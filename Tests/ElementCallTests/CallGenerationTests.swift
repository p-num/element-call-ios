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
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CallGenerationTests {
    @Test(arguments: [true, false])
    func cameraPermissionIsBoundToTheCallEvenWhenItsMediaDidNotExistYet(replaceCall: Bool) async throws {
        let room = ElementCallFakeRoom()
        let controller = makeController(transport: HeldTransport())
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: room, connection: .joining)
        let generation = controller.callGeneration
        let permission = HeldReply<Bool>()
        let toggle = Task {
            await controller.setCameraEnabled(true, generation: generation,
                                              cameraAccess: { await (try? permission.wait()) ?? false })
        }
        defer { permission.answer(true) }
        try await waitUntil { permission.isPending }
        
        let media = MatrixRTCMediaSession(localMemberID: "me", mediaSession: FakeMediaSession(), capturesCamera: false)
        if replaceCall {
            // Exactly the same room context can be reused by another call after A ended.
            controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                       room: room, connection: .connected, call: media)
        } else {
            // A nil media session becoming available is still the original call.
            controller.installMediaSession(media)
        }
        permission.answer(true)
        await toggle.value
        #expect(media.isCameraEnabled == !replaceCall)
        #expect((controller.callGeneration != generation) == replaceCall)
        await media.disconnect()
    }
    
    @Test(arguments: [true, false])
    func aCameraOffRequestSupersedesAnEarlierPendingPermission(turnOffWhilePermissionIsPending: Bool) async throws {
        let transport = FakeMediaSession()
        let media = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
        let controller = makeController(transport: HeldTransport())
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: ElementCallFakeRoom(), connection: .connected, call: media)
        let generation = controller.callGeneration
        let permission = HeldReply<Bool>()
        let enabling = Task {
            await controller.setCameraEnabled(true, generation: generation,
                                              cameraAccess: { await (try? permission.wait()) ?? false })
        }
        defer { permission.answer(true) }
        try await waitUntil { permission.isPending }
        #expect(transport.published.isEmpty)
        
        if turnOffWhilePermissionIsPending {
            await controller.setCameraEnabled(false, generation: generation)
        }
        #expect(!media.isCameraEnabled)
        #expect(!transport.localMutes.contains { $0.kind == .camera && !$0.muted })
        
        permission.answer(true)
        await enabling.value
        #expect(media.isCameraEnabled == !turnOffWhilePermissionIsPending)
        #expect(transport.published.count == (turnOffWhilePermissionIsPending ? 0 : 1))
        let didUnmuteCamera = transport.appliedLocalMutes.contains { $0.kind == .camera && !$0.muted }
        #expect(didUnmuteCamera == !turnOffWhilePermissionIsPending)
        await media.disconnect()
    }
    
    @Test
    func aLateSystemStartDoesNotOpenARoomForTheReplacement() async throws {
        let transport = HeldTransport()
        let system = HeldSystem()
        let controller = makeController(transport: transport, system: system)
        let room = ElementCallFakeRoom()
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false), room: room, connection: .joining)
        let generation = controller.callGeneration
        let joining = Task {
            await controller.joinCall(for: .init(isAudioCall: true, isStartingCall: false), room: room, generation: generation)
        }
        defer { system.start.answer(()) }
        try await waitUntil { system.start.isPending }
        let replacement = replaceCall(controller, in: room)
        system.start.answer(())
        #expect(await joining.value == nil)
        #expect(transport.openCount == 0)
        #expect(controller.rtcCall === replacement)
        #expect(controller.connection == .connected)
    }
    
    @Test(arguments: [true, false])
    func aLateRoomOpenOrErrorCannotReplaceOrFailTheCurrentCall(fails: Bool) async throws {
        let transport = HeldTransport(holdsOpen: true)
        let controller = makeController(transport: transport)
        let room = ElementCallFakeRoom()
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false), room: room, connection: .joining)
        let generation = controller.callGeneration
        let joining = Task {
            await controller.joinCall(for: .init(isAudioCall: true, isStartingCall: false), room: room, generation: generation)
        }
        let opened = HeldMatrixRoom(roomID: room.roomID)
        defer { transport.open.answer(opened) }
        try await waitUntil { transport.open.isPending }
        let replacement = replaceCall(controller, in: room)
        if fails {
            transport.open.fail()
        } else {
            transport.open.answer(opened)
        }
        #expect(await joining.value == nil)
        #expect(controller.rtcCall === replacement)
        #expect(controller.connection == .connected)
        #expect(controller.errorMessage == nil)
        if !fails {
            #expect(opened.closeCount == 1)
        }
    }
    
    @Test
    func aCancelledTransportOpenClosesItsRoomWithoutStartingTheCore() async throws {
        let transport = HeldTransport(holdsOpen: true)
        let client = MatrixRTCClient(transport: transport)
        let opening = Task { try await client.room(roomID: "!late:example.org", format: .roomState) }
        let opened = HeldMatrixRoom(roomID: "!late:example.org")
        defer { transport.open.answer(opened) }
        try await waitUntil { transport.open.isPending }
        opening.cancel()
        transport.open.answer(opened)
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(opened.closeCount == 1)
        #expect(opened.subscriptionCount == 0)
    }
    
    @Test(arguments: [true, false])
    func aLateMembershipJoinOrErrorCannotReplaceOrFailTheCurrentCall(fails: Bool) async throws {
        let room = ElementCallFakeRoom()
        let matrixRoom = HeldMatrixRoom(roomID: room.roomID, holdsJoin: true)
        let transport = HeldTransport(room: matrixRoom)
        let controller = makeController(transport: transport)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false), room: room, connection: .joining)
        let generation = controller.callGeneration
        let joining = Task {
            await controller.joinCall(for: .init(isAudioCall: true, isStartingCall: false), room: room, generation: generation)
        }
        defer { matrixRoom.publication.answer("$membership") }
        try await waitUntil { matrixRoom.publication.isPending }
        let replacement = replaceCall(controller, in: room)
        if fails {
            matrixRoom.publication.fail()
        } else {
            matrixRoom.publication.answer("$membership")
        }
        #expect(await joining.value == nil)
        #expect(controller.rtcCall === replacement)
        #expect(controller.connection == .connected)
        #expect(controller.errorMessage == nil)
        #expect(matrixRoom.closeCount == 1)
    }
    
    @Test
    func aFailureKeepsRestartBehindItsOriginalMembershipCleanup() async throws {
        let transport = HeldTransport()
        let system = HeldSystem()
        let controller = makeController(transport: transport, system: system)
        let room = ElementCallFakeRoom()
        let oldCore = FakeRtcCall(holdsLeave: true)
        let oldCall = MatrixRTCCall(rtcCall: oldCore)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: room, connection: .connected, rtcCall: oldCall)
        let generation = controller.callGeneration
        defer {
            oldCore.answerLeave()
            system.start.answer(())
        }
        
        controller.fail("Media failed", generation: generation)
        // No actor turn between failure and restart: teardown has not begun yet.
        controller.startCall(.init(isAudioCall: true, isStartingCall: false), room: room)
        #expect(controller.callGeneration == generation)
        #expect(controller.rtcCall === oldCall)
        #expect(controller.connection == .failed("Media failed"))
        try await waitUntil { oldCore.hasPendingLeave }
        #expect(oldCore.leaveCount == 1)
        
        oldCore.answerLeave()
        try await waitUntil { controller.rtcCall == nil && system.requests.contains(.end(roomID: room.roomID)) }
        #expect(controller.lastDeparture?.result == .confirmed)
        controller.startCall(.init(isAudioCall: true, isStartingCall: false), room: room)
        #expect(controller.callGeneration != generation)
        #expect(controller.connection == .joining)
        
        // Hold B before it opens a room: this test needs no SFU or media connection.
        try await waitUntil { system.start.isPending }
        controller.hangUp()
        try await waitUntil { controller.connection == .ended }
        system.start.answer(())
        #expect(oldCore.leaveCount == 1)
        #expect(transport.openCount == 0)
    }
    
    @Test
    func dismissingAFailureCannotClearTheRoomBeforeItsQueuedTeardown() async throws {
        let system = ElementCallFakeSystem()
        let controller = makeController(transport: HeldTransport(), system: system)
        let room = ElementCallFakeRoom()
        let core = FakeRtcCall(holdsLeave: true)
        let call = MatrixRTCCall(rtcCall: core)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: room, connection: .connected, rtcCall: call)
        defer { core.answerLeave() }
        
        controller.fail("Media failed", generation: controller.callGeneration)
        controller.reset()
        #expect(controller.room === room)
        #expect(controller.rtcCall === call)
        #expect(controller.connection == .failed("Media failed"))
        try await waitUntil { core.hasPendingLeave }
        core.answerLeave()
        try await waitUntil { controller.rtcCall == nil && system.requests.contains(.end(roomID: room.roomID)) }
        #expect(core.leaveCount == 1)
        controller.reset()
        #expect(controller.connection == .idle)
        #expect(controller.room == nil)
    }
    
    @Test
    func theHostCanResetSynchronouslyFromTheEndedAction() async throws {
        let controller = makeController(transport: HeldTransport())
        let core = FakeRtcCall()
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: ElementCallFakeRoom(), connection: .connected,
                                   rtcCall: MatrixRTCCall(rtcCall: core))
        var didReset = false
        let subscription = controller.actions.sink { action in
            if case .ended = action {
                controller.reset()
                didReset = true
            }
        }
        defer { subscription.cancel() }
        controller.hangUp()
        try await waitUntil { didReset }
        #expect(core.leaveCount == 1)
        #expect(controller.connection == .idle)
        #expect(controller.room == nil)
        #expect(controller.rtcCall == nil)
    }
    
    @Test(arguments: [true, false], [true, false])
    func selectedIntentReachesTheMembershipWithoutChangingRinging(isAudioCall: Bool, isStartingCall: Bool) async throws {
        for isDirect in [true, false] {
            let room = ElementCallFakeRoom(isDirect: isDirect)
            let matrixRoom = HeldMatrixRoom(roomID: room.roomID)
            let controller = makeController(transport: HeldTransport(room: matrixRoom))
            let data = ElementCallData(isAudioCall: isAudioCall, isStartingCall: isStartingCall)
            controller.setPreviewState(callData: data, room: room, connection: .joining)
            _ = try #require(await controller.joinCall(for: data, room: room, generation: controller.callGeneration))
            let memberships = matrixRoom.memberPublications
            let notifications = matrixRoom.notifications
            controller.hangUp()
            try await waitUntil { controller.connection == .ended }
            
            let expectedIntent = isAudioCall ? "audio" : "video"
            let membership = try decode(#require(memberships.first))
            #expect(membership["m.call.intent"] as? String == expectedIntent)
            #expect(notifications.count == (isStartingCall ? 1 : 0))
            if isStartingCall {
                let notification = try decode(#require(notifications.first))
                #expect(notification["notification_type"] as? String == (isDirect ? "ring" : "notification"))
                #expect(notification["m.call.intent"] as? String == expectedIntent)
            }
        }
    }
    
    @Test
    func callersOmittingTheNewIntentStillUseTheirNotificationIntent() async throws {
        let matrixRoom = HeldMatrixRoom(roomID: "!legacy:example.org")
        let client = MatrixRTCClient(transport: HeldTransport(room: matrixRoom))
        let room = try await client.room(roomID: matrixRoom.roomID, format: .roomState)
        // The existing source call remains valid and the core supplies its notification fallback.
        let call = try await room.joinCall(notify: .init(kind: .ring, intent: .audio))
        let memberships = matrixRoom.memberPublications
        let departure = await call.leave()
        await room.shutdown()
        
        #expect(departure == .confirmed)
        let membership = try decode(#require(memberships.first))
        #expect(membership["m.call.intent"] as? String == "audio")
    }
    
    private func decode(_ contentJSON: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentJSON.utf8)) as? [String: Any])
    }
    
    private func makeController(transport: any ElementCallMatrixTransportProtocol,
                                system: any ElementCallSystemProvidingProtocol = ElementCallFakeSystem()) -> ElementCallController {
        ElementCallController(rtcClient: MatrixRTCClient(transport: transport), system: system,
                              options: .init(), style: .stock, logger: nil)
    }
    
    private func replaceCall(_ controller: ElementCallController, in room: ElementCallFakeRoom) -> MatrixRTCCall {
        let replacement = MatrixRTCCall(rtcCall: FakeRtcCall())
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: room, connection: .connected, rtcCall: replacement)
        return replacement
    }
    
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if predicate() {
                return
            }
            try await clock.sleep(for: .milliseconds(1))
        }
        throw FakeRtcCall.RefusedError()
    }
}

