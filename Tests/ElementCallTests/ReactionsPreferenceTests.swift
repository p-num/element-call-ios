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

/// The reactions setting: kept on the device, With sound until changed, and applied to the call in
/// progress (037 R13, R14, R15).
@Suite("Reactions preference")
@MainActor
struct ReactionsPreferenceTests {
    @Test
    func theDefaultIsWithSound() throws {
        let store = try ElementCallUserDefaultsPreferencesStore(defaults: freshDefaults())
        #expect(store.reactions == .withSound)
    }
    
    @Test
    func aChoiceIsKept() throws {
        let defaults = try freshDefaults()
        ElementCallUserDefaultsPreferencesStore(defaults: defaults).reactions = .withoutSound
        #expect(ElementCallUserDefaultsPreferencesStore(defaults: defaults).reactions == .withoutSound)
    }
    
    @Test
    func anUnreadableValueIsTheDefault() throws {
        let defaults = try freshDefaults()
        defaults.set("loud", forKey: ElementCallUserDefaultsPreferencesStore.reactionsKey)
        #expect(ElementCallUserDefaultsPreferencesStore(defaults: defaults).reactions == .withSound)
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
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               preferences: store)
        #expect(controller.soundEffectsVolume == 0.2)
        controller.setSoundEffectsVolume(0.7)
        #expect(store.soundEffectsVolume == 0.7)
    }
    
    @Test
    func theControllerStartsFromTheStoreAndWritesItBack() {
        let store = ElementCallFakePreferencesStore(reactions: .off)
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               preferences: store)
        #expect(controller.reactionsPreference == .off)
        controller.setReactionsPreference(.withSound)
        #expect(controller.reactionsPreference == .withSound)
        #expect(store.reactions == .withSound)
    }
    
    /// R15: at once, in the call in progress.
    @Test
    func aChangeReachesTheCallInProgress() {
        let clock = MatrixRTCManualClock()
        let session = MatrixRTCMediaSession(localMemberID: "@alice:example.com:DEVICE",
                                            mediaSession: MatrixRTCScriptedSession(localMemberID: "@alice:example.com:DEVICE", clock: clock),
                                            clock: clock,
                                            capturesCamera: false)
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               preferences: ElementCallFakePreferencesStore(reactions: .withoutSound))
        controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(),
                                   connection: .connected,
                                   call: session)
        #expect(session.reactionsMode == .withoutSound)
        controller.setReactionsPreference(.off)
        #expect(session.reactionsMode == .off)
    }
    
    private func freshDefaults() throws -> UserDefaults {
        let name = "ReactionsPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
