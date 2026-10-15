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
/// to what a room needs, through the transport, when the room is opened.
public final class MatrixRTCClient {
    /// How long a room may take to become ready. The core waits for one delivery of every subject it
    /// subscribed to, with no deadline of its own, so a transport feed that never delivers would
    /// otherwise leave the join spinning for good.
    static let seedingTimeout: Duration = .seconds(30)
    
    private let transport: any ElementCallMatrixTransportProtocol
    private let backend: MatrixRTCBackend
    private let clock: any Clock<Duration>
    private lazy var client = RtcClient(backend: backend)
    
    public init(transport: any ElementCallMatrixTransportProtocol, clock: any Clock<Duration> = ContinuousClock()) {
        self.transport = transport
        self.clock = clock
        backend = MatrixRTCBackend(transport: transport)
    }
    
    /// Opens the room in a membership format and returns once the core has applied its current state.
    public func room(roomID: String, format: MatrixRTCMembershipFormat) async throws -> MatrixRTCRoom {
        let matrixRoom: any ElementCallMatrixRoomProtocol
        do {
            matrixRoom = try await transport.openRoom(roomID: roomID)
        } catch {
            MatrixRTCLog.error("The transport could not open \(roomID): \(error)")
            throw MatrixRTCError.transport("\(error)")
        }
        // Before the core asks for anything: it subscribes from inside `room`.
        backend.register(matrixRoom)
        
        MatrixRTCLog.info("Opening \(roomID) in format \(format)")
        do {
            let rtcRoom = try await seededRoom(roomID: roomID, format: format)
            MatrixRTCLog.info("\(roomID) is ready")
            return MatrixRTCRoom(rtcRoom: rtcRoom, matrixRoom: matrixRoom, backend: backend)
        } catch {
            backend.unregister(roomID: roomID)
            await matrixRoom.close()
            throw error
        }
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
            MatrixRTCLog.error("\(roomID) was not ready after \(Self.seedingTimeout); the core's log names the feed it waits on")
            Task {
                if let late = try? await attempt.value {
                    await late.shutdown()
                }
            }
            throw MatrixRTCError.roomNotReady(roomID: roomID)
        }
    }
}

/// One room, subscribed and ready. Joining a call happens here; observing the room is the core's.
public final class MatrixRTCRoom {
    public let roomID: String
    /// What a join tells the homeserver to keep us in the call for without hearing from us. The core
    /// restarts it on its own schedule.
    static let keepAliveTimeoutMs: UInt64 = 20000
    
    private let rtcRoom: RtcRoom
    private let matrixRoom: any ElementCallMatrixRoomProtocol
    private let backend: MatrixRTCBackend
    private var call: MatrixRTCCall?
    private var isShutDown = false
    
    init(rtcRoom: RtcRoom, matrixRoom: any ElementCallMatrixRoomProtocol, backend: MatrixRTCBackend) {
        roomID = matrixRoom.roomID
        self.rtcRoom = rtcRoom
        self.matrixRoom = matrixRoom
        self.backend = backend
    }
    
    /// Joins the room's call. No slot is named: the core joins the room-wide one, and picks the
    /// transport from what the homeserver advertises, failing the join when it advertises none.
    public func joinCall(notify: MatrixRTCNotify?) async throws -> MatrixRTCCall {
        guard !isShutDown else { throw MatrixRTCError.ffi("\(roomID) is shut down") }
        let rtcCall: RtcCall
        do {
            rtcCall = try await rtcRoom.joinCall(params: FfiJoinSessionParams(applicationSlotId: nil,
                                                                              transport: .advertised,
                                                                              keepAliveTimeoutMs: Self.keepAliveTimeoutMs,
                                                                              stickyDurationMs: nil, // The core owns the membership lifetime.
                                                                              encryptionConfig: nil, // Follow whatever the slot prescribes.
                                                                              notify: notify?.ffi))
        } catch MatrixRtcFfiError.SlotClosed(let message) {
            MatrixRTCLog.error("Join refused in \(roomID), the slot is closed: \(message)")
            throw MatrixRTCError.slotClosed(message)
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
    
    /// Leaves any call still joined here, then stops following the room. The transport's room is
    /// closed last, because the core leaves through it.
    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        await rtcRoom.shutdown()
        call?.stop()
        call = nil
        backend.unregister(roomID: roomID)
        await matrixRoom.close()
        MatrixRTCLog.info("Shut \(roomID) down")
    }
    
    public func debugSnapshot() async -> String {
        await (try? rtcRoom.debugSnapshot()) ?? "unavailable"
    }
}
