//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Foundation
import MatrixRtc
import Synchronization
import Testing

/// Pins the core's Matrix backend: each send reaches exactly one call on the right room, cancel and
/// restart are never swapped, failures carry what the homeserver said, every to-device recipient gets
/// a verdict, and a room subscription delivers each subject's current set, an empty one included.
@Suite(.timeLimit(.minutes(1)))
nonisolated struct MatrixRTCBackendTests {
    private let transport = RecordingTransport()
    private let room = RecordingRoom(roomID: "!r")
    
    private func makeBackend() -> MatrixRTCBackend {
        let backend = MatrixRTCBackend(transport: transport)
        backend.register(room)
        return backend
    }
    
    @Test
    func cancelAndRestartAreNotSwapped() async throws {
        let backend = makeBackend()
        
        try await backend.cancelDelayedEvent(roomId: "!r", delayId: "d1")
        try await backend.restartDelayedEvent(roomId: "!r", delayId: "d2")
        
        #expect(room.log.withLock { $0 } == ["update d1:cancel", "update d2:restart"])
    }
    
    @Test
    func stickyEventPassesContentAndDurationThroughVerbatim() async throws {
        let backend = makeBackend()
        
        let eventID = try await backend.sendStickyEvent(roomId: "!r", eventType: "org.matrix.msc4143.rtc.member", contentJson: "{\"a\":1}", durationMs: 7_200_000)
        
        #expect(eventID == "$sticky")
        #expect(room.log.withLock { $0 } == ["sticky org.matrix.msc4143.rtc.member|{\"a\":1}|7200000"])
    }
    
    /// A state key makes it a delayed state event; without one it is message-like.
    @Test
    func delayedEventsKeepTheirStateKey() async throws {
        let backend = makeBackend()
        
        _ = try await backend.sendDelayedEvent(roomId: "!r", eventType: "org.matrix.msc3401.call.member", stateKey: "_@alice:example.org_ALICE", contentJson: "{}", delayMs: 20000)
        _ = try await backend.sendDelayedEvent(roomId: "!r", eventType: "m.rtc.member", stateKey: nil, contentJson: "{}", delayMs: 20000)
        
        #expect(room.log.withLock { $0 } == ["delayed org.matrix.msc3401.call.member|_@alice:example.org_ALICE", "delayed m.rtc.member|nil"])
    }
    
    /// Which refusals retire the delayed leave is the core's call, so it gets the homeserver's words.
    @Test
    func homeserverRefusalCarriesErrcodeAndStatus() async {
        room.delayedEventError.withLock { $0 = .failed("Unrecognized request", errcode: "M_UNRECOGNIZED", httpStatus: 404) }
        let backend = makeBackend()
        
        do {
            _ = try await backend.sendDelayedEvent(roomId: "!r", eventType: "m.rtc.member", stateKey: nil, contentJson: "{}", delayMs: 20000)
            Issue.record("the send should have failed")
        } catch let FfiBackendError.Failed(errcode, status, reason) {
            #expect(errcode == "M_UNRECOGNIZED")
            #expect(status == 404)
            #expect(reason == "sendDelayedEvent(m.rtc.member): Unrecognized request")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
    
    @Test
    func aRoomThatIsNotOpenFailsAsABackendError() async {
        let backend = makeBackend()
        backend.unregister(roomID: "!r")
        
        await #expect(throws: FfiBackendError.self) {
            _ = try await backend.sendStateEvent(roomId: "!r", eventType: "m.room.topic", stateKey: "", contentJson: "{}")
        }
    }
    
    @Test
    func toDeviceReportsOneVerdictPerRecipient() async throws {
        transport.toDeviceFailures.withLock { $0 = ["@bob:example.org": ["DEV2"]] }
        let backend = makeBackend()
        
        let deliveries = try await backend.sendToDeviceMessage(recipients: [.init(userId: "@bob:example.org", deviceId: "DEV1"),
                                                                            .init(userId: "@bob:example.org", deviceId: "DEV2"),
                                                                            .init(userId: "@carol:example.org", deviceId: "DEV3")],
                                                               messageType: "org.matrix.msc4143.rtc.encryption_key",
                                                               contentJson: "{}")
        
        #expect(deliveries.map(\.deviceId) == ["DEV1", "DEV2", "DEV3"])
        #expect(deliveries.map { $0.error == nil } == [true, false, true])
        #expect(transport.toDeviceMessages.withLock { $0 } == ["@bob:example.org": ["DEV1": "{}", "DEV2": "{}"], "@carol:example.org": ["DEV3": "{}"]])
    }
    
    /// The core waits for one delivery of every subject before the room is ready, so an empty set
    /// is delivered like any other.
    @Test
    func aRoomSubscriptionDeliversEverySubjectsCurrentSetEmptyIncluded() async throws {
        let member = ElementCallRoomEvent(eventID: "$m", sender: "@bob:example.org", eventType: "org.matrix.msc3401.call.member",
                                          stateKey: "_@bob:example.org_BOB", originServerTimestamp: 1, contentJSON: "{}", encryptionInfo: nil)
        room.state.withLock { $0 = ["org.matrix.msc3401.call.member": [member]] }
        let backend = makeBackend()
        let sink = RecordingRoomSink()
        
        let subscription = try backend.forwardRoom(roomID: "!r",
                                                   subjects: FfiRoomSubjects(stateEventTypes: ["org.matrix.msc3401.call.member", "m.rtc.slot"],
                                                                             timelineEventTypes: []),
                                                   into: sink)
        defer { subscription.cancel() }
        
        let delivered = await sink.next(5)
        #expect(Set(delivered) == ["sticky 0",
                                   #"state org.matrix.msc3401.call.member ["$m"]"#,
                                   "state m.rtc.slot []",
                                   #"members ["@alice:example.org"]"#,
                                   "encryption true"])
    }
    
    @Test
    func cancellingTheSubscriptionEndsEveryFeedAndIsIdempotent() async throws {
        let backend = makeBackend()
        let subscription = try backend.forwardRoom(roomID: "!r",
                                                   subjects: FfiRoomSubjects(stateEventTypes: [], timelineEventTypes: ["m.reaction"]),
                                                   into: RecordingRoomSink())
        // sticky, members, encryption, timeline, redactions.
        await room.waitForSubscribers(5)
        
        subscription.cancel()
        subscription.cancel()
        
        await room.waitForSubscribers(0)
    }
    
    /// Nil means the client did not say, and stays nil: "encrypted" is not "cross-signed".
    @Test
    func toDeviceCrossSigningIsPassedOnAsReported() async throws {
        let backend = makeBackend()
        let sink = RecordingToDeviceSink()
        let subscription = backend.forwardToDevice(eventTypes: ["io.element.call.encryption_keys"], into: sink)
        defer { subscription.cancel() }
        
        transport.toDevice.yield(MatrixRTCToDeviceMessage(eventType: "io.element.call.encryption_keys", attestedSenderID: "@bob:example.org",
                                                          senderDeviceID: "BOB", isSenderCrossSigned: nil, wasEncrypted: true, contentJSON: "{}"))
        
        let message = try #require(await sink.next())
        #expect(message.sender == "@bob:example.org")
        #expect(message.encryption == FfiEventEncryption(encrypted: true, senderDeviceId: "BOB", senderCrossSigned: nil))
    }
    
    @Test
    func transportsComeVerbatimFromTheRoomOpenedLast() async throws {
        let backend = makeBackend()
        let later = RecordingRoom(roomID: "!later", transports: #"[{"type":"livekit","livekit_service_url":"https://later.example.org"}]"#)
        backend.register(later)
        
        #expect(try await backend.rtcTransports() == #"[{"type":"livekit","livekit_service_url":"https://later.example.org"}]"#)
        backend.unregister(roomID: "!later")
        #expect(try await backend.rtcTransports() == room.transports)
    }
}

