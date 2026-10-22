//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
@testable import ElementCallMatrix
import Foundation
import MatrixRustSDK
import Testing

/// The parts of the transport adapter that survive the widget-driver stopgap: how bridge failures
/// reach the core, and the session-long to-device relay.
///
/// Serialized for the same reason as `WidgetMatrixBridgeTests`: real deadlines, and parallel
/// execution on a hosted runner starves them.
@Suite(.timeLimit(.minutes(1)), .serialized)
nonisolated struct MatrixRTCTransportAdapterTests {
    /// The core decides which refusals retire a feature, so a refusal reaches it with the
    /// homeserver's own words rather than a verdict made here.
    @Test
    func homeserverRefusalsCarryTheirErrcodeAndStatus() {
        #expect(MatrixRTCRoomBridgeError.matrixAPI(errcode: "M_UNRECOGNIZED", httpStatus: 404, message: "Unrecognized request").transportError
            == .failed("Unrecognized request", errcode: "M_UNRECOGNIZED", httpStatus: 404))
        #expect(MatrixRTCRoomBridgeError.matrixAPI(errcode: "M_FORBIDDEN", httpStatus: 403, message: "Sending delayed events has been disallowed").transportError
            == .failed("Sending delayed events has been disallowed", errcode: "M_FORBIDDEN", httpStatus: 403))
    }
    
    @Test
    func bridgeFailuresCarryNoErrcode() {
        #expect(MatrixRTCRoomBridgeError.timedOut.transportError == .failed("timedOut"))
        #expect(MatrixRTCRoomBridgeError.notRunning.transportError == .failed("notRunning"))
    }
    
    @Test
    func relayFansInByEventTypeUntilUnsubscribed() async throws {
        let relay = ToDeviceRelay()
        var keys = relay.subscribe(eventTypes: ["io.element.call.encryption_keys"]).makeAsyncIterator()
        var both = relay.subscribe(eventTypes: ["io.element.call.encryption_keys", "org.matrix.msc4143.rtc.encryption_key"]).makeAsyncIterator()
        
        relay.publish(message(type: "org.matrix.msc4143.rtc.encryption_key", sender: "@a:example.org"))
        relay.publish(message(type: "io.element.call.encryption_keys", sender: "@b:example.org"))
        
        #expect(try #require(await keys.next()).attestedSenderID == "@b:example.org")
        #expect(try #require(await both.next()).attestedSenderID == "@a:example.org")
        #expect(try #require(await both.next()).attestedSenderID == "@b:example.org")
        
        relay.publish(message(type: "m.other", sender: "@c:example.org"))
        relay.publish(message(type: "io.element.call.encryption_keys", sender: "@d:example.org"))
        #expect(try #require(await keys.next()).attestedSenderID == "@d:example.org")
    }
    
    private func message(type: String, sender: String) -> MatrixRTCToDeviceMessage {
        MatrixRTCToDeviceMessage(eventType: type, attestedSenderID: sender, senderDeviceID: "DEV", isSenderCrossSigned: true, wasEncrypted: true, contentJSON: "{}")
    }
}
