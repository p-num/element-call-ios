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

/// Answers every Matrix call with nothing. Enough for a controller that never joins, and the
/// starting point for a test that scripts specific answers.
public final nonisolated class ElementCallFakeTransport: ElementCallMatrixTransportProtocol {
    public let userID: String
    public let deviceID: String
    
    public init(userID: String = "@alice:example.org", deviceID: String = "FAKEDEVICE") {
        self.userID = userID
        self.deviceID = deviceID
    }
    
    public func openRoom(roomID: String) async throws -> any ElementCallMatrixRoomProtocol {
        ElementCallFakeMatrixRoom(roomID: roomID, ownUserID: userID)
    }
    
    public func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async throws -> [String: [String]] {
        [:]
    }
    
    public func toDeviceMessages(eventTypes: [String]) -> AsyncStream<MatrixRTCToDeviceMessage> {
        AsyncStream { $0.finish() }
    }
    
    public func requestOpenIDToken() async throws -> MatrixRTCOpenIDToken {
        .init(accessToken: "", tokenType: "Bearer", matrixServerName: "example.org", expiresIn: 3600)
    }
}

/// An encrypted room holding only us, with no call in it and one LiveKit transport on offer. Every
/// feed delivers its current value once, so the core would treat it as ready.
public final nonisolated class ElementCallFakeMatrixRoom: ElementCallMatrixRoomProtocol {
    public let roomID: String
    public let ownUserID: String
    public let transportsJSON: String
    
    public init(roomID: String,
                ownUserID: String,
                transportsJSON: String = #"[{"type":"livekit","livekit_service_url":"https://sfu.example.org"}]"#) {
        self.roomID = roomID
        self.ownUserID = ownUserID
        self.transportsJSON = transportsJSON
    }
    
    public func isEncrypted() -> AsyncStream<Bool> {
        Self.once(true)
    }
    
    public func joinedMemberIDs() -> AsyncStream<[String]> {
        Self.once([ownUserID])
    }
    
    public func stickyEvents() -> AsyncStream<[ElementCallRoomEvent]> {
        Self.once([])
    }
    
    public func stateEvents(eventType: String) -> AsyncStream<[ElementCallRoomEvent]> {
        Self.once([])
    }
    
    public func timelineEvents(eventTypes: [String]) -> AsyncStream<[ElementCallRoomEvent]> {
        AsyncStream { $0.finish() }
    }
    
    public func redactions() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
    
    public func relations(eventID: String, relType: String, eventType: String) async throws -> [ElementCallRoomEvent] {
        []
    }
    
    public func rtcTransports() async throws -> String {
        transportsJSON
    }
    
    public func sendStateEvent(eventType: String, stateKey: String, contentJSON: String) async throws -> String {
        "$event"
    }
    
    public func sendStickyEvent(eventType: String, contentJSON: String, durationMs: UInt64) async throws -> String {
        "$event"
    }
    
    public func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async throws -> String {
        "delay"
    }
    
    public func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async throws { }
    
    public func sendRoomEvent(eventType: String, contentJSON: String) async throws -> String {
        "$event"
    }
    
    public func redactEvent(eventID: String, reason: String?) async throws { }
    
    public func close() async { }
    
    /// A current value and nothing after it. Finishing is fine: a finished feed simply has no
    /// changes to report.
    private static func once<Value: Sendable>(_ value: Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            continuation.yield(value)
            continuation.finish()
        }
    }
}

/// Records what the call asked the system to do, and lets a test push events back.
@MainActor
public final class ElementCallFakeSystem: ElementCallSystemProvidingProtocol {
    public enum Request: Sendable, Equatable {
        case start(roomID: String, displayName: String, isVideo: Bool)
        case connected(roomID: String)
        case end(roomID: String)
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
    
    public func endCall(roomID: String) {
        requests.append(.end(roomID: roomID))
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
        let controller = ElementCallController(rtcClient: MatrixRTCClient(transport: ElementCallFakeTransport()),
                                               system: ElementCallFakeSystem(),
                                               options: options,
                                               style: style,
                                               logger: nil)
        controller.setPreviewState(callData: .init(isAudioCall: isAudioCall, isStartingCall: true),
                                   room: room,
                                   connection: connection,
                                   connectedAt: connectedAt,
                                   call: call)
        return controller
    }
}
