//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementCallHost
@testable import ElementCallKit
@testable import ElementCallUI
import Foundation
import Testing

/// The call screen's side of reactions and the Preferences sheet, through the real view model over a
/// scripted call: who a bubble names, where the sheet's choices go, and when the sheet closes
/// (037 R7, R7a, R12a, R14, R15).
@Suite("Reactions on the call screen")
@MainActor
struct ReactionScreenTests {
    // MARK: - Naming (R7, R7a)
    
    @Test
    func aBubbleIsNamedAsTheSendersTileIs() async throws {
        let screen = try await Screen()
        screen.react(from: "BOB")
        screen.react(from: "CAROL")
        let names = try await screen.bubbleNames(count: 2)
        // Bob has a display name; Carol has none, so her Matrix ID, as on her tile.
        #expect(names == ["Bob", "@carol:example.com"])
    }
    
    /// R7: our own membership is "You"; another device of ours is another tile, so it carries our
    /// name rather than "You".
    @Test
    func oursIsYouAndAnotherDeviceOfOursIsOurName() async throws {
        let screen = try await Screen()
        screen.react(from: Screen.localMemberID)
        screen.react(from: "ME")
        let names = try await screen.bubbleNames(count: 2)
        #expect(names == ["You", "Valère"])
    }
    
    /// R7a: a bubble keeps the name it appeared with; the next one from the same person uses the new
    /// one.
    @Test
    func aRenameMidFlightLeavesTheBubbleAsItWas() async throws {
        let screen = try await Screen()
        screen.react(from: "BOB")
        _ = try await screen.bubbleNames(count: 1)
        
        screen.room.profiles.value["@bob:example.com"] = .init(userID: "@bob:example.com", displayName: "Robert", avatarURL: nil)
        try await waitUntil { screen.viewModel.context.viewState.tiles.contains { $0.displayName == "Robert" } }
        screen.react(from: "BOB")
        
        #expect(try await screen.bubbleNames(count: 2) == ["Bob", "Robert"])
    }
    
    /// R7a: the sender leaving does not rename or drop a bubble already rising.
    @Test
    func aSenderLeavingLeavesTheBubbleNamed() async throws {
        let screen = try await Screen()
        screen.react(from: "BOB")
        _ = try await screen.bubbleNames(count: 1)
        
        screen.scripted.push(roster: [.init(name: "CAROL"), .init(name: "ME")])
        try await waitUntil { !screen.session.tiles.order.contains { $0.userID == "@bob:example.com" } }
        
        #expect(try await screen.bubbleNames(count: 1) == ["Bob"])
    }
    
    // MARK: - The sheet (R12a, R14, R15)
    
    /// R14, R15: a choice in the sheet is kept for the next call and reaches this one at once.
    @Test
    func theSheetsChoicesAreKeptAndApplyToTheCallInProgress() async throws {
        let screen = try await Screen()
        screen.viewModel.context.send(viewAction: .setReactionsPreference(.off))
        screen.viewModel.context.send(viewAction: .setSoundEffectsVolume(0.3))
        
        #expect(screen.preferences.reactions == .off)
        #expect(screen.preferences.soundEffectsVolume == 0.3)
        #expect(screen.session.reactionsMode == .off)
        try await waitUntil { screen.viewModel.context.viewState.reactionsPreference == .off }
        #expect(screen.viewModel.context.viewState.soundEffectsVolume == 0.3)
        
        screen.react(from: "BOB")
        try await Task.sleep(for: .milliseconds(50))
        #expect(screen.viewModel.context.viewState.reactions.isEmpty)
    }
    
    /// R12a: there is nowhere to draw the sheet once the call is minimised, and nothing to come back
    /// to; restoring the call does not bring it back.
    @Test
    func minimisingClosesTheSheetForGood() async throws {
        let screen = try await Screen()
        screen.viewModel.context.send(viewAction: .showPreferences)
        #expect(screen.viewModel.context.viewState.isPreferencesPresented)
        
        screen.controller.setMaximized(false)
        try await waitUntil { !screen.viewModel.context.viewState.isPreferencesPresented }
        screen.controller.setMaximized(true)
        try await waitUntil { screen.viewModel.context.viewState.isMaximized }
        #expect(!screen.viewModel.context.viewState.isPreferencesPresented)
    }
    
    @Test
    func theCallEndingClosesTheSheet() async throws {
        let screen = try await Screen()
        screen.viewModel.context.send(viewAction: .showPreferences)
        
        screen.controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                          room: screen.room, connection: .ended(.left))
        try await waitUntil { !screen.viewModel.context.viewState.isPreferencesPresented }
    }
    
    // MARK: - Support
    
    private final class Room: ElementCallRoomContextProtocol {
        let profiles = CurrentValueSubject<[String: ElementCallMemberProfile], Never>([
            "@bob:example.com": .init(userID: "@bob:example.com", displayName: "Bob", avatarURL: nil),
            "@me:example.com": .init(userID: "@me:example.com", displayName: "Valère", avatarURL: nil)
        ])
        
        let roomID = "!room:example.com"
        let displayName = "Room"
        let isDirect = false
        
        var displayNamePublisher: AnyPublisher<String, Never> {
            Just(displayName).eraseToAnyPublisher()
        }
        
        var isDirectPublisher: AnyPublisher<Bool, Never> {
            Just(isDirect).eraseToAnyPublisher()
        }
        
        var memberProfiles: [String: ElementCallMemberProfile] {
            profiles.value
        }
        
        var memberProfilesPublisher: AnyPublisher<[String: ElementCallMemberProfile], Never> {
            profiles.eraseToAnyPublisher()
        }
    }
    
    /// A connected call with Bob, Carol and another device of ours (`ME`), reactions shown without
    /// sound and with no spread, so a reaction is on screen as soon as it is received.
    private struct Screen {
        static let localMemberID = "@me:example.com:ME"
        
        let clock = MatrixRTCManualClock()
        let scripted: MatrixRTCScriptedSession
        let session: MatrixRTCMediaSession
        let room = Room()
        let preferences = ElementCallFakePreferencesStore(reactions: .withoutSound)
        let controller: ElementCallController
        let viewModel: ElementCallScreenViewModel
        
        init() async throws {
            scripted = MatrixRTCScriptedSession(localMemberID: Self.localMemberID, clock: clock)
            session = MatrixRTCMediaSession(localMemberID: Self.localMemberID,
                                            mediaSession: scripted,
                                            audio: CallAudio(soundEffects: CallSoundEffectRenderer(join: [], leave: [], raiseHand: [])),
                                            clock: clock,
                                            capturesCamera: false,
                                            reactionSpread: { .zero })
            await session.start()
            scripted.push(roster: [.init(name: "BOB"), .init(name: "CAROL"), .init(name: "ME")])
            controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               preferences: preferences)
            controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                       room: room, connection: .connected, call: session)
            viewModel = ElementCallScreenViewModel(controller: controller)
            let session = session
            try await waitUntil { session.tiles.order.count == 3 }
        }
        
        /// From a scenario name (`BOB`) or a full member ID.
        func react(from member: String) {
            let memberID = member.hasPrefix("@") ? member : MatrixRTCScenario.Token(name: member).memberID
            scripted.push(event: .reaction(memberId: memberID, emoji: "👏", name: "clapping", sound: "clap"))
        }
        
        func bubbleNames(count: Int) async throws -> [String] {
            let viewModel = viewModel
            try await waitUntil { viewModel.context.viewState.reactions.count == count }
            return viewModel.context.viewState.reactions.map(\.senderName)
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
}
