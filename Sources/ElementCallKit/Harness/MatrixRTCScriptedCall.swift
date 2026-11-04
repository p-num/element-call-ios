//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// A call whose status is played rather than reported by the core: a direct call ringing, picked
/// up, declined or unanswered, on the real screen and with the real sounds, with no homeserver.
///
/// What it hands out is a genuine ``MatrixRTCCall``, so everything above the core runs as it ships:
/// the controller follows the status, the screen draws it, and the call's own audio plays the
/// ringback and the end sounds. Only the membership is inert: no roster, no hands, no reactions.
public final class MatrixRTCScriptedCall {
    public let call: MatrixRTCCall
    private let core: ScriptedCore
    
    public init(roomID: String, status: MatrixRTCCallStatus) {
        core = ScriptedCore(roomID: roomID, status: status.ffi)
        call = MatrixRTCCall(rtcCall: core)
        call.start()
    }
    
    /// What the core would report next. A hang-up reports `.ended(.left)` by itself, as the core does.
    public func report(_ status: MatrixRTCCallStatus) {
        core.subscription.push(status.ffi)
    }
}

private nonisolated extension MatrixRTCCallStatus {
    var ffi: FfiCallStatus {
        switch self {
        case .connecting:
            .connecting
        case .calling(let callee, let ring, let media):
            .calling(callee: callee, ring: ring.ffi, media: media.ffi)
        case .connected(let since, let isDegraded):
            .connected(sinceMs: since.milliseconds, degraded: isDegraded)
        case .ended(let reason):
            .ended(reason: reason.ffi)
        }
    }
}

private nonisolated extension MatrixRTCRingPhase {
    var ffi: FfiRingPhase {
        switch self {
        case .sending:
            .sending
        case .ringing(let sentAt, let lifetime):
            .ringing(sentAtMs: sentAt.milliseconds, lifetimeMs: UInt64(lifetime / .milliseconds(1)))
        }
    }
}

private nonisolated extension MatrixRTCMediaPhase {
    var ffi: FfiMediaPhase {
        switch self {
        case .connecting: .connecting
        case .connected(let isDegraded): .connected(degraded: isDegraded)
        }
    }
}

private nonisolated extension MatrixRTCEndReason {
    var ffi: FfiCallEnd {
        switch self {
        case .left: .left
        case .declined: .declined
        case .unanswered: .unanswered
        case .ringNotSent: .ringNotSent
        case .othersLeft: .othersLeft
        case .empty: .empty
        case .slotClosed: .slotClosed
        case .connectionClosed(let message): .connectionClosed(message: message)
        }
    }
}

private nonisolated extension Date {
    var milliseconds: UInt64 {
        UInt64(max(0, timeIntervalSince1970 * 1000))
    }
}

/// The membership side of the scripted call: the status as pushed, and nothing else.
private final nonisolated class ScriptedCore: RtcCallProtocol, Sendable {
    let subscription = ScriptedStatusSubscription()
    private let roomID: String
    private let initialStatus: FfiCallStatus
    
    init(roomID: String, status: FfiCallStatus) {
        self.roomID = roomID
        initialStatus = status
    }
    
    func status() -> FfiCallStatus {
        initialStatus
    }
    
    func subscribeStatus() -> CallStatusSubscription {
        subscription
    }
    
    func leave(params: FfiLeaveSessionParams) async throws {
        subscription.push(.ended(reason: .left))
    }
    
    func roomId() -> String {
        roomID
    }
    
    func slotId() -> String {
        "m.call#ROOM"
    }
    
    func memberId() -> String {
        "@alice:example.com:DEVICE"
    }
    
    func isLive() -> Bool {
        true
    }
    
    func memberCount() async -> UInt64 {
        1
    }
    
    func membershipEventId() async -> String? {
        nil
    }
    
    func raiseHand() async throws { }
    
    func lowerHand() async throws { }
    
    func raisedHands() async -> [FfiRaisedHand] {
        []
    }
    
    func sendReaction(emoji: String, name: String) async throws -> String {
        ""
    }
    
    func subscribeMembershipSnapshots() async -> MembershipSnapshotSubscription {
        NoMembershipSubscription(noPointer: .init())
    }
    
    /// Never resolves: the scripted call ends through its status.
    func waitForEnd() async -> FfiLeaveReason {
        await withCheckedContinuation { _ in }
    }
}

/// Answers each `next()` with the next pushed status, waiting for one when there is none yet, and
/// nil once it has handed out an end, as the core's does: that nil is what stops the call reading.
private final nonisolated class ScriptedStatusSubscription: CallStatusSubscription {
    private struct State {
        var queued: [FfiCallStatus] = []
        var pending: CheckedContinuation<FfiCallStatus?, Never>?
        var hasEnded = false
        
        mutating func handOut(_ status: FfiCallStatus) -> FfiCallStatus {
            if case .ended = status {
                hasEnded = true
            }
            return status
        }
    }
    
    private let state = Mutex(State())
    
    init() {
        super.init(noPointer: .init())
    }
    
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("A scripted subscription has no Rust object behind it")
    }
    
    func push(_ status: FfiCallStatus) {
        let pending = state.withLock { state in
            guard let pending = state.pending else {
                state.queued.append(status)
                return nil as CheckedContinuation<FfiCallStatus?, Never>?
            }
            state.pending = nil
            _ = state.handOut(status)
            return pending
        }
        pending?.resume(returning: status)
    }
    
    override func next() async -> FfiCallStatus? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> FfiCallStatus?? in
                if state.hasEnded {
                    return .some(nil)
                }
                guard !state.queued.isEmpty else {
                    state.pending = continuation
                    return nil
                }
                return .some(state.handOut(state.queued.removeFirst()))
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }
}

/// Ends on the first read: the scripted call has no roster of its own; the tiles come from the
/// scripted media session beside it.
private final nonisolated class NoMembershipSubscription: MembershipSnapshotSubscription {
    override func next() async -> [JoinedMembership]? {
        nil
    }
}
