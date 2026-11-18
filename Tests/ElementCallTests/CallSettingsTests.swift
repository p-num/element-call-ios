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
import Testing

/// The settings menu's developer side: who reaches it, the membership format and the video codec,
/// each kept on the device and read when a call joins (043 R4, R5, R13–R16a, R18).
@Suite("Call settings")
@MainActor
struct CallSettingsTests {
    private let room = ElementCallFakeRoom(roomID: "!room:example.org")
    private let videoCall = ElementCallData(isAudioCall: false, isStartingCall: true)
    /// Joining, not starting: nothing rings, and nothing reaches the audio engine while the room
    /// never opens (see `HangUpWhileJoiningTests`).
    private let joiningCall = ElementCallData(isAudioCall: true, isStartingCall: false)
    
    // MARK: - The store (R13, R13a, R16)
    
    @Test
    func theFormatStartsInRoomStateAndTheCodecOnAuto() throws {
        let store = try ElementCallUserDefaultsPreferencesStore(defaults: freshDefaults())
        #expect(store.membershipFormat == .roomState)
        #expect(store.videoCodec == .auto)
    }
    
    @Test
    func theFormatAndTheCodecAreKept() throws {
        let defaults = try freshDefaults()
        ElementCallUserDefaultsPreferencesStore(defaults: defaults).membershipFormat = .msc
        ElementCallUserDefaultsPreferencesStore(defaults: defaults).videoCodec = .h264
        #expect(ElementCallUserDefaultsPreferencesStore(defaults: defaults).membershipFormat == .msc)
        #expect(ElementCallUserDefaultsPreferencesStore(defaults: defaults).videoCodec == .h264)
    }
    
    @Test
    func anUnreadableValueIsTheDefault() throws {
        let defaults = try freshDefaults()
        defaults.set("sticky_2025", forKey: ElementCallUserDefaultsPreferencesStore.membershipFormatKey)
        defaults.set("theora", forKey: ElementCallUserDefaultsPreferencesStore.videoCodecKey)
        let store = ElementCallUserDefaultsPreferencesStore(defaults: defaults)
        #expect(store.membershipFormat == .roomState)
        #expect(store.videoCodec == .auto)
    }
    
    @Test
    func theControllerWritesTheFormatAndTheCodecBack() {
        let store = ElementCallFakePreferencesStore()
        let controller = makeController(store)
        controller.setMembershipFormat(.msc)
        controller.setVideoCodec(.vp9)
        #expect(store.membershipFormat == .msc)
        #expect(store.videoCodec == .vp9)
    }
    
    // MARK: - The codec list (R15)
    
    @Test
    func theCodecsOfferedAreAutoThenWhatTheDeviceEncodes() {
        let codecs = MatrixRTCClient.supportedVideoCodecs()
        #expect(codecs.first == .auto)
        #expect(codecs.count { $0 == .auto } == 1)
        #expect(Set(codecs).count == codecs.count)
    }
    
    /// R16a: read once, at the join; R15: a codec the device does not encode goes out as Auto.
    @Test
    func theCodecIsGivenToTheCallAtTheJoin() async throws {
        let supported = MatrixRTCClient.supportedVideoCodecs()
        let chosen = supported.last { $0 != .auto } ?? .auto
        let store = ElementCallFakePreferencesStore(videoCodec: chosen)
        let controller = makeController(store)
        let session = scriptJoin(controller)
        
        controller.startCall(videoCall, room: room)
        try await waitUntil { controller.call != nil }
        #expect(session.videoCodec == chosen)
        
        // A change now waits for the next join.
        controller.setVideoCodec(.auto)
        #expect(session.videoCodec == chosen)
        await hangUp(controller)
    }
    
