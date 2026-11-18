//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
@testable import ElementCallKit
@testable import ElementCallUI
import Foundation
import MatrixRtc
import Testing

/// Sending a reaction, from the bar to the core: what the picker offers, what reaches the core,
/// and what the screen does about a refusal, which is nothing (009 R11, R12, R19, R23).
@Suite("Sending reactions")
@MainActor
struct ReactionSendingTests {
    private func makeScreen() -> (ElementCallScreenViewModel, ElementCallController, FakeRTCCall) {
        let rtcCall = FakeRTCCall()
        let controller = ElementCallController.fake(connection: .connected)
        controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(),
                                   connection: .connected,
                                   rtcCall: MatrixRTCCall(rtcCall: rtcCall))
        return (ElementCallScreenViewModel(controller: controller), controller, rtcCall)
    }
    
    /// R11: the core's catalogue, in its order, which is what web's picker shows.
    @Test
    func thePickerOffersTheCoresCatalogue() {
        #expect(MatrixRTCReactionKind.catalogue.map(\.name) == reactionCatalog().map(\.name))
        #expect(MatrixRTCReactionKind.catalogue.first == MatrixRTCReactionKind(name: "thumbsup", emoji: "👍"))
    }
    
    /// R19: the emoji and its name reach the core, and the picker closes.
    @Test
    func sendingReachesTheCoreAndClosesThePicker() async throws {
        let (viewModel, _, rtcCall) = makeScreen()
        let party = try #require(MatrixRTCReactionKind.catalogue.first { $0.name == "party" })
        viewModel.context.send(viewAction: .present(.reactions))
        #expect(viewModel.context.viewState.presentedSheet == .reactions)
        
        viewModel.context.send(viewAction: .sendReaction(party))
        
        #expect(viewModel.context.viewState.presentedSheet == nil)
        try await waitUntil { !rtcCall.reactions.isEmpty }
        #expect(rtcCall.reactions.map(\.emoji) == ["🎉"])
        #expect(rtcCall.reactions.map(\.name) == ["party"])
    }
    
    /// R12, R23: a send inside the cooldown is refused, and that is not an error the user is told.
    @Test
    func aRefusalShowsNothing() async throws {
        let (viewModel, controller, rtcCall) = makeScreen()
        rtcCall.refuseReactions()
        
        viewModel.context.send(viewAction: .sendReaction(MatrixRTCReactionKind.catalogue[0]))
        try await waitUntil { !rtcCall.reactions.isEmpty }
        try await Task.sleep(for: .milliseconds(20))
        
        #expect(controller.errorMessage == nil)
        #expect(viewModel.context.alertInfo == nil)
    }
    
    /// More hands over to the picker: one presented sheet at a time, changed in place.
    @Test
    func moreOpensThePickerInPlace() {
        let (viewModel, _, _) = makeScreen()
        viewModel.context.send(viewAction: .present(.more))
        viewModel.context.send(viewAction: .present(.reactions))
        #expect(viewModel.context.viewState.presentedSheet == .reactions)
        viewModel.context.send(viewAction: .dismissSheet)
        #expect(viewModel.context.viewState.presentedSheet == nil)
    }
    
    @Test
    func theCallEndingClosesThePicker() async throws {
        let (viewModel, controller, _) = makeScreen()
        viewModel.context.send(viewAction: .present(.reactions))
        
        controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(), connection: .ended(.left))
        try await waitUntil { viewModel.context.viewState.presentedSheet == nil }
    }
}

/// The bar holds six controls at most, and the slot before hang-up is what keeps it there: the
/// single extra action, or `…` over two or more (009 R17).
@Suite("Control bar slot")
@MainActor
struct ControlBarSlotTests {
    typealias Fixtures = ElementCallPreviewFixtures
    
    /// The hand and reactions at least, so always a menu, with the hand first.
    @Test
    func inAGroupTheSlotIsTheMenu() {
        let state = Fixtures.connected(tiles: Fixtures.group)
        #expect(state.barSlot == .more)
        #expect(state.extraActions == [.raisedHand, .reactions])
        #expect(Fixtures.connected(tiles: Fixtures.group, isScreenSharingEnabled: true).extraActions == [.raisedHand, .reactions, .screenShare])
    }
    
    /// No hand and no reactions between two people (009 R33), so screen share alone has the slot.
    @Test
    func betweenTwoTheSlotIsScreenShareOrNothing() {
        let pair = Array(Fixtures.group.prefix(2))
        #expect(Fixtures.connected(tiles: pair).barSlot == nil)
        #expect(Fixtures.connected(tiles: pair, isScreenSharingEnabled: true).barSlot == .action(.screenShare))
    }
    
    /// A hand raised before the call got smaller can still be lowered (009 R2): the hand alone.
    @Test
    func aHandStillUpBetweenTwoKeepsItsButton() {
        var state = Fixtures.connected(tiles: Array(Fixtures.group.prefix(2)))
        state.isHandRaised = true
        #expect(state.barSlot == .action(.raisedHand))
        #expect(state.showsRaisedHandBanner)
    }
    
    @Test
    func theBannerShowsOnlyWhileOurHandIsUp() {
        var state = Fixtures.connected(tiles: Fixtures.group)
        #expect(!state.showsRaisedHandBanner)
        state.isHandRaised = true
        #expect(state.showsRaisedHandBanner)
    }
    
    /// Nothing to relate a reaction to before the join, and no homeserver to send it to in an outage.
    @Test
    func theReactionButtonNeedsAMembershipAndAHomeserver() {
        var state = ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group)
        #expect(state.isReactionControlEnabled)
        state.isSignallingReachable = false
        #expect(!state.isReactionControlEnabled)
        state.isSignallingReachable = true
        state.isHandRaiseAvailable = false
        #expect(!state.isReactionControlEnabled)
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
}
