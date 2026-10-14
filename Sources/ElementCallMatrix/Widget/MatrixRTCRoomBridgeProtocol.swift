//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation

nonisolated enum MatrixRTCRoomBridgeError: Error, Sendable, Equatable {
    /// The bridge is not (or no longer) running for the room.
    case notRunning
    case timedOut
    /// The bridge answered, but not with what the operation needs.
    case invalidResponse(String)
    /// The homeserver refused the request; `errcode` and status when the bridge could tell.
    case matrixAPI(errcode: String?, httpStatus: Int?, message: String)
}

/// Exactly the Matrix operations the released SDK bindings do not expose yet for a room: delayed
/// events, room event IDs, the room-state and timeline feeds and to-device messaging.
/// `ElementCallSDKRoom` routes those through whatever implements this; everything else goes straight
/// to the SDK.
///
/// Today's implementation is `WidgetMatrixBridge`, driving the SDK widget driver in process. See that
/// file's header for the exact bindings that retire this. Once they land, an SDK-backed
/// implementation replaces it and the room does not change.
nonisolated protocol MatrixRTCRoomBridgeProtocol: AnyObject, Sendable {
    var roomID: String { get }
    
    /// Returns once the bridge can serve requests.
    func start() async -> Result<Void, MatrixRTCRoomBridgeError>
    func stop() async
    
    /// - Returns: the MSC4140 delay ID.
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async -> Result<String, MatrixRTCRoomBridgeError>
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async -> Result<Void, MatrixRTCRoomBridgeError>
    /// - Returns: the event ID.
    func sendRoomEvent(eventType: String, contentJSON: String) async -> Result<String, MatrixRTCRoomBridgeError>
    /// The transports the homeserver advertises over MSC4515, as the raw JSON array. Homeserver-wide
    /// despite arriving through a room's driver, which just forwards to the client's discovery.
    func rtcTransports() async -> Result<String, MatrixRTCRoomBridgeError>
    /// `messages` is user ID → device ID → content JSON.
    /// - Returns: the recipients that were **not** served, user ID → device IDs.
    func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async -> Result<[String: [String]], MatrixRTCRoomBridgeError>
    
    /// The full current list of state events of that type: once the room's state has been read,
    /// immediately and empty included, then on every change.
    func stateEvents(eventType: String) -> AsyncStream<[ElementCallRoomEvent]>
    /// Message-like events of these types as they arrive.
    func timelineEvents(eventTypes: [String]) -> AsyncStream<[ElementCallRoomEvent]>
    /// The ID of every event redacted while the bridge runs.
    func redactions() -> AsyncStream<String>
    /// Every to-device message the bridge is allowed to receive, for as long as it runs.
    func toDeviceMessages() -> AsyncStream<MatrixRTCToDeviceMessage>
}
