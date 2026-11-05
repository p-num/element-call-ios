//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCallKit
import Foundation
import Synchronization

// Fakes for every port, shipped in the product rather than the test target on purpose: a host needs
// them for its own previews, and the example harness runs on them.

/// The core's Matrix side, answering every send and never letting a room become ready. A call
/// started through ``ElementCallController/startCall(_:room:)`` stays `.joining`: there is no
/// `MatrixRTCCall`, so no audio engine and no media.
///
/// Never, rather than on request: a room that opens lets the call join for real, and on the
/// simulator the controller then starts the audio engine and dials a LiveKit service that does not
/// exist. That is a host's unit test reaching outside its process, and when the simulator's audio
/// service stops answering, AudioToolbox aborts the whole test run.
///
/// Hang up what a test starts. A hang-up while joining ends the call as `.ended(.left)`; a call
/// nobody hangs up fails after 30 seconds (`MatrixRTCClient.seedingTimeout`) and tells the system
/// port so.
public final nonisolated class ElementCallFakeMatrixBackend: ElementCallMatrixBackendProtocol {
    public let userID: String
    public let deviceID: String
    public let transportsJSON: String
    private let subscribeRoom: @Sendable (String, ElementCallRoomSubjects, ElementCallRoomSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription
    
    public init(userID: String = "@alice:example.org",
                deviceID: String = "FAKEDEVICE",
                transportsJSON: String = #"[{"type":"livekit","livekit_service_url":"https://sfu.example.org"}]"#,
                subscribeRoom: @escaping @Sendable (String, ElementCallRoomSubjects, ElementCallRoomSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription = { _, _, _ in .init() }) {
        self.userID = userID
        self.deviceID = deviceID
        self.transportsJSON = transportsJSON
        self.subscribeRoom = subscribeRoom
    }
    
    public func sendStickyEvent(roomID: String, eventType: String, contentJSON: String, duration: Duration) async throws(ElementCallMatrixBackendError) -> String {
        "$event"
    }
    
    public func sendDelayedStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String, delay: Duration) async throws(ElementCallMatrixBackendError) -> String {
        "delay"
    }
    
    public func sendDelayedStickyEvent(roomID: String, eventType: String, contentJSON: String, stickyDuration: Duration, delay: Duration) async throws(ElementCallMatrixBackendError) -> String {
        "delay"
    }
    
    public func restartDelayedEvent(roomID: String, delayID: String) async throws(ElementCallMatrixBackendError) { }
    
    public func cancelDelayedEvent(roomID: String, delayID: String) async throws(ElementCallMatrixBackendError) { }
    
    public func sendToDeviceMessage(eventType: String, contentJSON: String, to recipients: [ElementCallDevice]) async throws(ElementCallMatrixBackendError) -> [ElementCallDevice: String] {
        [:]
    }
    
    public func sendStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String) async throws(ElementCallMatrixBackendError) -> String {
        "$event"
    }
    
    public func sendRoomEvent(roomID: String, eventType: String, contentJSON: String) async throws(ElementCallMatrixBackendError) -> String {
        "$event"
    }
    
    public func redactEvent(roomID: String, eventID: String, reason: String?) async throws(ElementCallMatrixBackendError) { }
    
    /// Delivers nothing, which the core reads as a room still loading. It has no deadline of its own
    /// for that, so the room never becomes ready.
    public func subscribeToRoom(roomID: String, subjects: ElementCallRoomSubjects, sink: ElementCallRoomSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription {
        try subscribeRoom(roomID, subjects, sink)
    }
    
    public func subscribeToDeviceMessages(eventTypes: [String], sink: ElementCallToDeviceSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription {
        ElementCallBackendSubscription()
    }
    
    public func relations(roomID: String, eventID: String, relationshipType: String, eventType: String) async throws(ElementCallMatrixBackendError) -> [ElementCallMatrixEvent] {
        []
    }
    
    public func openIDToken() async throws(ElementCallMatrixBackendError) -> ElementCallOpenIDToken {
        ElementCallOpenIDToken(accessToken: "", tokenType: "Bearer", matrixServerName: "example.org", expiresIn: .seconds(3600))
    }
    
    public func liveKitToken(for request: ElementCallLiveKitTokenRequest) async throws(ElementCallMatrixBackendError) -> String {
        "jwt-for-\(request.url)"
    }
    
    public func rtcTransportsJSON() async throws(ElementCallMatrixBackendError) -> String {
        transportsJSON
    }
}

/// Records what the call asked the system to do, and lets a test push events back.
@MainActor
public final class ElementCallFakeSystem: ElementCallSystemProvidingProtocol {
    public enum Request: Sendable, Equatable {
        case start(roomID: String, displayName: String, isVideo: Bool)
        case connected(roomID: String)
        case disconnected(roomID: String)
        case end(roomID: String, reason: ElementCallEndReason)
        case microphone(enabled: Bool, roomID: String)
    }
    
    public private(set) var requests: [Request] = []
    private let subject = PassthroughSubject<ElementCallSystemEvent, Never>()
    
    public init() { }
    
    public var events: AnyPublisher<ElementCallSystemEvent, Never> {
        subject.eraseToAnyPublisher()
    }
    
    public func send(_ event: ElementCallSystemEvent) {
        subject.send(event)
    }
    
    public func startCall(roomID: String, displayName: String, isVideo: Bool) async {
        requests.append(.start(roomID: roomID, displayName: displayName, isVideo: isVideo))
    }
    
    public func reportConnected(roomID: String) {
        requests.append(.connected(roomID: roomID))
    }
    
    public func reportDisconnected(roomID: String) {
        requests.append(.disconnected(roomID: roomID))
    }
    
    public func endCall(roomID: String, reason: ElementCallEndReason) {
        requests.append(.end(roomID: roomID, reason: reason))
    }
    
    public func setMicrophoneEnabled(_ enabled: Bool, roomID: String) {
        requests.append(.microphone(enabled: enabled, roomID: roomID))
    }
}

/// A fixed room, with publishers that never emit because nothing about it changes.
@MainActor
public final class ElementCallFakeRoom: ElementCallRoomContextProtocol {
    public let roomID: String
    public let displayName: String
    public let isDirect: Bool
    public let memberProfiles: [String: ElementCallMemberProfile]
    
    public init(roomID: String = "!room:example.org",
                displayName: String = "Product | Lobby",
                isDirect: Bool = false,
                memberProfiles: [String: ElementCallMemberProfile] = [:]) {
        self.roomID = roomID
        self.displayName = displayName
        self.isDirect = isDirect
        self.memberProfiles = memberProfiles
    }
    
    public var displayNamePublisher: AnyPublisher<String, Never> {
        Just(displayName).eraseToAnyPublisher()
    }
    
    public var isDirectPublisher: AnyPublisher<Bool, Never> {
        Just(isDirect).eraseToAnyPublisher()
    }
    
    public var memberProfilesPublisher: AnyPublisher<[String: ElementCallMemberProfile], Never> {
        Just(memberProfiles).eraseToAnyPublisher()
    }
}

/// Keeps every line, so a test can assert on what was logged.
public final nonisolated class ElementCallFakeLogger: ElementCallLoggingProtocol {
    private let recorded = Mutex<[ElementCallLogRecord]>([])
    
    public init() { }
    
    public var messages: [String] {
        recorded.withLock { $0.map(\.message) }
    }
    
    /// The whole records, for a test that cares where a line came from.
    public var records: [ElementCallLogRecord] {
        recorded.withLock { $0 }
    }
    
    public func log(_ record: ElementCallLogRecord) {
        recorded.withLock { $0.append(record) }
    }
}

/// Preferences held in memory, so a preview or the harness never writes the device's.
public final class ElementCallFakePreferencesStore: ElementCallPreferencesStoreProtocol {
    public var reactions: ElementCallReactionsPreference
    public var soundEffectsVolume: Float
    
    public init(reactions: ElementCallReactionsPreference = .withSound, soundEffectsVolume: Float = 0.5) {
        self.reactions = reactions
        self.soundEffectsVolume = soundEffectsVolume
    }
}

public extension ElementCallController {
    /// A controller with faked dependencies, for previews and snapshot tests. Never joins anything.
    static func fake(connection: ElementCallConnection,
                     room: any ElementCallRoomContextProtocol = ElementCallFakeRoom(),
                     isAudioCall: Bool = false,
                     // Placed after `isAudioCall` so no existing positional meaning shifts. A
                     // preview must leave this nil, for the reason `ElementCallPreviewFixtures`
                     // gives: a duration renders as a live counting timer, so any snapshot of one
                     // differs on every run. The example harness is not snapshotted, so it may.
                     connectedAt: Date? = nil,
                     // Everything on, like the preview fixtures: a fake host is a host that
                     // supports the lot, so a preview covers the fullest chrome. Pass an explicit
                     // value to exercise a gate.
                     options: ElementCallOptions = ElementCallOptions(isDeveloperModeEnabled: true,
                                                                      isScreenSharingEnabled: true),
                     style: ElementCallStyle = .stock,
                     // A scripted call (`MatrixRTCScenarioPlayer`), so a real view model can run
                     // over a controller that never joined. Nil for the stills the previews want.
                     call: MatrixRTCMediaSession? = nil) -> ElementCallController {
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               options: options,
                                               style: style,
                                               logger: nil,
                                               preferences: ElementCallFakePreferencesStore())
        controller.setPreviewState(callData: .init(isAudioCall: isAudioCall, isStartingCall: true),
                                   room: room,
                                   connection: connection,
                                   connectedAt: connectedAt,
                                   call: call)
        return controller
    }
    
    /// The example harness only: a controller in a call whose status a `MatrixRTCScriptedCall`
    /// plays, followed exactly as a joined call is, so the screen, the sounds and the end of the
    /// call are the shipping ones. `call` is the scripted media session that supplies the tiles.
    ///
    /// There is no CallKit here to activate the audio session, so this does, on a device too: the
    /// ringback and the end sounds are what the harness is for.
    static func fake(following rtcCall: MatrixRTCCall,
                     room: any ElementCallRoomContextProtocol,
                     isAudioCall: Bool,
                     call: MatrixRTCMediaSession?) -> ElementCallController {
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               options: ElementCallOptions(isDeveloperModeEnabled: true),
                                               style: .stock,
                                               logger: nil,
                                               preferences: ElementCallFakePreferencesStore())
        controller.setPreviewState(callData: .init(isAudioCall: isAudioCall, isStartingCall: true),
                                   room: room,
                                   connection: .joining,
                                   call: call,
                                   rtcCall: rtcCall)
        controller.follow(rtcCall, roomID: room.roomID)
        // What `startCall` follows besides the call, which this never reaches: without it the
        // screen's indicator, read from the held list, never came up in an outage fixture.
        controller.followInterruptions()
        // What `publishMedia` does once a joined call's media is up, which this never reaches: a
        // video call starts with the camera on.
        if !isAudioCall, let call {
            Task { try? await call.setCameraEnabled(true) }
        }
        do {
            try CallAudioSessionConfigurator.configure()
            try CallAudioSessionConfigurator.activate()
            controller.audioSessionDidActivate()
        } catch {
            controller.errorMessage = "Could not activate the audio session: \(error)"
        }
        return controller
    }
}
