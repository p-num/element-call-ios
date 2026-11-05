//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
import ElementCallKit
import Foundation
import Testing

/// The list the indicator shows waits for a cause to last, and goes the moment none is left
/// (034 R35). Driven by the host's connectivity report, the one cause a controller has without
/// media.
@Suite("Interruption hold")
@MainActor
struct InterruptionHoldTests {
    @Test
    func aCauseIsShownOnlyOnceItHasLasted() async throws {
        let (controller, clock) = start()
        controller.reportConnectivity(isOnline: false)
        try await waitUntil { controller.interruptionHoldTask != nil }
        #expect(controller.interruptions.isEmpty)
        
        clock.advance(by: ElementCallController.interruptionHold)
        try await waitUntil { !controller.interruptions.isEmpty }
        #expect(controller.interruptions == [.ownServer(isMembershipLapsed: false)])
        
        // Gone without a wait.
        controller.reportConnectivity(isOnline: true)
        try await waitUntil { controller.interruptions.isEmpty }
    }
    
    @Test
    func aBlipIsNeverShown() async throws {
        let (controller, clock) = start()
        controller.reportConnectivity(isOnline: false)
        try await waitUntil { controller.interruptionHoldTask != nil }
        controller.reportConnectivity(isOnline: true)
        try await waitUntil { controller.interruptionHoldTask == nil }
        
        clock.advance(by: ElementCallController.interruptionHold)
        await Task.yield()
        #expect(controller.interruptions.isEmpty)
    }
    
    private func start() -> (ElementCallController, MatrixRTCManualClock) {
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: ElementCallFakeSystem(),
                                               options: ElementCallOptions(),
                                               style: .stock,
                                               logger: nil)
        let clock = MatrixRTCManualClock()
        controller.clock = clock
        controller.setPreviewState(callData: ElementCallData(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(),
                                   connection: .connected)
        controller.followSignalling()
        controller.followInterruptions()
        return (controller, clock)
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
