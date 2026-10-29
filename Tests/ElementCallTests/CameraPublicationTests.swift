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
}
