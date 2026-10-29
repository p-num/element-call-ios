//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Testing

@MainActor
struct CameraPublicationTests {
    @Test
    func cameraPublicationStartsMutedUntilCaptureIsReady() async throws {
        let transport = FakeMediaSession()
        let call = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
        
        try await call.setCameraEnabled(true)
        
        #expect(transport.published.count == 1)
        #expect(transport.published.first?.kind == .camera)
        #expect(transport.published.first?.muted == true)
        #expect(transport.localMutes.last?.muted == false)
        #expect(call.isCameraEnabled)
        
        try await call.setCameraEnabled(false)
        #expect(transport.localMutes.last?.muted == true)
        #expect(!call.isCameraEnabled)
        try await call.setCameraEnabled(true)
        #expect(transport.published.count == 1)
        #expect(transport.localMutes.last?.muted == false)
        #expect(call.isCameraEnabled)
        await call.disconnect()
    }
    
    @Test
    func cameraPublicationCompletingAfterDisconnectNeverStartsOrUnmutes() async throws {
        let transport = FakeMediaSession(holdingPublish: .camera)
        let call = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
        let enabling = Task { try await call.setCameraEnabled(true) }
        defer { transport.answerPublish() }
        for _ in 0..<1000 {
            if transport.hasPendingPublish {
                break
            }
            await Task.yield()
        }
        try #require(transport.hasPendingPublish)
        await call.disconnect()
        transport.answerPublish()
        await #expect(throws: CancellationError.self) { try await enabling.value }
        #expect(call.hasEnded)
        #expect(!call.isCameraEnabled)
        #expect(transport.published.count == 1)
        #expect(transport.published.first?.muted == true)
        #expect(!transport.localMutes.contains { $0.kind == .camera && !$0.muted })
    }
    
    @Test(arguments: [false, true])
    func concurrentCameraEnablesShareOneMutedPublicationAndHonorTheLastIntent(turnOffBetweenEnables: Bool) async throws {
        let transport = FakeMediaSession(holdingPublish: .camera)
        let call = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
        let firstEnable = Task { try await call.setCameraEnabled(true) }
        defer { transport.answerPublish() }
        try await waitUntil { transport.hasPendingPublish }
        if turnOffBetweenEnables {
            try await call.setCameraEnabled(false)
        }
        var secondEnableStarted = false
        let secondEnable = Task {
            secondEnableStarted = true
            try await call.setCameraEnabled(true)
        }
        try await waitUntil { secondEnableStarted }
        
        #expect(transport.published.count == 1)
        #expect(transport.published.first?.muted == true)
        #expect(!call.isCameraEnabled)
        #expect(!transport.localMutes.contains { $0.kind == .camera && !$0.muted })
        transport.answerPublish()
        try await firstEnable.value
        try await secondEnable.value
        #expect(transport.published.count == 1)
        #expect(call.isCameraEnabled)
        #expect(transport.localMutes.last { $0.kind == .camera }?.muted == false)
        await call.disconnect()
    }
    
    @Test
    func anInterruptionWinsOverAnEarlierUnmuteAcknowledgement() async throws {
        let transport = FakeMediaSession()
        let call = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
        transport.holdNextMute(kind: .camera, muted: false)
        let enabling = Task { try await call.setCameraEnabled(true) }
        defer { transport.answerMute() }
        try await waitUntil { transport.hasPendingMute }
        await call.handleCameraInterruption(true)
        #expect(transport.appliedLocalMutes.last { $0.kind == .camera }?.muted == true)
        
        transport.answerMute()
        try await enabling.value
        #expect(call.isCameraEnabled)
        #expect(call.isCameraInterrupted)
        #expect(transport.appliedLocalMutes.last { $0.kind == .camera }?.muted == true)
        await call.disconnect()
    }
    
    @Test
    func turningTheCameraOffWinsOverAnEarlierInterruptionRecoveryUnmute() async throws {
        let transport = FakeMediaSession()
        let call = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false)
        try await call.setCameraEnabled(true)
        await call.handleCameraInterruption(true)
        transport.holdNextMute(kind: .camera, muted: false)
        let recovering = Task { await call.handleCameraInterruption(false) }
        defer { transport.answerMute() }
        try await waitUntil { transport.hasPendingMute }
        try await call.setCameraEnabled(false)
        #expect(transport.appliedLocalMutes.last { $0.kind == .camera }?.muted == true)
        
        transport.answerMute()
        await recovering.value
        #expect(!call.isCameraEnabled)
        #expect(transport.appliedLocalMutes.last { $0.kind == .camera }?.muted == true)
        await call.disconnect()
    }
    
    #if targetEnvironment(simulator)
    @Test
    func unavailableCameraNeverAdvertisesUnmutedVideoAndCanBeRetried() async throws {
        let transport = FakeMediaSession()
        let call = MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport)
        try await call.publishMicrophone(muted: false)
        
        for _ in 0..<2 {
            await #expect(throws: MatrixRTCError.self) {
                try await call.setCameraEnabled(true)
            }
            #expect(!call.isCameraEnabled)
            #expect(!call.hasEnded)
            let allCameraPublicationsAreMuted = transport.published.filter { $0.kind == .camera }.allSatisfy(\.muted)
            #expect(allCameraPublicationsAreMuted)
            #expect(!transport.localMutes.contains { $0.kind == .camera && !$0.muted })
        }
        #expect(transport.published.filter { $0.kind == .camera }.count == 1)
        #expect(!call.isMicrophoneMuted)
        await call.disconnect()
    }
    #endif
    
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
