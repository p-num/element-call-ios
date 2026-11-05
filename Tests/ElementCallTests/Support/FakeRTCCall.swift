//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// A membership that holds each hand request until the test answers it, oldest first, so the time
/// between a tap and the homeserver's reply is something a test can stand in, and reports whatever
/// status the test pushes.
///
/// Everything else is inert: there is no roster.
final class FakeRTCCall: RtcCallProtocol, Sendable {
    enum HandRequest: Equatable {
        case raise
        case lower
    }
    
    struct RefusedError: Error { }
    
    private struct State {
        var requests: [HandRequest] = []
        var pending: [CheckedContinuation<Void, Error>] = []
        var leaveCount = 0
        var pendingLeave: CheckedContinuation<Void, Error>?
    }
    
    private let state = Mutex(State())
    private let holdsLeave: Bool
    
    var hasPendingLeave: Bool {
        state.withLock { $0.pendingLeave != nil }
    }
    
    func answerLeave(failingWith error: Error? = nil) {
        let pending = state.withLock { state in
            defer { state.pendingLeave = nil }
            return state.pendingLeave
        }
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume()
        }
    }
    
    private let initialStatus: FfiCallStatus
    let statusSubscription = FakeStatusSubscription()
    
    init(status: FfiCallStatus = .connected(sinceMs: 0, degraded: false), holdsLeave: Bool = false) {
        self.holdsLeave = holdsLeave
        initialStatus = status
    }
    
    /// Every hand request made, answered or not.
    var requests: [HandRequest] {
        state.withLock { $0.requests }
    }
    
    var leaveCount: Int {
        state.withLock { $0.leaveCount }
    }
    
    var pendingRequestCount: Int {
        state.withLock { $0.pending.count }
    }
    
    /// Answers the oldest request in flight: it resolved, or was refused with `error`.
    func answer(failingWith error: Error? = nil) {
        let pending = state.withLock { state in
            state.pending.isEmpty ? nil : state.pending.removeFirst()
        }
        if let error {
            pending?.resume(throwing: error)
        } else {
            pending?.resume()
        }
    }
    
    private func hold(_ request: HandRequest) async throws {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                state.requests.append(request)
                state.pending.append(continuation)
            }
        }
    }
    
    // MARK: - RtcCallProtocol
    
    func raiseHand() async throws {
        try await hold(.raise)
    }
    
    func lowerHand() async throws {
        try await hold(.lower)
    }
    
    func roomId() -> String {
        "!room:example.com"
    }
    
    func slotId() -> String {
        "m.call#ROOM"
    }
    
    func memberId() -> String {
        "@me:example.com:DEVICE"
    }
    
    func isLive() -> Bool {
        true
    }
    
    func leave(params: FfiLeaveSessionParams) async throws {
        state.withLock { $0.leaveCount += 1 }
        if holdsLeave {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.pendingLeave = continuation }
            }
        }
    }
    
    func memberCount() async -> UInt64 {
        1
    }
    
    func membershipEventId() async -> String? {
        nil
    }
    
    func raisedHands() async -> [FfiRaisedHand] {
        []
    }
    
    func sendReaction(emoji: String, name: String) async throws -> String {
        ""
    }
    
    func status() -> FfiCallStatus {
        initialStatus
    }
    
    func subscribeStatus() -> CallStatusSubscription {
        statusSubscription
    }
    
    func subscribeMembershipSnapshots() async -> MembershipSnapshotSubscription {
        EmptyMembershipSubscription(noPointer: .init())
    }
    
    func waitForEnd() async -> FfiLeaveReason {
        fatalError("A call over FakeRTCCall is never started")
    }
}

/// Answers each `next()` with the next pushed status, waiting for one when there is none yet, as the
/// core's does. A pushed nil ends it.
final nonisolated class FakeStatusSubscription: CallStatusSubscription {
    private struct State {
        var queued: [FfiCallStatus?] = []
        var pending: CheckedContinuation<FfiCallStatus?, Never>?
    }
    
    private let state = Mutex(State())
    
    init() {
        super.init(noPointer: .init())
    }
    
    required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
        fatalError("A fake has no Rust object behind it")
    }
    
    func push(_ status: FfiCallStatus?) {
        let pending = state.withLock { state in
            guard let pending = state.pending else {
                state.queued.append(status)
                return nil as CheckedContinuation<FfiCallStatus?, Never>?
            }
            state.pending = nil
            return pending
        }
        pending?.resume(returning: status)
    }
    
    override func next() async -> FfiCallStatus? {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> FfiCallStatus?? in
                guard !state.queued.isEmpty else {
                    state.pending = continuation
                    return nil
                }
                return .some(state.queued.removeFirst())
            }
            if let ready {
                continuation.resume(returning: ready)
            }
        }
    }
}

/// Ends on the first read, as the core's does once the room has gone.
final nonisolated class EmptyMembershipSubscription: MembershipSnapshotSubscription {
    override func next() async -> [JoinedMembership]? {
        nil
    }
}
