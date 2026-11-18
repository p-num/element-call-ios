//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
@testable import ElementCallKit
import Foundation
import Testing

/// The two reactions switches: kept on the device, both on until changed, the sound one remembered
/// while reactions are hidden, and applied to the call in progress (037 R15; 043 R6, R7, R8).
@Suite("Reactions preference")
@MainActor
struct ReactionsPreferenceTests {
    @Test
    func bothSwitchesStartOn() throws {
        let store = try ElementCallUserDefaultsPreferencesStore(defaults: freshDefaults())
        #expect(store.showsReactions)
        #expect(store.playsReactionSounds)
    }
    
    @Test
    func aChoiceIsKept() throws {
        let defaults = try freshDefaults()
        ElementCallUserDefaultsPreferencesStore(defaults: defaults).showsReactions = false
        ElementCallUserDefaultsPreferencesStore(defaults: defaults).playsReactionSounds = false
        #expect(!ElementCallUserDefaultsPreferencesStore(defaults: defaults).showsReactions)
        #expect(!ElementCallUserDefaultsPreferencesStore(defaults: defaults).playsReactionSounds)
    }
    
    /// 043's non-goal: the three-way setting that came before is not carried over. Reading it would
    /// be the migration the spec declined, so an Off from before starts with both switches on.
    @Test
    func theThreeWaySettingFromBeforeIsIgnored() throws {
        let defaults = try freshDefaults()
        defaults.set("off", forKey: "io.element.call.preferences.reactions")
        let store = ElementCallUserDefaultsPreferencesStore(defaults: defaults)
        #expect(store.showsReactions)
        #expect(store.playsReactionSounds)
    }
    
    @Test
    func theSoundEffectsVolumeStartsAtHalfAndIsKept() throws {
        let defaults = try freshDefaults()
        #expect(ElementCallUserDefaultsPreferencesStore(defaults: defaults).soundEffectsVolume == 0.5)
        ElementCallUserDefaultsPreferencesStore(defaults: defaults).soundEffectsVolume = 0.8
        #expect(ElementCallUserDefaultsPreferencesStore(defaults: defaults).soundEffectsVolume == 0.8)
        ElementCallUserDefaultsPreferencesStore(defaults: defaults).soundEffectsVolume = 3
        #expect(ElementCallUserDefaultsPreferencesStore(defaults: defaults).soundEffectsVolume == 1)
    }
    
    @Test
    func theControllerKeepsTheVolume() {
        let store = ElementCallFakePreferencesStore(soundEffectsVolume: 0.2)
        let controller = controller(store)
        #expect(controller.soundEffectsVolume == 0.2)
        controller.setSoundEffectsVolume(0.7)
        #expect(store.soundEffectsVolume == 0.7)
    }
    
    /// R7: what plays follows both switches, and nothing plays without bubbles whatever the sound
    /// switch says.
    @Test(arguments: [(true, true, MatrixRTCReactionsMode.withSound),
                      (true, false, .withoutSound),
                      (false, true, .off),
                      (false, false, .off)])
    func theModeFollowsBothSwitches(shows: Bool, plays: Bool, mode: MatrixRTCReactionsMode) {
        let controller = controller(ElementCallFakePreferencesStore(showsReactions: shows, playsReactionSounds: plays))
        #expect(controller.reactionsMode == mode)
    }
    
    @Test
    func theControllerStartsFromTheStoreAndWritesItBack() {
        let store = ElementCallFakePreferencesStore(showsReactions: false)
        let controller = controller(store)
        #expect(!controller.showsReactions)
        controller.setShowsReactions(true)
        #expect(controller.showsReactions)
        #expect(store.showsReactions)
        controller.setPlaysReactionSounds(false)
        #expect(!store.playsReactionSounds)
    }
    
    /// R7: greyed while reactions are hidden, and keeping its position, so it comes back as it was.
    @Test
    func theSoundSwitchIsHeldWhileReactionsAreHidden() {
        let store = ElementCallFakePreferencesStore(showsReactions: true, playsReactionSounds: false)
        let controller = controller(store)
        controller.setShowsReactions(false)
        controller.setPlaysReactionSounds(true)
        #expect(!controller.playsReactionSounds)
        #expect(!store.playsReactionSounds)
        controller.setShowsReactions(true)
        #expect(controller.reactionsMode == .withoutSound)
    }
    
    /// 037 R15: at once, in the call in progress.
    @Test
    func aChangeReachesTheCallInProgress() {
        let clock = MatrixRTCManualClock()
        let session = MatrixRTCMediaSession(localMemberID: "@alice:example.com:DEVICE",
                                            mediaSession: MatrixRTCScriptedSession(localMemberID: "@alice:example.com:DEVICE", clock: clock),
                                            clock: clock,
                                            capturesCamera: false)
        let controller = controller(ElementCallFakePreferencesStore(playsReactionSounds: false))
        controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(),
                                   connection: .connected,
                                   call: session)
        #expect(session.reactionsMode == .withoutSound)
        controller.setShowsReactions(false)
        #expect(session.reactionsMode == .off)
        controller.setShowsReactions(true)
        controller.setPlaysReactionSounds(true)
        #expect(session.reactionsMode == .withSound)
    }
    
    private func controller(_ store: ElementCallFakePreferencesStore) -> ElementCallController {
        ElementCallController(backend: ElementCallFakeMatrixBackend(),
                              system: ElementCallFakeSystem(),
                              preferences: store,
                              permissions: ElementCallFakeMediaPermissions())
    }
    
    private func freshDefaults() throws -> UserDefaults {
        let name = "ReactionsPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
