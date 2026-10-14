//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// `@testable` for `MatrixRTCCall`'s internal initialiser and the controller's `setPreviewState`.
@testable import ElementCallHost
@testable import ElementCallKit
@testable import ElementCallUI
import Foundation
import MatrixRtc
import SwiftUI
import Testing

/// The raised hand on our side of the core: requests go through, and a refusal reaches the caller
/// rather than being logged and swallowed, since the control has to show it (009 R22).
@Suite("Raised hand")
@MainActor
struct RaisedHandTests {
    @Test
    func raisingAndLoweringGoThroughToTheCore() async throws {
        let rtcCall = FakeRtcCall()
        let call = MatrixRTCCall(rtcCall: rtcCall)
        
        async let raised: Void = call.raiseHand()
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer()
        try await raised
        
        async let lowered: Void = call.lowerHand()
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer()
        try await lowered
        
        #expect(rtcCall.requests == [.raise, .lower])
    }
    
    @Test
    func aRefusalReachesTheCaller() async throws {
        let rtcCall = FakeRtcCall()
        let call = MatrixRTCCall(rtcCall: rtcCall)
        
        let raised = Task { try await call.raiseHand() }
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer(failingWith: FakeRtcCall.RefusedError())
        
        await #expect(throws: MatrixRTCError.self) { try await raised.value }
    }
}

/// The controller between a tap and the homeserver's answer: one request at a time, and the
/// control never shows the tap (009 R5, R22).
@Suite("Raised hand control")
@MainActor
struct RaisedHandControlTests {
    private func makeController() -> (ElementCallController, FakeRtcCall) {
        let rtcCall = FakeRtcCall()
        let controller = ElementCallController.fake(connection: .connected)
        controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(),
                                   connection: .connected,
                                   rtcCall: MatrixRTCCall(rtcCall: rtcCall))
        return (controller, rtcCall)
    }
    
    @Test
    func aRequestIsPendingUntilTheHomeserverAnswers() async throws {
        let (controller, rtcCall) = makeController()
        
        controller.setHandRaised(true)
        #expect(controller.isHandPending)
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer()
        
        try await waitUntilSettled(controller)
        #expect(controller.errorMessage == nil)
        #expect(rtcCall.requests == [.raise])
    }
    
    /// A second tap while the first is in flight would send twice, and the order the two land in
    /// is the homeserver's to pick.
    @Test
    func aTapWhilePendingIsIgnored() async throws {
        let (controller, rtcCall) = makeController()
        
        controller.setHandRaised(true)
        try await waitForPendingRequest(on: rtcCall)
        controller.setHandRaised(false)
        rtcCall.answer()
        try await waitUntilSettled(controller)
        
        #expect(rtcCall.requests == [.raise])
    }
    
    @Test
    func aRefusalIsToldAndClearsThePendingState() async throws {
        let (controller, rtcCall) = makeController()
        
        controller.setHandRaised(false)
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer(failingWith: FakeRtcCall.RefusedError())
        
        try await waitUntilSettled(controller)
        #expect(controller.errorMessage == "Your hand could not be lowered.")
        #expect(rtcCall.requests == [.lower])
    }
    
    @Test
    func nothingIsSentBeforeTheJoin() {
        let controller = ElementCallController.fake(connection: .joining)
        
        controller.setHandRaised(true)
        
        #expect(!controller.isHandPending)
    }
    
    /// The screen, end to end: the control goes to pending, and when the homeserver accepts the
    /// raise it still shows the hand down, because our tile has not moved. Here it never will,
    /// since nothing publishes one; on a call the core does, a moment later. Showing the tap
    /// instead would tell the user their hand is up before anyone can see it (009 R5).
    @Test
    func theControlShowsTheTileNotTheTap() async throws {
        let (controller, rtcCall) = makeController()
        let viewModel = ElementCallScreenViewModel(controller: controller)
        // The first refresh runs from the observation task, after construction.
        _ = try await deferFulfillment(values { viewModel.context.viewState.isHandRaiseAvailable }) { $0 }.fulfill()
        let pending = deferFulfillment(values { viewModel.context.viewState.isHandPending }) { $0 }
        
        viewModel.context.send(viewAction: .toggleRaisedHand)
        
        _ = try await pending.fulfill()
        #expect(!viewModel.context.viewState.isHandRaised)
        let settled = deferFulfillment(values { viewModel.context.viewState.isHandPending }) { !$0 }
        try await waitForPendingRequest(on: rtcCall)
        rtcCall.answer()
        _ = try await settled.fulfill()
        #expect(!viewModel.context.viewState.isHandRaised)
    }
    
    @Test
    func theHarnessRaisesOurOwnTile() {
        let context = ElementCallScreenContext.harness(state: ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group))
        
        context.send(viewAction: .toggleRaisedHand)
        
        #expect(context.viewState.isHandRaised)
        // Nobody else in the group has a hand up, so ours is first.
        #expect(context.viewState.tiles.filter(\.hasHandRaised).map(\.handPosition) == [1])
        #expect(context.viewState.tiles.first { $0.isLocal }?.handPosition == 1)
    }
    
    /// The number is the core's, carried through unchanged: never recomputed from raise times, which
    /// would number only the tiles in the window (009 R6, C9).
    @Test
    func theTileCarriesTheCoresPosition() {
        let ffi = FfiCallTile(memberId: "@bob:example.com:DEVICE",
                              kind: .person,
                              userId: "@bob:example.com",
                              deviceId: "DEVICE",
                              hero: false,
                              hasVideo: false,
                              microphoneMuted: false,
                              speaking: false,
                              handRaisedAtMs: 5,
                              handRaisedPosition: 3,
                              reachable: true)
        #expect(MatrixRTCTile(ffi, localMemberID: "me").handRaisedPosition == 3)
    }
    
    private func waitUntilSettled(_ controller: ElementCallController) async throws {
        for _ in 0..<1000 where controller.isHandPending {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(!controller.isHandPending)
    }
}

