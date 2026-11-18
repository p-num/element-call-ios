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
    
    @Test("A call turns the sensor on for the earpiece, and off once it leaves it or ends")
    func callTogglesTheSensor() {
        #expect(ElementCallController.proximityMonitoringChange(isMonitoring: false, isInCall: true, output: .receiver) == true)
        #expect(ElementCallController.proximityMonitoringChange(isMonitoring: true, isInCall: true, output: .speaker) == false)
        #expect(ElementCallController.proximityMonitoringChange(isMonitoring: true, isInCall: false, output: .receiver) == false)
    }
    
    @Test("A controller without a call leaves the sensor alone, whoever turned it on")
    func idleControllerLeavesTheSensorAlone() {
        // Another controller's earpiece call may have it on, and route changes reach every controller.
        #expect(ElementCallController.proximityMonitoringChange(isMonitoring: false, isInCall: false, output: .receiver) == nil)
        #expect(ElementCallController.proximityMonitoringChange(isMonitoring: false, isInCall: false, output: .speaker) == nil)
    }
    
    @Test("A call whose output hasn't changed what it wants writes nothing")
    func unchangedCallWritesNothing() {
        #expect(ElementCallController.proximityMonitoringChange(isMonitoring: true, isInCall: true, output: .receiver) == nil)
        #expect(ElementCallController.proximityMonitoringChange(isMonitoring: false, isInCall: true, output: .speaker) == nil)
    }
}
