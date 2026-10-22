//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// `@testable` for `applySystemMute`, which a host drives through its CallKit delegate rather than
// by calling it, and for `MatrixRTCMediaSession`'s internal initialiser.
@testable import ElementCallHost
@testable import ElementCallKit
@testable import ElementCallUI
import Foundation
import MatrixRtc
import Testing

/// Muting or turning the camera off before the call exists.
///
/// The control bar is drawn whenever the screen is maximized, with no gate on the connection, so it
/// is live from `.joining` onwards -- a good twenty seconds on a slow join. Every tap there used to
/// be dropped: `setMicrophoneMuted` forwarded to a nil `call`, CallKit's echo landed in
/// `applySystemMute` which is itself `guard let call`, and `refresh()` returned before it could draw
/// the button's new state. The microphone was then published unmuted regardless.
///
/// `ElementCallController.fake(connection:)` is exactly the state under test: a room, and no call.
///
/// The tests that wait on a screen use `deferFulfillment`, the helper the host reads its own tests
/// with: start watching, act, then fulfil. Watching before the act is the point -- a value that
/// lands between the two cannot be missed.
@Suite("Pre-join controls")
@MainActor
struct PreJoinControlsTests {
    /// `ElementCallController.fake(connection:)` builds its own ports and keeps them to itself, so a
    /// test that needs to speak *through* one builds the controller itself. The same wiring
    /// otherwise.
    private func makeJoiningController(isAudioCall: Bool = false) -> (ElementCallController, ElementCallFakeSystem) {
        let system = ElementCallFakeSystem()
        let controller = ElementCallController(rtcClient: MatrixRTCClient(transport: ElementCallFakeTransport()),
                                               system: system,
                                               // The same everything-on options `fake(...)` uses, so
                                               // the two controllers differ only in who holds the ports.
                                               options: ElementCallOptions(isDeveloperModeEnabled: true,
                                                                           isScreenSharingEnabled: true),
                                               style: .stock,
                                               logger: nil)
        controller.setPreviewState(callData: .init(isAudioCall: isAudioCall, isStartingCall: true),
                                   room: ElementCallFakeRoom(),
                                   connection: .joining)
        return (controller, system)
    }
    
    /// Driven through the view action rather than by calling the controller, so it covers the whole
    /// path a tap takes and asserts what the user is looking at: the button has to hold, or they tap
    /// it again and unmute themselves.
    @Test
    func aMuteBeforeTheCallExistsReachesTheScreen() async throws {
        let controller = ElementCallController.fake(connection: .joining)
        let viewModel = ElementCallScreenViewModel(controller: controller)
        #expect(!viewModel.context.viewState.isMicrophoneMuted)
        let muted = deferFulfillment(values { viewModel.context.viewState.isMicrophoneMuted }) { $0 }
        
        viewModel.context.send(viewAction: .toggleMicrophone)
        
        let isMuted = try await muted.fulfill()
        #expect(isMuted)
    }
    
    /// Only the disabling direction. Enabling goes through `AVCaptureDevice.requestAccess`, which
    /// nothing in process can answer for, whereas `if enabled, ...` skips that branch entirely here.
    @Test
    func turningTheCameraOffBeforeTheCallExistsIsRemembered() async throws {
        let controller = ElementCallController.fake(connection: .joining)
        #expect(controller.isCameraEnabled)
        let disabled = deferFulfillment(values { controller.isCameraEnabled }) { !$0 }
        
        controller.setCameraEnabled(false)
        
        let isEnabled = try await disabled.fulfill()
        #expect(!isEnabled)
    }
    
    /// The system call UI is the other way in -- the lock screen, or the CallKit banner -- and a
    /// user who mutes there while we are joining has the same expectation.
    ///
    /// Driven from the port rather than by calling `applySystemMute` directly, so the subscription
    /// in the controller's initialiser is part of what is under test: routing that event to the
    /// wrong handler, or dropping the subscription, is as good a way to lose the mute as the guard
    /// that used to sit inside it.
    @Test
    func aSystemMuteBeforeTheCallExistsReachesTheScreen() async throws {
        let (controller, system) = makeJoiningController()
        let viewModel = ElementCallScreenViewModel(controller: controller)
        #expect(!viewModel.context.viewState.isMicrophoneMuted)
        let muted = deferFulfillment(values { viewModel.context.viewState.isMicrophoneMuted }) { $0 }
        
        system.send(.microphoneMuteChanged(isMuted: true))
        
        let isMuted = try await muted.fulfill()
        #expect(isMuted)
    }
    
    /// The end of the chain, and the only part of it that reaches the transport: a mute the
    /// controller is holding has to go into the publish itself, not be applied after it. Publishing
    /// unmuted and correcting it a moment later is what put a lobby mute on the wire.
    @Test
    func theMuteGoesIntoThePublishRatherThanAfterIt() async throws {
        let session = FakeMediaSession()
        let call = MatrixRTCMediaSession(localMemberID: "@me:example.org_DEVICE", mediaSession: session)
        
        try await call.publishMicrophone(muted: true)
        
        #expect(session.published.count == 1)
        #expect(session.published.first?.kind == .microphone)
        #expect(session.published.first?.muted == true)
    }
    
    /// The control, or the test above would pass just as well against a hardcoded `true`.
    @Test
    func anUnmutedJoinPublishesUnmuted() async throws {
        let session = FakeMediaSession()
        let call = MatrixRTCMediaSession(localMemberID: "@me:example.org_DEVICE", mediaSession: session)
        
        try await call.publishMicrophone(muted: false)
        
        #expect(session.published.first?.muted == false)
    }
    
    /// The seed the intent starts from, which used to be read straight off `callData` inside
    /// `publishMedia` and so could not be overridden by a tap.
    @Test
    func theCameraStartsOnForAVideoCallAndOffForAnAudioOne() {
        #expect(ElementCallController.fake(connection: .joining, isAudioCall: false).isCameraEnabled)
        #expect(!ElementCallController.fake(connection: .joining, isAudioCall: true).isCameraEnabled)
    }
}