// MARK: - Fakes

private final nonisolated class RecordingTransport: ElementCallMatrixTransportProtocol {
    let userID = "@alice:example.org"
    let deviceID = "ALICE"
    let toDeviceMessages = Mutex([String: [String: String]]())
    let toDeviceFailures = Mutex([String: [String]]())
    let toDevice: AsyncStream<MatrixRTCToDeviceMessage>.Continuation
    private let toDeviceStream: AsyncStream<MatrixRTCToDeviceMessage>
    
    init() {
        (toDeviceStream, toDevice) = AsyncStream.makeStream()
    }
    
    func openRoom(roomID: String) async throws -> any ElementCallMatrixRoomProtocol {
        RecordingRoom(roomID: roomID)
    }
    
    func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async throws -> [String: [String]] {
        toDeviceMessages.withLock { $0 = messages }
        return toDeviceFailures.withLock { $0 }
    }
    
    func toDeviceMessages(eventTypes: [String]) -> AsyncStream<MatrixRTCToDeviceMessage> {
        toDeviceStream
    }
    
    func requestOpenIDToken() async throws -> MatrixRTCOpenIDToken {
        .init(accessToken: "t", tokenType: "Bearer", matrixServerName: "example.org", expiresIn: 60)
    }
}

/// Records every send; each feed delivers its current value and then stays open until cancelled,
/// as a real room's does.
private final nonisolated class RecordingRoom: ElementCallMatrixRoomProtocol {
    let roomID: String
    let transports: String
    let log = Mutex([String]())
    let state = Mutex([String: [ElementCallRoomEvent]]())
    let delayedEventError = Mutex<MatrixRTCTransportError?>(nil)
    private let subscribers = Mutex(0)
    
    init(roomID: String, transports: String = #"[{"type":"livekit","livekit_service_url":"https://sfu.example.org"}]"#) {
        self.roomID = roomID
        self.transports = transports
    }
    
    /// Until the number of open feeds reaches `count`.
    func waitForSubscribers(_ count: Int) async {
        while subscribers.withLock({ $0 }) != count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    
    private func feed<Value: Sendable>(_ current: Value?) -> AsyncStream<Value> {
        AsyncStream { continuation in
            subscribers.withLock { $0 += 1 }
            if let current {
                continuation.yield(current)
            }
            continuation.onTermination = { _ in self.subscribers.withLock { $0 -= 1 } }
        }
    }
    
    func isEncrypted() -> AsyncStream<Bool> {
        feed(true)
    }
    
    func joinedMemberIDs() -> AsyncStream<[String]> {
        feed(["@alice:example.org"])
    }
    
    func stickyEvents() -> AsyncStream<[ElementCallRoomEvent]> {
        feed([])
    }
    
    func stateEvents(eventType: String) -> AsyncStream<[ElementCallRoomEvent]> {
        feed(state.withLock { $0[eventType, default: []] })
    }
    
    func timelineEvents(eventTypes: [String]) -> AsyncStream<[ElementCallRoomEvent]> {
        feed(nil)
    }
    
    func redactions() -> AsyncStream<String> {
        feed(nil)
    }
    
    func relations(eventID: String, relType: String, eventType: String) async throws -> [ElementCallRoomEvent] {
        []
    }
    
    func rtcTransports() async throws -> String {
        transports
    }
    
    func sendStateEvent(eventType: String, stateKey: String, contentJSON: String) async throws -> String {
        log.withLock { $0.append("state \(eventType)") }
        return "$state"
    }
    
    func sendStickyEvent(eventType: String, contentJSON: String, durationMs: UInt64) async throws -> String {
        log.withLock { $0.append("sticky \(eventType)|\(contentJSON)|\(durationMs)") }
        return "$sticky"
    }
    
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async throws -> String {
        if let error = delayedEventError.withLock({ $0 }) {
            throw error
        }
        log.withLock { $0.append("delayed \(eventType)|\(stateKey ?? "nil")") }
        return "delay"
    }
    
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async throws {
        log.withLock { $0.append("update \(delayID):\(action)") }
    }
    
    func sendRoomEvent(eventType: String, contentJSON: String) async throws -> String {
        "$event"
    }
    
    func redactEvent(eventID: String, reason: String?) async throws { }
    
    func close() async { }
}

/// Each delivery as a line, in arrival order.
private final nonisolated class RecordingRoomSink: RoomSubjectSink {
    private let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    
    init() {
        (lines, continuation) = AsyncStream.makeStream()
    }
    
    func next(_ count: Int) async -> [String] {
        var iterator = lines.makeAsyncIterator()
        var result = [String]()
        while result.count < count, let line = await iterator.next() {
            result.append(line)
        }
        return result
    }
    
    func onStickyEvents(events: [FfiEventIn]) {
        continuation.yield("sticky \(events.count)")
    }
    
    func onStateEvents(eventType: String, events: [FfiEventIn]) {
        continuation.yield("state \(eventType) \(events.map(\.eventId))")
    }
    
    func onJoinedMembers(userIds: [String]) {
        continuation.yield("members \(userIds)")
    }
    
    func onEncryption(encrypted: Bool) {
        continuation.yield("encryption \(encrypted)")
    }
    
    func onTimelineEvents(events: [FfiEventIn]) {
        continuation.yield("timeline \(events.map(\.eventId))")
    }
    
    func onRedaction(eventId: String) {
        continuation.yield("redaction \(eventId)")
    }
}

private final nonisolated class RecordingToDeviceSink: ToDeviceSubjectSink {
    private let messages: AsyncStream<FfiToDeviceMessageIn>
    private let continuation: AsyncStream<FfiToDeviceMessageIn>.Continuation
    
    init() {
        (messages, continuation) = AsyncStream.makeStream()
    }
    
    func next() async -> FfiToDeviceMessageIn? {
        var iterator = messages.makeAsyncIterator()
        return await iterator.next()
    }
    
    func onToDeviceMessage(message: FfiToDeviceMessageIn) {
        continuation.yield(message)
    }
}
