//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// Records what `MatrixRTCMediaSession` asks of the transport, which is the only place the publish options
/// are observable: everything past this point is Rust.
///
/// `FfiLocalTrack(noPointer:)` is the initialiser uniffi provides for exactly this -- the object
/// holds no Rust pointer, so it can be handed around but never called into. Nothing does, here: the
/// microphone's drainer only reaches for the track once the ring has frames in it, and no audio
/// engine is running.
final class FakeMediaSession: MediaSessionProtocol, @unchecked Sendable {
    private let state = Mutex(State())
    
    private struct State {
        var published: [FfiPublishOptions] = []
        var localMutes: [(kind: FfiStreamKind, muted: Bool)] = []
        var detailWindows: [(offset: UInt32, len: UInt32, also: [FfiTileId])] = []
        var constraints: [(stream: FfiStreamRef, constraints: FfiMediaConstraints)] = []
    }
    
    var published: [FfiPublishOptions] {
        state.withLock { $0.published }
    }
    
    /// Every window the call declared, in order; the core republishes on each, so a repeat is a bug.
    var detailWindows: [(offset: UInt32, len: UInt32, also: [FfiTileId])] {
        state.withLock { $0.detailWindows }
    }
    
    var constraints: [(stream: FfiStreamRef, constraints: FfiMediaConstraints)] {
        state.withLock { $0.constraints }
    }
    
    var localMutes: [(kind: FfiStreamKind, muted: Bool)] {
        state.withLock { $0.localMutes }
    }
    
    func publish(options: FfiPublishOptions) async throws -> FfiLocalTrack {
        state.withLock { $0.published.append(options) }
        return FfiLocalTrack(noPointer: .init())
    }
    
    func setLocalMuted(kind: FfiStreamKind, muted: Bool) async throws {
        state.withLock { $0.localMutes.append((kind, muted)) }
    }
    
    // MARK: - Inert
    
    func audioStream(memberId: String, kind: FfiStreamKind) -> AudioFrameStream? {
        nil
    }
    
    func disconnect() async throws { }
    func localIdentity() -> String {
        "@fake:example.org"
    }
    
    /// Never returns, so the call's event pump parks rather than spinning.
    func nextEvent() async -> FfiCallEvent? {
        try? await Task.sleep(for: .seconds(3600))
        return nil
    }
    
    /// Parks like `nextEvent()`, for the same reason.
    func nextRoster() async -> FfiTileRoster? {
        try? await Task.sleep(for: .seconds(3600))
        return nil
    }
    
    /// Parks like `nextEvent()`, for the same reason.
    func nextLocalState() async -> FfiLocalState? {
        try? await Task.sleep(for: .seconds(3600))
        return nil
    }
    
    func roster() -> FfiTileRoster {
        FfiTileRoster(order: [], detail: [])
    }
    
    func localState() -> FfiLocalState? {
        nil
    }
    
    func setRankingThreshold(tiles: UInt32) { }
    
    func setDetailWindow(offset: UInt32, len: UInt32, also: [FfiTileId]) {
        state.withLock { $0.detailWindows.append((offset, len, also)) }
    }
    
    func participants() -> [FfiParticipant] {
        []
    }
    
    func receiveStats(memberId: String, kind: FfiStreamKind) async -> FfiReceiveStats? {
        nil
    }
    
    func receiveStatsFor(streams: [FfiStreamRef]) async -> [FfiStreamStats] {
        []
    }
    
    func setConstraints(memberId: String, kind: FfiStreamKind, constraints: FfiMediaConstraints) {
        state.withLock { $0.constraints.append((FfiStreamRef(memberId: memberId, kind: kind), constraints)) }
    }
    
    func unpublish(kind: FfiStreamKind) async throws { }
    func videoStream(memberId: String, kind: FfiStreamKind) -> VideoFrameStream? {
        nil
    }
}
