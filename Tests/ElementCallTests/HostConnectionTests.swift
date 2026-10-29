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

@MainActor
struct HostConnectionTests {
    @Test
    func anUnknownParticipantDoesNotRecoverDegradedMedia() async {
        let transport = FakeMediaSession()
        let media = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport)
        await media.start()
        var events = media.events.makeAsyncIterator()
        transport.send(.mediaConnectionState(degraded: true))
        #expect(await events.next() == .mediaConnectionDegraded(true))
        #expect(media.isMediaDegraded)
        
        // A real event behind the diagnostic is a barrier proving the pump has processed it.
        transport.send(.unknownParticipant(identity: "unmatched"))
        transport.send(.handLowered(memberId: "peer"))
        let afterDiagnostic = await events.next()
        #expect(afterDiagnostic == .handLowered(memberID: "peer"))
        if afterDiagnostic != .handLowered(memberID: "peer") {
            #expect(await events.next() == .handLowered(memberID: "peer"))
        }
        #expect(media.isMediaDegraded)
        
        transport.send(.mediaConnectionState(degraded: false))
        #expect(await events.next() == .mediaConnectionDegraded(false))
        #expect(!media.isMediaDegraded)
        await media.disconnect()
    }
    
    @Test
    func aggregateDegradationKeepsLocalParticipationAndTheOriginalConnectionTime() async throws {
        let connectedAt = Date(timeIntervalSince1970: 1234)
        let fixture = Fixture(connection: .connected, connectedAt: connectedAt)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        
        // A different participant's SFU can produce these aggregate events too.
        fixture.transport.send(.mediaConnectionState(degraded: true))
        try await waitUntil { fixture.media.isMediaDegraded }
        await drain()
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.controller.isInCall)
        #expect(fixture.controller.call === fixture.media)
        #expect(fixture.controller.connectedAt == connectedAt)
        #expect(fixture.system.requests.isEmpty)
        
        fixture.transport.send(.mediaConnectionState(degraded: false))
        try await waitUntil { !fixture.media.isMediaDegraded }
        await drain()
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.controller.connectedAt == connectedAt)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
    }
    
    @Test
    func anOldMediaPumpCannotEndItsReplacementInTheSameRoom() async throws {
        let fixture = Fixture(connection: .connected)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        let replacement = replaceMedia(in: fixture, connection: .connected)
        
        fixture.transport.send(.ended(reason: .left))
        try await waitUntil { fixture.media.hasEnded }
        await drain()
        #expect(fixture.controller.call === replacement)
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
        await replacement.disconnect()
    }
    
    @Test
    func aScheduledMediaEndCannotEndItsReplacementInTheSameRoom() async {
        let fixture = Fixture(connection: .connected)
        fixture.controller.handle(.ended(.left), from: fixture.media)
        // Replace before the separately scheduled teardown task gets an actor turn.
        let replacement = replaceMedia(in: fixture, connection: .connected)
        await drain()
        #expect(fixture.controller.call === replacement)
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
        await replacement.disconnect()
    }
    
    @Test(arguments: [ElementCallConnection.connectingMedia, .ended])
    func startupCompletionCannotReviveAnEndedMediaSession(connection: ElementCallConnection) async {
        let fixture = Fixture(connection: connection)
        await fixture.media.start()
        var events = fixture.media.events.makeAsyncIterator()
        fixture.transport.send(.ended(reason: .left))
        #expect(await events.next() == .ended(.left))
        #expect(fixture.media.hasEnded)
        
        fixture.controller.completeMediaStartup(on: fixture.media, roomID: fixture.room.roomID)
        #expect(fixture.controller.connection == connection)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
    }
    
    @Test
    func cancelledStartupCompletionCannotConnect() async {
        let fixture = Fixture(connection: .connectingMedia)
        let completion = Task {
            fixture.controller.completeMediaStartup(on: fixture.media, roomID: fixture.room.roomID)
        }
        completion.cancel()
        await completion.value
        #expect(fixture.controller.connection == .connectingMedia)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
    }
    
    @Test
    func oldStartupCompletionCannotConnectItsReplacementInTheSameRoom() async {
        let fixture = Fixture(connection: .connectingMedia)
        let replacement = replaceMedia(in: fixture, connection: .connectingMedia)
        fixture.controller.completeMediaStartup(on: fixture.media, roomID: fixture.room.roomID)
        #expect(fixture.controller.call === replacement)
        #expect(fixture.controller.connection == .connectingMedia)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
        await replacement.disconnect()
    }
    
    @Test
    func duplicateReadinessKeepsOneConnectionReportAndTheOriginalTime() async throws {
        let fixture = Fixture(connection: .connectingMedia)
        fixture.controller.completeMediaStartup(on: fixture.media, roomID: fixture.room.roomID)
        let connectedAt = try #require(fixture.controller.connectedAt)
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.system.requests == [.connected(roomID: fixture.room.roomID)])
        
        await drain()
        fixture.controller.completeMediaStartup(on: fixture.media, roomID: fixture.room.roomID)
        #expect(fixture.controller.connectedAt == connectedAt)
        #expect(fixture.system.requests == [.connected(roomID: fixture.room.roomID)])
        await fixture.media.disconnect()
    }
    
    @Test
    func endingWhileMicrophonePublicationIsPendingCannotReportConnected() async throws {
        let fixture = Fixture(connection: .connectingMedia, holdingPublish: .microphone)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        let startup = Task {
            await fixture.controller.publishMedia(on: fixture.media, rtcCall: fixture.rtcCall,
                                                  room: fixture.room, prepareAudio: { }, cameraAccess: { true })
        }
        defer { fixture.transport.answerPublish() }
        try await waitUntil { fixture.transport.hasPendingPublish }
        fixture.transport.send(.ended(reason: .left))
        try await waitUntil { fixture.controller.connection == .ended }
        fixture.transport.answerPublish()
        await startup.value
        #expect(fixture.controller.connection == .ended)
        #expect(fixture.controller.connectedAt == nil)
        #expect(!fixture.system.requests.contains(.connected(roomID: fixture.room.roomID)))
        #expect(fixture.transport.published.allSatisfy { $0.kind == .microphone })
        await fixture.media.disconnect()
    }
    
    @Test
    func microphoneReadinessPrecedesCameraAndLateCameraFailureDoesNotAlertTheReplacement() async throws {
        let fixture = Fixture(connection: .connectingMedia, isAudioCall: false, holdingPublish: .camera)
        let startup = Task {
            await fixture.controller.publishMedia(on: fixture.media, rtcCall: fixture.rtcCall,
                                                  room: fixture.room, prepareAudio: { }, cameraAccess: { true })
        }
        defer { fixture.transport.answerPublish() }
        try await waitUntil { fixture.transport.hasPendingPublish }
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.controller.connectedAt != nil)
        #expect(fixture.system.requests == [.connected(roomID: fixture.room.roomID)])
        
        let replacement = replaceMedia(in: fixture, connection: .connectingMedia)
        fixture.transport.answerPublish(failingWith: FakeRtcCall.RefusedError())
        await startup.value
        #expect(fixture.controller.call === replacement)
        #expect(fixture.controller.connection == .connectingMedia)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.controller.errorMessage == nil)
        #expect(fixture.system.requests == [.connected(roomID: fixture.room.roomID)])
        #expect(!fixture.media.isCameraEnabled)
        await fixture.media.disconnect()
        await replacement.disconnect()
    }
    
    @Test
    func cameraPermissionDoesNotDelayConnectionOrOverrideTurningTheCameraOff() async throws {
        let fixture = Fixture(connection: .connectingMedia, isAudioCall: false)
        let permission = CameraPermission()
        let startup = Task {
            await fixture.controller.publishMedia(on: fixture.media, rtcCall: fixture.rtcCall,
                                                  room: fixture.room, prepareAudio: { },
                                                  cameraAccess: { await permission.request() })
        }
        defer { permission.answer() }
        try await waitUntil { permission.wasRequested }
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.system.requests == [.connected(roomID: fixture.room.roomID)])
        fixture.controller.setCameraEnabled(false)
        await drain()
        permission.answer()
        await startup.value
        #expect(!fixture.media.isCameraEnabled)
        #expect(fixture.transport.published.allSatisfy { $0.kind == .microphone })
        #expect(fixture.system.requests == [.connected(roomID: fixture.room.roomID)])
        await fixture.media.disconnect()
    }
    
    @Test
    func turningTheCameraOffDuringPublicationWinsBeforeItCanUnmute() async throws {
        let fixture = Fixture(connection: .connected, holdingPublish: .camera)
        let generation = fixture.controller.callGeneration
        let enabling = Task {
            await fixture.controller.setCameraEnabled(true, generation: generation, cameraAccess: { true })
        }
        defer { fixture.transport.answerPublish() }
        try await waitUntil { fixture.transport.hasPendingPublish }
        await fixture.controller.setCameraEnabled(false, generation: generation)
        fixture.transport.answerPublish()
        await enabling.value
        
        #expect(!fixture.media.isCameraEnabled)
        #expect(!fixture.controller.isCameraEnabled)
        #expect(!fixture.transport.localMutes.contains { $0.kind == .camera && !$0.muted })
        await fixture.media.disconnect()
    }
    
    @Test
    func mutingDuringMicrophonePublicationWinsOverTheInitialUnmutedIntent() async throws {
        let fixture = Fixture(connection: .connectingMedia, holdingPublish: .microphone)
        let startup = Task {
            await fixture.controller.publishMedia(on: fixture.media, rtcCall: fixture.rtcCall,
                                                  room: fixture.room, prepareAudio: { })
        }
        defer { fixture.transport.answerPublish() }
        try await waitUntil { fixture.transport.hasPendingPublish }
        fixture.controller.setMicrophoneMuted(true)
        try await waitUntil { fixture.media.isMicrophoneMuted }
        fixture.transport.answerPublish()
        await startup.value
        
        #expect(fixture.media.isMicrophoneMuted)
        #expect(fixture.controller.isMicrophoneMuted)
        #expect(fixture.transport.localMutes.last { $0.kind == .microphone }?.muted == true)
        await fixture.media.disconnect()
    }
    
    @Test
    func microphonePublicationCompletingAfterDisconnectCannotRestoreLocalMedia() async throws {
        let fixture = Fixture(connection: .connectingMedia, holdingPublish: .microphone)
        let publishing = Task { try await fixture.media.publishMicrophone(muted: false) }
        defer { fixture.transport.answerPublish() }
        try await waitUntil { fixture.transport.hasPendingPublish }
        await fixture.media.disconnect()
        fixture.transport.answerPublish()
        await #expect(throws: CancellationError.self) { try await publishing.value }
        #expect(fixture.media.hasEnded)
        #expect(fixture.transport.localMutes.isEmpty)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.system.requests.isEmpty)
    }
    
    @Test(arguments: [false, true])
    func queuedMicrophoneChangesCannotMuteAReplacementCall(isSystemMute: Bool) async {
        let fixture = Fixture(connection: .connected)
        if isSystemMute {
            fixture.controller.applySystemMute(true)
        } else {
            fixture.controller.setMicrophoneMuted(true)
        }
        // The old mute task has not had an actor turn; B reuses the exact same room context.
        let replacementTransport = FakeMediaSession()
        let replacement = MatrixRTCMediaSession(localMemberID: "replacement", mediaSession: replacementTransport,
                                                capturesCamera: false)
        fixture.controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: true),
                                           room: fixture.room, connection: .connected, call: replacement)
        await drain()
        #expect(!replacement.isMicrophoneMuted)
        #expect(!fixture.media.isMicrophoneMuted)
        #expect(replacementTransport.localMutes.isEmpty)
        #expect(fixture.transport.localMutes.isEmpty)
        await fixture.media.disconnect()
        await replacement.disconnect()
    }
    
    @Test
    func anEndRequestForAnOlderRoomCannotEndTheCurrentRoom() async throws {
        let fixture = Fixture(connection: .connected)
        fixture.system.send(.endCallRequested(roomID: "!older:example.org"))
        // A following event proves the system publisher was delivered, without racing a timer.
        fixture.system.send(.microphoneMuteChanged(isMuted: true))
        try await waitUntil { fixture.controller.connection == .ended || fixture.media.isMicrophoneMuted }
        await drain()
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.controller.call === fixture.media)
        #expect(fixture.media.isMicrophoneMuted)
        #expect(!fixture.system.requests.contains(.end(roomID: fixture.room.roomID)))
        await fixture.media.disconnect()
    }
    
    @Test
    func ownRecoveryBeforeMicrophoneReadinessCannotConnectTheHost() async throws {
        let fixture = Fixture(connection: .connectingMedia)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        fixture.transport.send(.ownMediaConnectionState(degraded: true))
        try await waitUntil { fixture.media.isOwnMediaDegraded }
        fixture.transport.send(.ownMediaConnectionState(degraded: false))
        try await waitUntil { !fixture.media.isOwnMediaDegraded }
        await drain()
        #expect(fixture.controller.connection == .connectingMedia)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
    }
    
    @Test
    func initialOwnMediaDegradationDelaysTheFirstConnectionUntilRecovery() async throws {
        let fixture = Fixture(connection: .connectingMedia, holdingPublish: .microphone)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        let startup = Task {
            await fixture.controller.publishMedia(on: fixture.media, rtcCall: fixture.rtcCall,
                                                  room: fixture.room, prepareAudio: { })
        }
        defer { fixture.transport.answerPublish() }
        try await waitUntil { fixture.transport.hasPendingPublish }
        fixture.transport.send(.ownMediaConnectionState(degraded: true))
        try await waitUntil { fixture.media.isOwnMediaDegraded }
        fixture.transport.answerPublish()
        await startup.value
        #expect(fixture.controller.connection == .connectingMedia)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.system.requests.isEmpty)
        
        fixture.transport.send(.ownMediaConnectionState(degraded: false))
        try await waitUntil { fixture.controller.connection == .connected }
        #expect(fixture.controller.connectedAt != nil)
        #expect(fixture.system.requests == [.connected(roomID: fixture.room.roomID)])
        await fixture.media.disconnect()
    }
    
    @Test
    func ownMediaReconnectCoalescesReportsAndPreservesTheFirstConnectionTime() async throws {
        let connectedAt = Date(timeIntervalSince1970: 1234)
        let fixture = Fixture(connection: .connected, connectedAt: connectedAt)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        fixture.transport.send(.ownMediaConnectionState(degraded: true))
        fixture.transport.send(.ownMediaConnectionState(degraded: true))
        // A separate aggregate event is a barrier behind both duplicate own-media events.
        fixture.transport.send(.mediaConnectionState(degraded: true))
        try await waitUntil { fixture.media.isMediaDegraded }
        await drain()
        #expect(fixture.controller.connection == .connectingMedia)
        #expect(fixture.controller.isInCall)
        #expect(fixture.controller.call === fixture.media)
        #expect(fixture.controller.connectedAt == connectedAt)
        #expect(fixture.system.requests == [.disconnected(roomID: fixture.room.roomID)])
        
        fixture.transport.send(.ownMediaConnectionState(degraded: false))
        fixture.transport.send(.ownMediaConnectionState(degraded: false))
        fixture.transport.send(.mediaConnectionState(degraded: false))
        try await waitUntil { fixture.controller.connection == .connected && !fixture.media.isMediaDegraded }
        await drain()
        #expect(fixture.controller.connectedAt == connectedAt)
        #expect(fixture.system.requests == [.disconnected(roomID: fixture.room.roomID),
                                            .connected(roomID: fixture.room.roomID)])
        await fixture.media.disconnect()
    }
    
    @Test
    func ownMediaRecoveryRestoresTheHostWhileOnlyRemoteMediaRemainsDegraded() async throws {
        let connectedAt = Date(timeIntervalSince1970: 1234)
        let fixture = Fixture(connection: .connected, connectedAt: connectedAt)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        fixture.transport.send(.ownMediaConnectionState(degraded: true))
        try await waitUntil { fixture.controller.connection == .connectingMedia }
        fixture.transport.send(.mediaConnectionState(degraded: true))
        try await waitUntil { fixture.media.isMediaDegraded }
        fixture.transport.send(.ownMediaConnectionState(degraded: false))
        try await waitUntil { fixture.controller.connection == .connected }
        #expect(!fixture.media.isOwnMediaDegraded)
        #expect(fixture.media.isMediaDegraded)
        #expect(fixture.controller.connectedAt == connectedAt)
        #expect(fixture.system.requests == [.disconnected(roomID: fixture.room.roomID),
                                            .connected(roomID: fixture.room.roomID)])
        await fixture.media.disconnect()
    }
    
    @Test
    func staleOwnMediaEventsCannotReportConnectionForAReplacementInTheSameRoom() async throws {
        let fixture = Fixture(connection: .connected)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        let replacement = MatrixRTCMediaSession(localMemberID: "replacement", mediaSession: FakeMediaSession(),
                                                capturesCamera: false)
        let connectedAt = Date(timeIntervalSince1970: 5678)
        fixture.controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: true),
                                           room: fixture.room, connection: .connected,
                                           connectedAt: connectedAt, call: replacement)
        fixture.transport.send(.ownMediaConnectionState(degraded: true))
        fixture.transport.send(.ownMediaConnectionState(degraded: false))
        fixture.transport.send(.mediaConnectionState(degraded: true))
        try await waitUntil { fixture.media.isMediaDegraded }
        await drain()
        #expect(fixture.controller.call === replacement)
        #expect(fixture.controller.connection == .connected)
        #expect(fixture.controller.connectedAt == connectedAt)
        #expect(!replacement.isOwnMediaDegraded)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
        await replacement.disconnect()
    }
    
    @Test(arguments: [ElementCallConnection.idle, .joining, .ended, .failed("failed")])
    func ownMediaEventsCannotConnectAnUnreadyOrTerminalHost(connection: ElementCallConnection) async throws {
        let fixture = Fixture(connection: connection)
        await fixture.media.start()
        fixture.controller.observeMediaSession(fixture.media)
        fixture.transport.send(.ownMediaConnectionState(degraded: true))
        fixture.transport.send(.ownMediaConnectionState(degraded: false))
        fixture.transport.send(.mediaConnectionState(degraded: true))
        try await waitUntil { fixture.media.isMediaDegraded }
        await drain()
        #expect(fixture.controller.connection == connection)
        #expect(fixture.controller.connectedAt == nil)
        #expect(fixture.system.requests.isEmpty)
        await fixture.media.disconnect()
    }
    
    private final class CameraPermission {
        private let replies: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation
        private(set) var wasRequested = false
        
        init() {
            (replies, continuation) = AsyncStream.makeStream()
        }
        
        func request() async -> Bool {
            wasRequested = true
            var iterator = replies.makeAsyncIterator()
            return await iterator.next() ?? false
        }
        
        func answer() {
            continuation.yield(true)
            continuation.finish()
        }
    }
    
    private struct Fixture {
        let room = ElementCallFakeRoom()
        let system = ElementCallFakeSystem()
        let transport: FakeMediaSession
        let media: MatrixRTCMediaSession
        let rtcCall = MatrixRTCCall(rtcCall: FakeRtcCall())
        let controller: ElementCallController
        
        init(connection: ElementCallConnection, connectedAt: Date? = nil,
             isAudioCall: Bool = true, holdingPublish: FfiStreamKind? = nil) {
            transport = FakeMediaSession(holdingPublish: holdingPublish)
            media = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
            controller = ElementCallController(rtcClient: MatrixRTCClient(transport: ElementCallFakeTransport()),
                                               system: system, options: .init(), style: .stock, logger: nil)
            controller.setPreviewState(callData: .init(isAudioCall: isAudioCall, isStartingCall: true),
                                       room: room, connection: connection, connectedAt: connectedAt, call: media, rtcCall: rtcCall)
        }
    }
    
    private func replaceMedia(in fixture: Fixture, connection: ElementCallConnection) -> MatrixRTCMediaSession {
        let replacement = MatrixRTCMediaSession(localMemberID: "replacement", mediaSession: FakeMediaSession())
        fixture.controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: true),
                                           room: fixture.room, connection: connection, call: replacement)
        return replacement
    }
    
    private func drain() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
    
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        throw FakeRtcCall.RefusedError()
    }
}
