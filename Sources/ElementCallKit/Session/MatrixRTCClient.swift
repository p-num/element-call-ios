//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc

/// The entry point to the core for one Matrix account: it opens rooms, and holds nothing about any
/// room until one is asked for. There is nothing to start and nothing to feed; the core subscribes
/// to what a room needs, through the host's backend, when the room is opened.
public final class MatrixRTCClient {
    public var userID: String {
        backend.ownUserId()
    }
    
    /// How long a room may take to become ready. The core waits for one delivery of every subject it
    /// subscribed to, with no deadline of its own, so a backend feed that never delivers would
    /// otherwise leave the join spinning for good.
    static let seedingTimeout: Duration = .seconds(30)
    
    private let backend: MatrixBackendAdapter
    private let clock: any Clock<Duration>
    private lazy var client = RtcClient(backend: backend)
    
    public init(backend: any ElementCallMatrixBackendProtocol, clock: any Clock<Duration> = ContinuousClock()) {
        self.backend = MatrixBackendAdapter(backend)
        self.clock = clock
    }
    
    /// Whether the homeserver answers: the current value, then every change, for as long as the
    /// stream is read (034 C4). Live from the client rather than from a call, so it covers a join
    /// made during an outage and a direct call ringing before its media is up.
    public func signallingUpdates() -> AsyncStream<MatrixRTCSignallingHealth> {
        let subscription = client.subscribeSignallingHealth()
        let (updates, continuation) = AsyncStream<MatrixRTCSignallingHealth>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // The bindings' `next()` ignores cancellation, so a cancelled reader parks until the next
        // change and leaves then.
        let reader = Task {
            while let health = await subscription.next(), !Task.isCancelled {
                continuation.yield(MatrixRTCSignallingHealth(health))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in reader.cancel() }
        return updates
    }
    
    /// From the host: its Matrix client has gone offline (`false`), or a request has succeeded
    /// since it was (`true`) — never merely that it started trying, which would retry every send
    /// for nothing (034 C3). Optional; without it the core goes by its own sends.
    public func reportConnectivity(isOnline: Bool) {
        MatrixRTCLog.info("Host reports the homeserver \(isOnline ? "online" : "offline")")
        client.reportConnectivity(online: isOnline)
    }
    
    /// Opens the room in a membership format and returns once the core has applied its current state.
    public func room(roomID: String, format: MatrixRTCMembershipFormat) async throws -> MatrixRTCRoom {
        MatrixRTCLog.info("Opening \(roomID) in format \(format)")
        let rtcRoom = try await seededRoom(roomID: roomID, format: format)
        guard !Task.isCancelled else {
            await rtcRoom.shutdown()
            throw CancellationError()
        }
        MatrixRTCLog.info("\(roomID) is ready")
        return MatrixRTCRoom(roomID: roomID, rtcRoom: rtcRoom)
    }
    
    /// The core's `room`, bounded by ``seedingTimeout``.
    ///
    /// A race rather than a task group: the bindings' futures ignore cancellation, so a group would
    /// wait for the losing call anyway, which is the hang this exists to escape. A room that becomes
    /// ready after its caller gave up is shut down at once, or the core would refuse the next attempt
    /// to open it.
    private func seededRoom(roomID: String, format: MatrixRTCMembershipFormat) async throws -> RtcRoom {
        let client = client
        let options = FfiRoomOptions(format: format.ffi)
        let attempt = Task { try await client.room(roomId: roomID, options: options) }
        
        let (outcomes, continuation) = AsyncStream<Result<RtcRoom, any Error>?>.makeStream()
        let waiter = Task { await continuation.yield(attempt.result) }
        let timer = Task { [clock] in
            try await clock.sleep(for: Self.seedingTimeout)
            continuation.yield(nil)
        }
        var iterator = outcomes.makeAsyncIterator()
        let outcome = await iterator.next() ?? nil
        continuation.finish()
        timer.cancel()
        waiter.cancel()
        
        switch outcome {
        case .success(let rtcRoom):
            return rtcRoom
        case .failure(let error):
            MatrixRTCLog.error("Opening \(roomID) failed: \(error)")
            throw MatrixRTCError.ffi("\(error)")
        case nil:
            Task {
                if let late = try? await attempt.value {
                    await late.shutdown()
                }
            }
            try Task.checkCancellation()
            MatrixRTCLog.error("\(roomID) was not ready after \(Self.seedingTimeout); the core's log names the feed it waits on")
            throw MatrixRTCError.roomNotReady(roomID: roomID)
        }
    }
}

/// One room, subscribed and ready. Joining a call happens here; observing the room is the core's.
public final class MatrixRTCRoom {
    public let roomID: String
    /// What a join tells the homeserver to keep us in the call for without hearing from us. The core
    /// restarts it on its own schedule.
    static let keepAliveTimeout: Duration = .seconds(20)
    
    private let rtcRoom: RtcRoom
    private var call: MatrixRTCCall?
    private var isShutDown = false
    
    init(roomID: String, rtcRoom: RtcRoom) {
        self.roomID = roomID
        self.rtcRoom = rtcRoom
    }
    
    /// Joins the room's call. No slot is named: the core joins the room-wide one, and picks the
    /// transport from what the homeserver advertises, failing the join when it advertises none.
    /// Intent describes membership even when joining quietly; ringing remains a separate policy.
    public func joinCall(intent: MatrixRTCCallIntent? = nil, kind: MatrixRTCCallKind) async throws -> MatrixRTCCall {
        guard !isShutDown else { throw MatrixRTCError.ffi("\(roomID) is shut down") }
        let rtcCall: RtcCall
        do {
            rtcCall = try await rtcRoom.joinCall(params: FfiJoinSessionParams(applicationSlotId: nil,
                                                                              callIntent: intent?.rawValue,
                                                                              transport: .advertised,
                                                                              kind: kind.ffi,
                                                                              keepAliveTimeoutMs: Self.keepAliveTimeout.inMilliseconds,
                                                                              stickyDurationMs: nil, // The core owns the membership lifetime.
                                                                              encryptionConfig: nil)) // Follow whatever the slot prescribes.
        } catch MatrixRtcFfiError.SlotClosed(let message) {
            MatrixRTCLog.error("Join refused in \(roomID), the slot is closed: \(message)")
            throw MatrixRTCError.slotClosed(message)
        } catch MatrixRtcFfiError.JoinTimedOut {
            MatrixRTCLog.error("Join timed out in \(roomID)")
            throw MatrixRTCError.joinTimedOut
        } catch MatrixRtcFfiError.JoinRefused(let errorCode, let reason) {
            MatrixRTCLog.error("Join refused in \(roomID): \(errorCode ?? "no code") \(reason)")
            throw MatrixRTCError.joinRefused(errorCode: errorCode, reason: reason)
        } catch {
            MatrixRTCLog.error("Join failed in \(roomID): \(error)")
            throw MatrixRTCError.ffi("\(error)")
        }
        let call = MatrixRTCCall(rtcCall: rtcCall)
        MatrixRTCLog.info("Joined \(roomID)/\(call.slotID) as \(call.localMemberID)")
        self.call = call
        call.start()
        return call
    }
    
    /// Leaves any call still joined here, then stops following the room: the core cancels its
    /// subscriptions to the backend as it goes.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await rtcRoom.shutdown()
        call?.stop()
        call = nil
        MatrixRTCLog.info("Shut \(roomID) down")
    }
    
    public func debugSnapshot() async -> String {
        await (try? rtcRoom.debugSnapshot()) ?? "unavailable"
    }
}