    @Test
    func aCodecTheDeviceCannotEncodeGoesOutAsAuto() async throws {
        let supported = MatrixRTCClient.supportedVideoCodecs()
        guard let unsupported = MatrixRTCVideoCodec.allCases.first(where: { !supported.contains($0) }) else { return }
        let store = ElementCallFakePreferencesStore(videoCodec: unsupported)
        let controller = makeController(store)
        let session = scriptJoin(controller)
        
        controller.startCall(videoCall, room: room)
        try await waitUntil { controller.call != nil }
        #expect(session.videoCodec == .auto)
        // Left as it was in the store: nothing is written on the user's behalf.
        #expect(store.videoCodec == unsupported)
        await hangUp(controller)
    }
    
    // MARK: - The format at the join (R13, R14, R18)
    
    /// The room is opened in the stored format. The fake backend never delivers the room, so the
    /// open runs into its 30 second bound, which is the failure R18 is about.
    @Test
    func anMSCJoinThatFailsSaysTheFormatMayBeTheCause() async throws {
        let logger = ElementCallFakeLogger()
        let controller = makeController(ElementCallFakePreferencesStore(membershipFormat: .msc), logger: logger)
        let clock = MatrixRTCManualClock()
        controller.clock = clock
        
        controller.startCall(joiningCall, room: room)
        try await waitForTheRoom(clock)
        #expect(logger.records.contains { $0.message.contains("joining with membership format msc") })
        clock.advance(by: MatrixRTCClient.seedingTimeout + .seconds(1))
        
        try await waitUntil { controller.connection.failure != nil }
        guard case .mscJoinFailed = controller.connection.failure else {
            Issue.record("Expected an MSC join failure, got \(controller.connection)")
            return
        }
        #expect(controller.connection.failure?.title == L10n.failureJoinFailedTitle)
        #expect(controller.connection.failure?.text == L10n.failureJoinMembershipFormat)
        controller.hangUp()
    }
    
    /// R14: the format a call joins with is the one it keeps; R18: only an MSC join blames MSC.
    @Test
    func aFormatChangedWhileJoiningWaitsForTheNextJoin() async throws {
        let logger = ElementCallFakeLogger()
        let store = ElementCallFakePreferencesStore(membershipFormat: .roomState)
        let controller = makeController(store, logger: logger)
        let clock = MatrixRTCManualClock()
        controller.clock = clock
        
        controller.startCall(joiningCall, room: room)
        try await waitForTheRoom(clock)
        #expect(logger.records.contains { $0.message.contains("joining with membership format roomState") })
        controller.setMembershipFormat(.msc)
        clock.advance(by: MatrixRTCClient.seedingTimeout + .seconds(1))
        
        try await waitUntil { controller.connection.failure != nil }
        guard case .other = controller.connection.failure else {
            Issue.record("A Room state join should fail as before, got \(controller.connection)")
            return
        }
        #expect(store.membershipFormat == .msc)
        controller.hangUp()
    }
    
    /// R18a: the way back from a stored MSC, since Developer options is only reachable in a call.
    @Test
    func anMSCFailureOffersRoomStateAndClosesTheCall() throws {
        var sent: [ElementCallScreenViewAction] = []
        let action = try #require(ElementCallView.primaryAction(for: .mscJoinFailed("Join refused")) { sent.append($0) })
        #expect(action.title == L10n.failureUseRoomState)
        action.perform()
        guard sent.count == 2, case .setMembershipFormat(.roomState) = sent[0], case .hangUp = sent[1] else {
            Issue.record("Expected Room state then hang-up, got \(sent)")
            return
        }
    }
    
    /// R18a is MSC's alone: a Room state join that fails offers only Close, as before.
    @Test
    func otherJoinFailuresOfferNoFormatChange() {
        #expect(ElementCallView.primaryAction(for: .joinRefused) { _ in } == nil)
        #expect(ElementCallView.primaryAction(for: .other("Join failed")) { _ in } == nil)
    }
    
