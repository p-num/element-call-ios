//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// What the system tells us about a call in progress.
public nonisolated enum ElementCallSystemEvent: Sendable {
    /// The system activated the audio session. It can land either side of media connecting, so the
    /// audio engine starts from whichever of the two happens second.
    case audioSessionActivated
    case audioSessionDeactivated
    /// The mute state changed outside our UI, from the lock screen or the system call UI.
    case microphoneMuteChanged(isMuted: Bool)
    /// The system ended the call, from the lock screen or because the user hung up elsewhere.
    case endCallRequested(roomID: String)
}

/// The system call integration, implemented by the host over CallKit.
///
/// This stays with the host because a CallKit provider is process-wide and usually shared with a
/// VoIP push registry: an app that also answers calls some other way cannot hand its provider over.
///
/// Answering an incoming call is deliberately not here. That arrives as a push and ends in a screen
/// being presented, which is the host's navigation, and reaches this package as an ordinary
/// ``ElementCallController/startCall(_:room:)``.
/// Main-actor bound, unlike ``ElementCallMatrixTransportProtocol``: the Rust core calls the transport from
/// its own threads, whereas this is only ever reached from the call controller.
@MainActor
public protocol ElementCallSystemProvidingProtocol: AnyObject {
    /// Reports an outgoing call, or attaches to the ringing call this one answers. Must return only
    /// once the system knows about the call, because our membership goes out immediately after: an
    /// incoming-call watcher that sees our own membership first reads it as answered elsewhere.
    func startCall(roomID: String, displayName: String, isVideo: Bool) async
    func reportConnected(roomID: String)
    /// Our publishing media is reconnecting; keep the same system call alive.
    func reportDisconnected(roomID: String)
    func endCall(roomID: String)
    /// Mirrors our mute state into the system call UI.
    func setMicrophoneEnabled(_ enabled: Bool, roomID: String)
    
    var events: AnyPublisher<ElementCallSystemEvent, Never> { get }
}

public extension ElementCallSystemProvidingProtocol {
    func reportDisconnected(roomID: String) { }
}