/// Ignores task cancellation until answered, as an outstanding host/FFI operation can.
private final nonisolated class HeldReply<Value: Sendable>: Sendable {
    private struct State {
        var pending: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
    }
    
    private let state = Mutex(State())
    
    var isPending: Bool {
        state.withLock { $0.pending != nil }
    }
    
    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = state.withLock { state -> Result<Value, Error>? in
                if let result = state.result {
                    return result
                }
                state.pending = continuation
                return nil
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }
    
    func answer(_ value: Value) {
        complete(.success(value))
    }
    
    func fail() {
        complete(.failure(MatrixRTCTransportError.failed("Forbidden", errcode: "M_FORBIDDEN", httpStatus: 403)))
    }
    
    private func complete(_ result: Result<Value, Error>) {
        let pending = state.withLock { state -> CheckedContinuation<Value, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.pending = nil }
            return state.pending
        }
        pending?.resume(with: result)
    }
}

private final nonisolated class HeldTransport: ElementCallMatrixTransportProtocol {
    let userID = "@alice:example.org"
    let deviceID = "FAKEDEVICE"
    let open = HeldReply<any ElementCallMatrixRoomProtocol>()
    private let delegate = ElementCallFakeTransport()
    private let holdsOpen: Bool
    private let room: (any ElementCallMatrixRoomProtocol)?
    private let opens = Mutex(0)
    
    init(holdsOpen: Bool = false, room: (any ElementCallMatrixRoomProtocol)? = nil) {
        self.holdsOpen = holdsOpen
        self.room = room
    }
    
    var openCount: Int {
        opens.withLock { $0 }
    }
    
    func openRoom(roomID: String) async throws -> any ElementCallMatrixRoomProtocol {
        opens.withLock { $0 += 1 }
        if holdsOpen {
            return try await open.wait()
        }
        if let room {
            return room
        }
        return try await delegate.openRoom(roomID: roomID)
    }
    
    func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async throws -> [String: [String]] {
        try await delegate.sendToDeviceMessage(eventType: eventType, messages: messages)
    }
    
    func toDeviceMessages(eventTypes: [String]) -> AsyncStream<MatrixRTCToDeviceMessage> {
        delegate.toDeviceMessages(eventTypes: eventTypes)
    }
    
    func requestOpenIDToken() async throws -> MatrixRTCOpenIDToken {
        try await delegate.requestOpenIDToken()
    }
}

