//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Observation

/// The outcome of sending this device's departure, separately from local media teardown.
public nonisolated enum MatrixRTCLeaveResult: Sendable, Equatable {
    case confirmed
    case failed
}

/// Our participation in a room's call: membership in, media attached separately.
///
/// You are in the call as soon as ``MatrixRTCRoom/joinCall(kind:)`` returned; media is attached with
/// ``connectMedia()``. Teardown order matters: disconnect media → leave → shut the room down.
@MainActor
@Observable
public final class MatrixRTCCall {
    public let roomID: String
    public let slotID: String
    /// Minted by the core at join time; what every event, roster entry and key report is keyed by.
    public let localMemberID: String
    
    /// Who is in the call, from the core's membership projection, ourselves included.
    public private(set) var members: [MatrixRTCMembership] = []
    /// People in the call, counting a user on multiple devices once.
    public var memberCount: Int {
        Set(members.map(\.userID)).count
    }
    
    /// Where the call is, as the core sees it. In a DM it is also how the call ends without us: the
    /// core leaves by itself on a decline, a ring nobody answered or the other side hanging up.
    public private(set) var status: MatrixRTCCallStatus
    /// Every change of ``status``, starting after the value it had at the join.
    public let statusUpdates: AsyncStream<MatrixRTCCallStatus>
    @ObservationIgnored private let statusContinuation: AsyncStream<MatrixRTCCallStatus>.Continuation
    
    public private(set) var mediaSession: MatrixRTCMediaSession?
    
    /// The protocol rather than the class so a test can stand in for the membership; only
    /// ``connectMedia()`` needs the core's own call, and says so.
    @ObservationIgnored private let rtcCall: any RtcCallProtocol
    @ObservationIgnored private var leaveTask: Task<MatrixRTCLeaveResult, Never>?
    @ObservationIgnored private var membershipReader: Task<Void, Never>?
    @ObservationIgnored private var membershipObservers: [UUID: AsyncStream<[MatrixRTCMembership]>.Continuation] = [:]
    private var isStopped = false
    @ObservationIgnored private var statusReader: Task<Void, Never>?
    
    /// The call's engine and sounds, from the join: the ringback plays before there is media.
    @ObservationIgnored let audio: CallAudio
    @ObservationIgnored private let clock: any Clock<Duration>
    /// Time on ``clock`` since the join.
    @ObservationIgnored private let elapsed: () -> Duration
    /// When the end sound finishes, on ``elapsed``; the audio is released no earlier (030 R25).
    @ObservationIgnored private var endSoundEnds: Duration?
    
    init(rtcCall: any RtcCallProtocol, audio: CallAudio = CallAudio(), clock: any Clock<Duration> = ContinuousClock()) {
        self.rtcCall = rtcCall
        self.audio = audio
        self.clock = clock
        elapsed = stopwatch(clock)
        roomID = rtcCall.roomId()
        slotID = rtcCall.slotId()
        localMemberID = rtcCall.memberId()
        status = MatrixRTCCallStatus(rtcCall.status())
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        playSounds(for: status)
    }
    
    /// Reads the roster until the room is shut down. Each `next()` waits for a change, the first
    /// answering the current roster; nil means the room has gone, and only then does reading stop.
    func start() {
        let rtcCall = rtcCall
        membershipReader = Task { [weak self] in
            let subscription = await rtcCall.subscribeMembershipSnapshots()
            while let snapshot = await subscription.next() {
                guard !Task.isCancelled else { return }
                self?.updateMembers(snapshot.map(MatrixRTCMembership.init))
            }
        }
        // The subscription answers the current status first, which `init` already read.
        statusReader = Task { [weak self] in
            let subscription = rtcCall.subscribeStatus()
            while let status = await subscription.next() {
                guard !Task.isCancelled else { return }
                self?.updateStatus(MatrixRTCCallStatus(status))
            }
            self?.statusContinuation.finish()
        }
    }
    
    func stop() {
        isStopped = true
        membershipReader?.cancel()
        membershipReader = nil
        for observer in membershipObservers.values {
            observer.finish()
        }
        membershipObservers.removeAll()
        statusReader?.cancel()
        statusReader = nil
        statusContinuation.finish()
    }
    