    /// The view model passes the choice to the store, so the next join opens in Room state.
    @Test
    func choosingRoomStateFromTheScreenIsKept() {
        let store = ElementCallFakePreferencesStore(membershipFormat: .msc)
        let viewModel = ElementCallScreenViewModel(controller: makeController(store))
        viewModel.context.send(viewAction: .setMembershipFormat(.roomState))
        #expect(store.membershipFormat == .roomState)
    }
    
    // MARK: - The menu and its sheets (R4, R5)
    
    @Test(arguments: [true, false])
    func developerOptionsOpenOnlyInDeveloperMode(isDeveloperModeEnabled: Bool) {
        var state = ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group)
        state.isDeveloperModeEnabled = isDeveloperModeEnabled
        let context = ElementCallScreenContext.harness(state: state)
        context.send(viewAction: .present(.developerOptions))
        #expect((context.viewState.presentedSheet == .developerOptions) == isDeveloperModeEnabled)
    }
    
    @Test
    func theRealScreenRefusesDeveloperOptionsWithoutDeveloperMode() {
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               options: ElementCallOptions(isDeveloperModeEnabled: false),
                                               preferences: ElementCallFakePreferencesStore(),
                                               permissions: ElementCallFakeMediaPermissions())
        let viewModel = ElementCallScreenViewModel(controller: controller)
        viewModel.context.send(viewAction: .present(.developerOptions))
        #expect(viewModel.context.viewState.presentedSheet == nil)
        viewModel.context.send(viewAction: .present(.preferences))
        #expect(viewModel.context.viewState.presentedSheet == .preferences)
    }
    
    /// R5: the settings sheets stay across backgrounding; what was opened for a moment does not.
    @Test
    func onlyTheSettingsSheetsAreSettings() {
        #expect(ElementCallSheet.preferences.isSettings)
        #expect(ElementCallSheet.developerOptions.isSettings)
        #expect(!ElementCallSheet.more.isSettings)
        #expect(!ElementCallSheet.reactions.isSettings)
    }
    
    // MARK: - Support
    
    private func makeController(_ store: ElementCallFakePreferencesStore,
                                logger: ElementCallFakeLogger? = nil) -> ElementCallController {
        ElementCallController(backend: ElementCallFakeMatrixBackend(),
                              system: ElementCallFakeSystem(),
                              options: ElementCallOptions(isDeveloperModeEnabled: true),
                              logger: logger,
                              preferences: store,
                              permissions: ElementCallFakeMediaPermissions())
    }
    
    /// A scripted membership and media, so the join runs everything around them for real.
    private func scriptJoin(_ controller: ElementCallController) -> MatrixRTCMediaSession {
        let scripted = MatrixRTCScriptedCall(roomID: room.roomID, status: .connected(since: .now, isDegraded: false))
        let player = MatrixRTCScenarioPlayer(scenario: MatrixRTCScenario(name: "settings", frames: []))
        controller.scriptedJoin = { (scripted.call, player.call) }
        return player.call
    }
    
    private func hangUp(_ controller: ElementCallController) async {
        controller.hangUp()
        for _ in 0..<1000 where controller.call != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    
    /// Until the room open's bound is asleep on the clock, so the join is waiting for a room that
    /// never comes. The format was read and logged before the open began, and advancing now fires
    /// the bound: advanced any earlier, the bound would sleep from the new time and never fire.
    /// Waited for rather than slept past, since under the whole suite's load the join took more
    /// than 5 s to get there.
    private func waitForTheRoom(_ clock: MatrixRTCManualClock) async throws {
        try await waitUntil(for: .seconds(30)) {
            clock.sleeperDeadlines.contains(MatrixRTCClient.seedingTimeout)
        }
    }
    
    private func waitUntil(for timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let step = Duration.milliseconds(5)
        for _ in 0..<Int(timeout / step) where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
    
    private func freshDefaults() throws -> UserDefaults {
        let name = "CallSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private extension ElementCallConnection {
    var failure: ElementCallFailure? {
        if case .failed(let failure) = self {
            failure
        } else {
            nil
        }
    }
}