private final nonisolated class HeldMatrixRoom: ElementCallMatrixRoomProtocol {
    let roomID: String
    let publication = HeldReply<String>()
    private let delegate: ElementCallFakeMatrixRoom
    private let holdsJoin: Bool
    private let state = Mutex(State())
    
    private struct State {
        var closes = 0
        var subscriptions = 0
        var heldPublication = false
        var memberPublications: [String] = []
        var notifications: [String] = []
    }
    
    init(roomID: String, holdsJoin: Bool = false) {
        self.roomID = roomID
        self.holdsJoin = holdsJoin
        delegate = ElementCallFakeMatrixRoom(roomID: roomID, ownUserID: "@alice:example.org")
    }
    
    var memberPublications: [String] {
        state.withLock { $0.memberPublications }
    }
    
    var notifications: [String] {
        state.withLock { $0.notifications }
    }
    
    var closeCount: Int {
        state.withLock { $0.closes }
    }
    
    var subscriptionCount: Int {
        state.withLock { $0.subscriptions }
    }
    
    func isEncrypted() -> AsyncStream<Bool> {
        state.withLock { $0.subscriptions += 1 }
        return delegate.isEncrypted()
    }
    
    func joinedMemberIDs() -> AsyncStream<[String]> {
        delegate.joinedMemberIDs()
    }
    
    func stickyEvents() -> AsyncStream<[ElementCallRoomEvent]> {
        delegate.stickyEvents()
    }
    
    func stateEvents(eventType: String) -> AsyncStream<[ElementCallRoomEvent]> {
        delegate.stateEvents(eventType: eventType)
    }
    
    func timelineEvents(eventTypes: [String]) -> AsyncStream<[ElementCallRoomEvent]> {
        delegate.timelineEvents(eventTypes: eventTypes)
    }
    
    func redactions() -> AsyncStream<String> {
        delegate.redactions()
    }
    
    func relations(eventID: String, relType: String, eventType: String) async throws -> [ElementCallRoomEvent] {
        try await delegate.relations(eventID: eventID, relType: relType, eventType: eventType)
    }
    
    func rtcTransports() async throws -> String {
        try await delegate.rtcTransports()
    }
    
    func sendStateEvent(eventType: String, stateKey: String, contentJSON: String) async throws -> String {
        if eventType == "org.matrix.msc3401.call.member", contentJSON != "{}" {
            state.withLock { $0.memberPublications.append(contentJSON) }
        }
        if holdsJoin, eventType == "org.matrix.msc3401.call.member", contentJSON != "{}" {
            let hold = state.withLock {
                guard !$0.heldPublication else { return false }
                $0.heldPublication = true
                return true
            }
            if hold {
                return try await publication.wait()
            }
        }
        return try await delegate.sendStateEvent(eventType: eventType, stateKey: stateKey, contentJSON: contentJSON)
    }
    
    func sendStickyEvent(eventType: String, contentJSON: String, durationMs: UInt64) async throws -> String {
        recordNotification(eventType: eventType, contentJSON: contentJSON)
        return try await delegate.sendStickyEvent(eventType: eventType, contentJSON: contentJSON, durationMs: durationMs)
    }
    
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async throws -> String {
        try await delegate.sendDelayedEvent(eventType: eventType, stateKey: stateKey, contentJSON: contentJSON, delayMs: delayMs)
    }
    
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async throws {
        try await delegate.updateDelayedEvent(delayID: delayID, action: action)
    }
    
    func sendRoomEvent(eventType: String, contentJSON: String) async throws -> String {
        recordNotification(eventType: eventType, contentJSON: contentJSON)
        return try await delegate.sendRoomEvent(eventType: eventType, contentJSON: contentJSON)
    }
    
    private func recordNotification(eventType: String, contentJSON: String) {
        if eventType.hasSuffix(".rtc.notification") {
            state.withLock { $0.notifications.append(contentJSON) }
        }
    }
    
    func redactEvent(eventID: String, reason: String?) async throws {
        try await delegate.redactEvent(eventID: eventID, reason: reason)
    }
    
    func close() async {
        state.withLock { $0.closes += 1 }
    }
}

private final class HeldSystem: ElementCallSystemProvidingProtocol {
    let start = HeldReply<Void>()
    private let delegate = ElementCallFakeSystem()
    var events: AnyPublisher<ElementCallSystemEvent, Never> {
        delegate.events
    }
    
    var requests: [ElementCallFakeSystem.Request] {
        delegate.requests
    }
    
    func startCall(roomID: String, displayName: String, isVideo: Bool) async {
        await delegate.startCall(roomID: roomID, displayName: displayName, isVideo: isVideo)
        _ = try? await start.wait()
    }
    
    func reportConnected(roomID: String) {
        delegate.reportConnected(roomID: roomID)
    }
    
    func endCall(roomID: String) {
        delegate.endCall(roomID: roomID)
    }
    
    func setMicrophoneEnabled(_ enabled: Bool, roomID: String) {
        delegate.setMicrophoneEnabled(enabled, roomID: roomID)
    }
}