    /// Each observer gets the current Matrix membership and subsequent changes. SFU reconnects
    /// do not imply departure, and multiple devices of one user remain separate memberships.
    public func membershipSnapshots() -> AsyncStream<[MatrixRTCMembership]> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(members)
            guard !isStopped else {
                continuation.finish()
                return
            }
            membershipObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.membershipObservers.removeValue(forKey: id) }
            }
        }
    }
    
    /// Attaches media. The core takes the transport from the join and the account from the backend.
    /// Returns once the engine is up, without waiting for our own media server, which the core
    /// connects as it would reconnect a lost one (034 C10). `isSFUFallbackEnabled`: see
    /// `ElementCallOptions.isSFUFallbackEnabled`.
    public func connectMedia(isSFUFallbackEnabled: Bool = false) async throws -> MatrixRTCMediaSession {
        if let mediaSession {
            return mediaSession
        }
        guard let rtcCall = rtcCall as? RtcCall else {
            throw MatrixRTCError.media("\(roomID)/\(slotID) is not a core call and has no media")
        }
        let ffiSession: MediaSession
        do {
            ffiSession = try await connectMediaSession(call: rtcCall, config: MediaSessionConfig(sfuFallback: isSFUFallbackEnabled))
        } catch {
            MatrixRTCLog.warning("Failed to connect media for \(roomID)/\(slotID): \(error)")
            throw MatrixRTCError.media("\(error)")
        }
        
        let mediaSession = MatrixRTCMediaSession(localMemberID: localMemberID, mediaSession: ffiSession, audio: audio)
        self.mediaSession = mediaSession
        await mediaSession.start()
        MatrixRTCLog.info("Media connected for \(roomID)/\(slotID) as \(localMemberID)")
        return mediaSession
    }
    
    /// Concurrent and repeated callers share the original result. A failed send cannot be
    /// retried on the ended core object and is never converted to success by a later teardown.
    @discardableResult
    public func leave(reason: MatrixRTCLeaveReason? = nil) async -> MatrixRTCLeaveResult {
        if let leaveTask {
            return await leaveTask.value
        }
        let task = Task { [self] in
            await mediaSession?.disconnect()
            mediaSession = nil
            do {
                let leaveReason = reason.map { FfiLeaveReason(code: $0.code, reason: $0.reason) }
                try await rtcCall.leave(params: FfiLeaveSessionParams(leaveReason: leaveReason))
                MatrixRTCLog.info("Left \(roomID)/\(slotID)")
                return MatrixRTCLeaveResult.confirmed
            } catch {
                MatrixRTCLog.warning("Failed to leave \(roomID)/\(slotID): \(error)")
                return MatrixRTCLeaveResult.failed
            }
        }
        leaveTask = task
        return await task.value
    }
    
    // MARK: - Audio
    
    /// Once the system has activated the audio session (CallKit's `didActivate`, or directly where
    /// nothing else owns it). Returns before the engine is running: starting it reconfigures the
    /// graph, which must not happen synchronously on this thread.
    public func startAudio() {
        audio.start()
    }
    
    /// How loud the call's sound effects play, 0 to 1 of the call's own level; half until set
    /// (037 R22). Applies to sounds already playing too.
    public func setSoundEffectsVolume(_ volume: Float) {
        audio.setEffectsGain(volume)
    }
    
    /// One short effect at the current volume, so the user hears what they chose (037 R24).
    public func playSoundEffectsVolumeSample() {
        audio.play(.join)
    }
    
    /// CallKit's `didDeactivate`.
    public func stopAudio() {
        audio.stop()
    }
    
    /// After the call has ended: lets a decline's or a timeout's sound play to its end, then shuts the
    /// call's audio down (030 R25). Nothing to wait for after a hang-up, which has no sound.
    public func releaseAudio() async {
        if let endSoundEnds {
            let remaining = endSoundEnds - elapsed()
            if remaining > .zero {
                try? await clock.sleep(for: remaining)
            }
        }
        audio.shutdown()
        MatrixRTCLog.info("Audio released for \(roomID)/\(slotID)")
    }
    
    private func playSounds(for status: MatrixRTCCallStatus) {
        audio.setRingback(RingingSoundPolicy.playsRingback(status))
        if let sound = RingingSoundPolicy.endSound(status) {
            audio.play(sound)
            endSoundEnds = audio.duration(of: sound).map { elapsed() + $0 }
        }
    }
    
    // MARK: - Raised hand
    
    /// Returns once the homeserver has the annotation, and the core has recorded our hand as up. The
    /// tiles carry it a moment later, through the same raised-hand set as everyone else's, which is
    /// what the control shows: never this call's success, which is not yet what others see.
    ///
    /// A no-op while the hand is up. The core keeps it on our membership across sticky refreshes,
    /// so nothing here re-raises it.
    public func raiseHand() async throws {
        do {
            try await rtcCall.raiseHand()
            MatrixRTCLog.info("Hand raised in \(roomID)/\(slotID)")
        } catch {
            MatrixRTCLog.warning("Failed to raise hand in \(roomID)/\(slotID): \(error)")
            throw MatrixRTCError.ffi("\(error)")
        }
    }
    
    /// Redacts the annotation. A no-op while the hand is down.
    public func lowerHand() async throws {
        do {
            try await rtcCall.lowerHand()
            MatrixRTCLog.info("Hand lowered in \(roomID)/\(slotID)")
        } catch {
            MatrixRTCLog.warning("Failed to lower hand in \(roomID)/\(slotID): \(error)")
            throw MatrixRTCError.ffi("\(error)")
        }
    }
    
    private func updateStatus(_ status: MatrixRTCCallStatus) {
        guard status != self.status else { return }
        MatrixRTCLog.info("\(roomID)/\(slotID) is \(status)")
        self.status = status
        playSounds(for: status)
        statusContinuation.yield(status)
    }
    
    func updateMembers(_ members: [MatrixRTCMembership]) {
        if members.map(\.memberID) != self.members.map(\.memberID) {
            MatrixRTCLog.info("\(members.count) member(s) in \(roomID)/\(slotID): \(members.map(\.memberID))")
        }
        self.members = members
        for observer in membershipObservers.values {
            observer.yield(members)
        }
    }
}