/// Fewer than three people: no hand offered, unless ours is already up and has to come down (009 R2,
/// R33); and one-to-one, no hand shown.
@Suite("Raised hand in a small call")
@MainActor
struct SmallCallRaisedHandTests {
    typealias Fixtures = ElementCallPreviewFixtures
    
    @Test
    func theControlIsNotOfferedOneToOne() {
        let state = Fixtures.connected(tiles: [Fixtures.alice, Fixtures.bob])
        #expect(state.isOneToOne)
        #expect(!state.showsRaiseHandControl)
    }
    
    @Test
    func theControlIsNotOfferedAlone() {
        let state = Fixtures.connected(tiles: [Fixtures.alice])
        #expect(!state.showsRaiseHandControl)
    }
    
    /// A share is a second tile for the same person, so it does not make three people.
    @Test
    func aShareDoesNotCountAsAPerson() {
        let state = Fixtures.connected(tiles: [Fixtures.alice, Fixtures.share("Frank"), Fixtures.tile("Frank", hasVideo: true)])
        #expect(!state.showsRaiseHandControl)
    }
    
    @Test
    func aHandAlreadyUpCanStillBeLowered() {
        var state = Fixtures.connected(tiles: [Fixtures.alice, Fixtures.bob])
        state.isHandRaised = true
        #expect(state.showsRaiseHandControl)
    }
    
    @Test
    func aThirdPersonBringsTheControlBack() {
        let state = Fixtures.connected(tiles: [Fixtures.alice, Fixtures.bob, Fixtures.carol])
        #expect(!state.isOneToOne)
        #expect(state.showsRaiseHandControl)
    }
    
    @Test
    func hidingAHandKeepsEverythingElse() {
        let tile = Fixtures.tile("Erin", isSpeaking: true, handPosition: 1)
        let hidden = tile.withHandHidden()
        #expect(!hidden.hasHandRaised)
        #expect(hidden.id == tile.id && hidden.isSpeaking)
    }
}

/// Mic, camera, audio, the hand and hang-up are the bar a host ships with screen share off, which
/// Element X does. The next control has to bring the `…` sheet with it rather than clip the bar on
/// the smallest phone (009 R17).
@Suite("Control bar length")
@MainActor
struct ControlBarLengthTests {
    static let smallestPhoneShortSide: CGFloat = 375
    
    @Test(arguments: [Axis.horizontal, .vertical])
    func theShippedBarFitsTheSmallestPhone(axis: Axis) {
        #expect(ElementCallControlsView.length(controls: 5, along: axis) <= Self.smallestPhoneShortSide)
    }
}

/// Until the fake holds a request. Bounded, so a request that never arrives fails rather than hangs.
@MainActor
func waitForPendingRequest(on rtcCall: FakeRtcCall) async throws {
    for _ in 0..<1000 where !rtcCall.hasPendingRequest {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(rtcCall.hasPendingRequest)
}
