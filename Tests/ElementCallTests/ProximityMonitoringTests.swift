//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
import ElementCallKit
import Testing

/// The screen goes dark at the ear only while a call is on the earpiece, ringing included.
@MainActor
struct ProximityMonitoringTests {
    @Test
    func onlyACallOnTheEarpieceIsMonitored() {
        let airPods = CallAudioOutput(kind: .bluetooth, id: "airpods", name: "AirPods Pro")
        #expect(ElementCallController.isProximityMonitored(isInCall: true, output: .receiver))
        #expect(!ElementCallController.isProximityMonitored(isInCall: true, output: .speaker))
        #expect(!ElementCallController.isProximityMonitored(isInCall: true, output: airPods))
        #expect(!ElementCallController.isProximityMonitored(isInCall: true, output: nil))
        #expect(!ElementCallController.isProximityMonitored(isInCall: false, output: .receiver))
    }
}
