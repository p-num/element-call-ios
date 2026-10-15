//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Observation

/// Our participation in a room's call: membership in, media attached separately.
///
/// You are in the call as soon as ``MatrixRTCRoom/joinCall(notify:)`` returned; media is attached with
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
    public var memberCount: Int {
        members.count
    }
    
    public private(set) var mediaSession: MatrixRTCMediaSession?
    
    /// The protocol rather than the class so a test can stand in for the membership; only
    /// ``connectMedia()`` needs the core's own call, and says so.
    @ObservationIgnored private let rtcCall: any RtcCallProtocol
    @ObservationIgnored private var hasLeft = false
    @ObservationIgnored private var membershipReader: Task<Void, Never>?
    
    init(rtcCall: any RtcCallProtocol) {
        self.rtcCall = rtcCall
        roomID = rtcCall.roomId()
        slotID = rtcCall.slotId()
        localMemberID = rtcCall.memberId()
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
    }
    
    func stop() {
        membershipReader?.cancel()
        membershipReader = nil
    }
    
    /// Attaches media. The core takes the transport from the join and the account from the backend,
    /// so there is nothing to pass.
    public func connectMedia() async throws -> MatrixRTCMediaSession {
        if let mediaSession {
            return mediaSession
        }
        guard let rtcCall = rtcCall as? RtcCall else {
            throw MatrixRTCError.media("\(roomID)/\(slotID) is not a core call and has no media")
        }
        let ffiSession: MediaSession
        do {
            ffiSession = try await connectMediaSession(call: rtcCall, config: MediaSessionConfig())
        } catch {
            MatrixRTCLog.warning("Failed to connect media for \(roomID)/\(slotID): \(error)")
            throw MatrixRTCError.media("\(error)")
        }
        
        let mediaSession = MatrixRTCMediaSession(localMemberID: localMemberID, mediaSession: ffiSession)
        self.mediaSession = mediaSession
        await mediaSession.start()
        MatrixRTCLog.info("Media connected for \(roomID)/\(slotID) as \(localMemberID)")
        return mediaSession
    }
    
    /// Idempotent: hanging up and tearing the screen down both leave, and the core refuses a second
    /// attempt.
    public func leave(reason: MatrixRTCLeaveReason? = nil) async {
        guard !hasLeft else {
            MatrixRTCLog.debug("Already left \(roomID)/\(slotID)")
            return
        }
        hasLeft = true
        
        await mediaSession?.disconnect()
        mediaSession = nil
        do {
            let leaveReason = reason.map { FfiLeaveReason(code: $0.code, reason: $0.reason) }
            try await rtcCall.leave(params: FfiLeaveSessionParams(leaveReason: leaveReason))
            MatrixRTCLog.info("Left \(roomID)/\(slotID)")
        } catch {
            MatrixRTCLog.warning("Failed to leave \(roomID)/\(slotID): \(error)")
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
    
    private func updateMembers(_ members: [MatrixRTCMembership]) {
        if members.map(\.memberID) != self.members.map(\.memberID) {
            MatrixRTCLog.info("\(members.count) member(s) in \(roomID)/\(slotID): \(members.map(\.memberID))")
        }
        self.members = members
    }
}
