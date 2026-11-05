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
        let controller = makeController(backend: HeldBackend())
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
        let controller = makeController(backend: HeldBackend())
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
        let transport = HeldBackend()
        let system = HeldSystem()
        let controller = makeController(backend: transport, system: system)
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
    
    @Test
    func aLateRoomSeedCannotReplaceTheCurrentCall() async throws {
        let backend = HeldBackend(holdsSeed: true)
        let controller = makeController(backend: backend)
        let room = ElementCallFakeRoom()
        let data = ElementCallData(isAudioCall: true, isStartingCall: false)
        controller.setPreviewState(callData: data, room: room, connection: .joining)
        let generation = controller.callGeneration
        let joining = Task { await controller.joinCall(for: data, room: room, generation: generation) }
        defer { backend.seedRoom() }
        try await waitUntil { backend.isSeeding }
        let replacement = replaceCall(controller, in: room)
        backend.seedRoom()
        #expect(await joining.value == nil)
        #expect(controller.rtcCall === replacement)
        #expect(controller.connection == .connected)
        #expect(controller.errorMessage == nil)
        try await waitUntil { backend.closeCount == 1 }
        #expect(backend.memberPublications.isEmpty)
    }
    
    @Test
    func cancellingRoomSeedingClosesTheLateSubscription() async throws {
        let backend = HeldBackend(holdsSeed: true)
        let client = MatrixRTCClient(backend: backend)
        let opening = Task { try await client.room(roomID: "!late:example.org", format: .roomState) }
        defer { backend.seedRoom() }
        try await waitUntil { backend.isSeeding }
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        backend.seedRoom()
        try await waitUntil { backend.closeCount == 1 }
        #expect(backend.memberPublications.isEmpty)
    }
    
    @Test(arguments: [true, false])
    func aLateMembershipJoinOrErrorCannotReplaceOrFailTheCurrentCall(fails: Bool) async throws {
        let room = ElementCallFakeRoom()
        let matrixRoom = HeldBackend(holdsJoin: true)
        let transport = matrixRoom
        let controller = makeController(backend: transport)
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
        let transport = HeldBackend()
        let system = HeldSystem()
        let controller = makeController(backend: transport, system: system)
        let room = ElementCallFakeRoom()
        let oldCore = FakeRTCCall(holdsLeave: true)
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
        #expect(controller.connection == .failed(.other("Media failed")))
        try await waitUntil { oldCore.hasPendingLeave }
        #expect(oldCore.leaveCount == 1)
        
        oldCore.answerLeave()
        try await waitUntil { controller.rtcCall == nil && system.requests.contains(.end(roomID: room.roomID, reason: .failed)) }
        #expect(controller.lastDeparture?.result == .confirmed)
        controller.startCall(.init(isAudioCall: true, isStartingCall: false), room: room)
        #expect(controller.callGeneration != generation)
        #expect(controller.connection == .joining)
        
        // Hold B before it opens a room: this test needs no SFU or media connection.
        try await waitUntil { system.start.isPending }
        controller.hangUp()
        try await waitUntil { controller.connection == .ended(.left) }
        system.start.answer(())
        #expect(oldCore.leaveCount == 1)
        #expect(transport.openCount == 0)
    }
    
    @Test
    func dismissingAFailureCannotClearTheRoomBeforeItsQueuedTeardown() async throws {
        let system = ElementCallFakeSystem()
        let controller = makeController(backend: HeldBackend(), system: system)
        let room = ElementCallFakeRoom()
        let core = FakeRTCCall(holdsLeave: true)
        let call = MatrixRTCCall(rtcCall: core)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: room, connection: .connected, rtcCall: call)
        defer { core.answerLeave() }
        
        controller.fail("Media failed", generation: controller.callGeneration)
        controller.reset()
        #expect(controller.room === room)
        #expect(controller.rtcCall === call)
        #expect(controller.connection == .failed(.other("Media failed")))
        try await waitUntil { core.hasPendingLeave }
        core.answerLeave()
        try await waitUntil { controller.rtcCall == nil && system.requests.contains(.end(roomID: room.roomID, reason: .failed)) }
        #expect(core.leaveCount == 1)
        controller.reset()
        #expect(controller.connection == .idle)
        #expect(controller.room == nil)
    }
    
    @Test
    func theHostCanResetSynchronouslyFromTheEndedAction() async throws {
        let controller = makeController(backend: HeldBackend())
        let core = FakeRTCCall()
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
        let pair = ["@alice:example.org", "@bob:example.org"]
        let cases = [(true, pair, "ring"), (false, pair, "notification"), (true, [pair[0]], "notification")]
        for (isDirect, joinedUserIDs, expectedNotificationType) in cases {
            let room = ElementCallFakeRoom(isDirect: isDirect)
            let matrixRoom = HeldBackend(joinedUserIDs: joinedUserIDs)
            let controller = makeController(backend: matrixRoom)
            let data = ElementCallData(isAudioCall: isAudioCall, isStartingCall: isStartingCall)
            controller.setPreviewState(callData: data, room: room, connection: .joining)
            _ = try #require(await controller.joinCall(for: data, room: room, generation: controller.callGeneration))
            if isStartingCall {
                try await waitUntil { !matrixRoom.notifications.isEmpty }
            }
            controller.hangUp()
            try await waitUntil { controller.connection == .ended(.left) }
            let memberships = matrixRoom.memberPublications
            let notifications = matrixRoom.notifications
            
            let expectedIntent = isAudioCall ? "audio" : "video"
            let membership = try decode(#require(memberships.first))
            #expect(membership["m.call.intent"] as? String == expectedIntent)
            #expect(notifications.count == (isStartingCall ? 1 : 0))
            if isStartingCall {
                let notification = try decode(#require(notifications.first))
                #expect(notification["notification_type"] as? String == expectedNotificationType)
                #expect(notification["m.call.intent"] as? String == expectedIntent)
            }
        }
    }
    
    @Test
    func callersOmittingTheNewIntentStillUseTheirNotificationIntent() async throws {
        let matrixRoom = HeldBackend()
        let client = MatrixRTCClient(backend: matrixRoom)
        let room = try await client.room(roomID: "!legacy:example.org", format: .roomState)
        // The existing source call remains valid and the core supplies its notification fallback.
        let call = try await room.joinCall(kind: .direct(ring: .audio))
        let memberships = matrixRoom.memberPublications
        let departure = await call.leave()
        await room.shutdown()
        
        #expect(departure == .confirmed)
        let membership = try decode(#require(memberships.first))
        #expect(membership["m.call.intent"] as? String == "audio")
    }
    
    @Test(arguments: [true, false])
    func roomOpenAndJoinFailuresShowHostCopyAndKeepServiceDiagnostics(failsToOpenRoom: Bool) async throws {
        let room = ElementCallFakeRoom()
        let matrixRoom = HeldBackend(holdsJoin: !failsToOpenRoom, refusesRoom: failsToOpenRoom)
        let transport = matrixRoom
        let system = ElementCallFakeSystem()
        let logger = ElementCallFakeLogger()
        let strings = ElementCallStrings(callPreparationFailed: "Host preparation failure. Try again.",
                                         callJoinFailed: "Host join failure. Try again.")
        let controller = makeController(backend: transport, system: system, strings: strings, logger: logger)
        controller.startCall(.init(isAudioCall: true, isStartingCall: false), room: room)
        defer { matrixRoom.publication.fail() }
        if !failsToOpenRoom {
            try await waitUntil { matrixRoom.publication.isPending }
            matrixRoom.publication.fail()
        }
        try await waitUntil { system.requests.contains(.end(roomID: room.roomID, reason: .failed)) }
        
        let expected: ElementCallFailure = failsToOpenRoom ? .other(strings.callPreparationFailed) : .joinRefused
        #expect(controller.connection == .failed(expected))
        let stage = failsToOpenRoom ? "Could not open the room:" : "Join refused:"
        #expect(logger.messages.contains { $0.contains(stage) && $0.contains("Forbidden") })
        #expect(!logger.messages.contains(strings.callPreparationFailed))
        #expect(!logger.messages.contains(strings.callJoinFailed))
    }
    
    @Test
    func aMicrophoneFailureShowsHostCopyAndKeepsMediaDiagnostics() async throws {
        let system = ElementCallFakeSystem()
        let logger = ElementCallFakeLogger()
        let strings = ElementCallStrings(microphoneStartFailed: "Host microphone failure. Try again.")
        let controller = makeController(backend: HeldBackend(), system: system, strings: strings, logger: logger)
        let transport = FakeMediaSession(holdingPublish: .microphone)
        let media = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
        let room = ElementCallFakeRoom()
        let call = MatrixRTCCall(rtcCall: FakeRTCCall())
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false), room: room,
                                   connection: .connectingMedia, call: media, rtcCall: call)
        let prepareAudio: () -> Void = { }
        let startup = Task { await controller.publishMedia(on: media, rtcCall: call, room: room, prepareAudio: prepareAudio) }
        defer { transport.answerPublish() }
        try await waitUntil { transport.hasPendingPublish }
        transport.answerPublish(failingWith: MatrixRTCError.media("MIC_CAPTURE_FIXTURE"))
        await startup.value
        try await waitUntil { system.requests.contains(.end(roomID: room.roomID, reason: .failed)) }
        
        #expect(controller.connection == .failed(.other(strings.microphoneStartFailed)))
        #expect(logger.messages.contains { $0.contains("Microphone failed:") && $0.contains("MIC_CAPTURE_FIXTURE") })
        #expect(!logger.messages.contains(strings.microphoneStartFailed))
        await media.disconnect()
    }
    
    private func decode(_ contentJSON: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentJSON.utf8)) as? [String: Any])
    }
    
    private func makeController(backend: any ElementCallMatrixBackendProtocol,
                                system: any ElementCallSystemProvidingProtocol = ElementCallFakeSystem(),
                                strings: ElementCallStrings = .init(),
                                logger: (any ElementCallLoggingProtocol)? = nil) -> ElementCallController {
        let stock = ElementCallStyle.stock
        let style = ElementCallStyle(theme: stock.theme, icons: stock.icons, avatars: stock.avatars, strings: strings)
        return ElementCallController(backend: backend, system: system,
                                     options: .init(), style: style, logger: logger)
    }
    
    private func replaceCall(_ controller: ElementCallController, in room: ElementCallFakeRoom) -> MatrixRTCCall {
        let replacement = MatrixRTCCall(rtcCall: FakeRTCCall())
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
        throw FakeRTCCall.RefusedError()
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
        complete(.failure(ElementCallMatrixBackendError(errorCode: "M_FORBIDDEN", statusCode: 403, reason: "Forbidden")))
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

private final nonisolated class HeldBackend: ElementCallMatrixBackendProtocol {
    let userID = "@alice:example.org"
    let deviceID = "FAKEDEVICE"
    let publication = HeldReply<String>()
    private let holdsSeed: Bool
    private let holdsJoin: Bool
    private let refusesRoom: Bool
    private let joinedUserIDs: [String]
    private let state = Mutex(State())
    
    private struct Seed {
        let subjects: ElementCallRoomSubjects
        let sink: ElementCallRoomSink
    }
    
    private struct State {
        var seed: Seed?
        var opens = 0
        var closes = 0
        var heldPublication = false
        var memberPublications: [String] = []
        var notifications: [String] = []
    }
    
    init(holdsSeed: Bool = false, holdsJoin: Bool = false, refusesRoom: Bool = false,
         joinedUserIDs: [String] = ["@alice:example.org"]) {
        self.holdsSeed = holdsSeed
        self.holdsJoin = holdsJoin
        self.refusesRoom = refusesRoom
        self.joinedUserIDs = joinedUserIDs
    }
    
    var isSeeding: Bool {
        state.withLock { $0.seed != nil }
    }
    
    var openCount: Int {
        state.withLock { $0.opens }
    }
    
    var closeCount: Int {
        state.withLock { $0.closes }
    }
    
    var memberPublications: [String] {
        state.withLock { $0.memberPublications }
    }
    
    var notifications: [String] {
        state.withLock { $0.notifications }
    }
    
    func subscribeToRoom(roomID: String, subjects: ElementCallRoomSubjects, sink: ElementCallRoomSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription {
        if refusesRoom {
            throw ElementCallMatrixBackendError(errorCode: "M_FORBIDDEN", statusCode: 403, reason: "Forbidden")
        }
        state.withLock {
            $0.opens += 1
            $0.seed = Seed(subjects: subjects, sink: sink)
        }
        if !holdsSeed {
            seedRoom()
        }
        return ElementCallBackendSubscription { [self] in state.withLock { $0.closes += 1 } }
    }
    
    func seedRoom() {
        let seed = state.withLock {
            defer { $0.seed = nil }
            return $0.seed
        }
        guard let seed else { return }
        seed.sink.deliverEncryption(isEncrypted: false)
        seed.sink.deliverJoinedMembers(joinedUserIDs)
        seed.sink.deliverStickyEvents([])
        for eventType in seed.subjects.stateEventTypes {
            seed.sink.deliverStateEvents([], ofType: eventType)
        }
    }
    
    func sendStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String) async throws(ElementCallMatrixBackendError) -> String {
        if eventType == MatrixRTCEventTypes.legacyStateMember, contentJSON != "{}" {
            let hold = state.withLock {
                $0.memberPublications.append(contentJSON)
                guard holdsJoin, !$0.heldPublication else { return false }
                $0.heldPublication = true
                return true
            }
            if hold {
                do {
                    return try await publication.wait()
                } catch {
                    throw ElementCallMatrixBackendError(errorCode: "M_FORBIDDEN", statusCode: 403, reason: "Forbidden")
                }
            }
        }
        return "$event"
    }
    
    func sendStickyEvent(roomID: String, eventType: String, contentJSON: String, duration: Duration) async throws(ElementCallMatrixBackendError) -> String {
        recordNotification(eventType, contentJSON)
        return "$event"
    }
    
    func sendRoomEvent(roomID: String, eventType: String, contentJSON: String) async throws(ElementCallMatrixBackendError) -> String {
        recordNotification(eventType, contentJSON)
        return "$event"
    }
    
    private func recordNotification(_ eventType: String, _ contentJSON: String) {
        if eventType.hasSuffix(".rtc.notification") {
            state.withLock { $0.notifications.append(contentJSON) }
        }
    }
    
    func sendDelayedStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String, delay: Duration) async throws(ElementCallMatrixBackendError) -> String {
        "delay"
    }
    
    func sendDelayedStickyEvent(roomID: String, eventType: String, contentJSON: String, stickyDuration: Duration, delay: Duration) async throws(ElementCallMatrixBackendError) -> String {
        "delay"
    }
    
    func restartDelayedEvent(roomID: String, delayID: String) async throws(ElementCallMatrixBackendError) { }
    func cancelDelayedEvent(roomID: String, delayID: String) async throws(ElementCallMatrixBackendError) { }
    func redactEvent(roomID: String, eventID: String, reason: String?) async throws(ElementCallMatrixBackendError) { }
    func sendToDeviceMessage(eventType: String, contentJSON: String, to recipients: [ElementCallDevice]) async throws(ElementCallMatrixBackendError) -> [ElementCallDevice: String] {
        [:]
    }
    
    func subscribeToDeviceMessages(eventTypes: [String], sink: ElementCallToDeviceSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription {
        .init()
    }
    
    func relations(roomID: String, eventID: String, relationshipType: String, eventType: String) async throws(ElementCallMatrixBackendError) -> [ElementCallMatrixEvent] {
        []
    }
    
    func openIDToken() async throws(ElementCallMatrixBackendError) -> ElementCallOpenIDToken {
        .init(accessToken: "", tokenType: "Bearer", matrixServerName: "example.org", expiresIn: .seconds(3600))
    }
    
    func liveKitToken(for request: ElementCallLiveKitTokenRequest) async throws(ElementCallMatrixBackendError) -> String {
        "jwt"
    }
    
    func rtcTransportsJSON() async throws(ElementCallMatrixBackendError) -> String {
        #"[{"type":"livekit","livekit_service_url":"https://sfu.example.org"}]"#
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
    
    func reportDisconnected(roomID: String) {
        delegate.reportDisconnected(roomID: roomID)
    }
    
    func endCall(roomID: String, reason: ElementCallEndReason) {
        delegate.endCall(roomID: roomID, reason: reason)
    }
    
    func setMicrophoneEnabled(_ enabled: Bool, roomID: String) {
        delegate.setMicrophoneEnabled(enabled, roomID: roomID)
    }
}
