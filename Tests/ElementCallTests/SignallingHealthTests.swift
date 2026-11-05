//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation
import Testing

/// The host's connectivity report reaching the core, and the core's verdict coming back: the real
/// client, over a backend that never fails, so the report is the only thing that can move it
/// (034 C3, C4).
@Suite("Signalling health")
@MainActor
struct SignallingHealthTests {
    @Test
    func theHostsReportMovesTheHealth() async throws {
        let client = MatrixRTCClient(backend: ElementCallFakeMatrixBackend())
        var updates = client.signallingUpdates().makeAsyncIterator()
        
        #expect(await updates.next() == .reachable)
        
        client.reportConnectivity(isOnline: false)
        let offline = try #require(await updates.next())
        #expect(!offline.isReachable)
        
        client.reportConnectivity(isOnline: true)
        #expect(await updates.next() == .reachable)
    }
    
    /// Reporting what the core already believes changes nothing, so nothing is published.
    @Test
    func theCurrentValueAgainIsNotAChange() async throws {
        let client = MatrixRTCClient(backend: ElementCallFakeMatrixBackend())
        var updates = client.signallingUpdates().makeAsyncIterator()
        #expect(await updates.next() == .reachable)
        
        client.reportConnectivity(isOnline: true)
        client.reportConnectivity(isOnline: false)
        
        let next = try #require(await updates.next())
        #expect(!next.isReachable)
    }
}
