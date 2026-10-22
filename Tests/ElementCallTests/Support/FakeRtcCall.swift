//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// A membership that holds each hand request until the test answers it, so the time between a tap
/// and the homeserver's reply is something a test can stand in.
///
/// Everything but the hand is inert. Nothing calls `start()` on a call built over this, so the
/// roster subscription is never asked for.
final class FakeRtcCall: RtcCallProtocol, Sendable {
    enum HandRequest: Equatable {
        case raise
        case lower
    }
    
    struct RefusedError: Error { }
    
    private struct State {
        var requests: [HandRequest] = []
        var pending: CheckedContinuation<Void, Error>?
    }
    
    private let state = Mutex(State())
    
    /// Every hand request made, answered or not.
    var requests: [HandRequest] {
        state.withLock { $0.requests }
    }
    
    var hasPendingRequest: Bool {
        state.withLock { $0.pending != nil }
    }
    
    /// Answers the request in flight: the homeserver accepted it, or refused it with `error`.
    func answer(failingWith error: Error? = nil) {
        let pending = state.withLock { state in
            defer { state.pending = nil }
            return state.pending
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
                state.pending = continuation
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
    
    func leave(params: FfiLeaveSessionParams) async throws { }
    
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
    
    func subscribeMembershipSnapshots() async -> MembershipSnapshotSubscription {
        fatalError("A call over FakeRtcCall is never started")
    }
    
    func waitForEnd() async -> FfiLeaveReason {
        fatalError("A call over FakeRtcCall is never started")
    }
}
