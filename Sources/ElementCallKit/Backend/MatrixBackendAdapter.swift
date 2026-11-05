//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc

/// The core's `MatrixBackend` over the host's ``ElementCallMatrixBackendProtocol``. The one place the
/// bindings' generated spellings meet the host's, so a host never writes `roomId` or `delayMs`; it
/// only carries, and decides nothing.
final nonisolated class MatrixBackendAdapter: MatrixBackend {
    private let backend: any ElementCallMatrixBackendProtocol
    
    init(_ backend: any ElementCallMatrixBackendProtocol) {
        self.backend = backend
    }
    
    func ownUserId() -> String {
        backend.userID
    }
    
    func ownDeviceId() -> String {
        backend.deviceID
    }
    
    func sendStickyEvent(roomId: String, eventType: String, contentJson: String, durationMs: UInt64) async throws -> String {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.sendStickyEvent(roomID: roomId, eventType: eventType, contentJSON: contentJson, duration: .milliseconds(durationMs))
        }
    }
    
    func sendDelayedStateEvent(roomId: String, eventType: String, stateKey: String, contentJson: String, delayMs: UInt64) async throws -> String {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.sendDelayedStateEvent(roomID: roomId, eventType: eventType, stateKey: stateKey, contentJSON: contentJson, delay: .milliseconds(delayMs))
        }
    }
    
    func sendDelayedStickyEvent(roomId: String, eventType: String, contentJson: String, stickyDurationMs: UInt64, delayMs: UInt64) async throws -> String {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.sendDelayedStickyEvent(roomID: roomId,
                                                     eventType: eventType,
                                                     contentJSON: contentJson,
                                                     stickyDuration: .milliseconds(stickyDurationMs),
                                                     delay: .milliseconds(delayMs))
        }
    }
    
    func restartDelayedEvent(roomId: String, delayId: String) async throws {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.restartDelayedEvent(roomID: roomId, delayID: delayId)
        }
    }
    
    func cancelDelayedEvent(roomId: String, delayId: String) async throws {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.cancelDelayedEvent(roomID: roomId, delayID: delayId)
        }
    }
    
    /// One verdict per recipient, from the host's undelivered ones: the core re-sends only to those.
    func sendToDeviceMessage(recipients: [FfiToDeviceRecipient], messageType: String, contentJson: String) async throws -> [FfiToDeviceDelivery] {
        let devices = recipients.map { ElementCallDevice(userID: $0.userId, deviceID: $0.deviceId) }
        let failures = try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.sendToDeviceMessage(eventType: messageType, contentJSON: contentJson, to: devices)
        }
        return devices.map { FfiToDeviceDelivery(userId: $0.userID, deviceId: $0.deviceID, error: failures[$0]) }
    }
    
    func sendStateEvent(roomId: String, eventType: String, stateKey: String, contentJson: String) async throws -> String {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.sendStateEvent(roomID: roomId, eventType: eventType, stateKey: stateKey, contentJSON: contentJson)
        }
    }
    
    func sendRoomEvent(roomId: String, eventType: String, contentJson: String) async throws -> String {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.sendRoomEvent(roomID: roomId, eventType: eventType, contentJSON: contentJson)
        }
    }
    
    func redactEvent(roomId: String, eventId: String, reason: String?) async throws {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.redactEvent(roomID: roomId, eventID: eventId, reason: reason)
        }
    }
    
    func subscribeRoom(roomId: String, subjects: FfiRoomSubjects, sink: RoomSink) throws -> BackendSubscription {
        do {
            let subscription = try backend.subscribeToRoom(roomID: roomId,
                                                           subjects: ElementCallRoomSubjects(stateEventTypes: subjects.stateEventTypes,
                                                                                             timelineEventTypes: subjects.timelineEventTypes),
                                                           sink: ElementCallRoomSink(sink))
            return Subscription(subscription)
        } catch {
            throw error.ffi
        }
    }
    
    func subscribeToDevice(eventTypes: [String], sink: ToDeviceSink) throws -> BackendSubscription {
        do {
            return try Subscription(backend.subscribeToDeviceMessages(eventTypes: eventTypes, sink: ElementCallToDeviceSink(sink)))
        } catch {
            throw error.ffi
        }
    }
    
    func relations(roomId: String, eventId: String, relType: String, eventType: String) async throws -> [FfiEventIn] {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.relations(roomID: roomId, eventID: eventId, relationshipType: relType, eventType: eventType).map(\.ffi)
        }
    }
    
    func openidToken() async throws -> FfiOpenIdToken {
        let token = try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.openIDToken()
        }
        return FfiOpenIdToken(accessToken: token.accessToken,
                              tokenType: token.tokenType,
                              matrixServerName: token.matrixServerName,
                              expiresInSecs: UInt64(max(0, token.expiresIn.components.seconds)))
    }
    
    func livekitToken(request: FfiLiveKitTokenRequest) async throws -> String {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.liveKitToken(for: ElementCallLiveKitTokenRequest(serverName: request.serverName,
                                                                               url: request.url,
                                                                               roomID: request.roomId,
                                                                               slotID: request.slotId,
                                                                               memberID: request.memberId))
        }
    }
    
    func rtcTransports() async throws -> String {
        try await carry { () async throws(ElementCallMatrixBackendError) in
            try await backend.rtcTransportsJSON()
        }
    }
    
    // MARK: - Private
    
    /// Hands the host's failure to the core in the one error type it reads; anything else it would
    /// count as an unexpected callback error.
    private func carry<T>(_ body: () async throws(ElementCallMatrixBackendError) -> T) async throws(FfiBackendError) -> T {
        do {
            return try await body()
        } catch {
            throw error.ffi
        }
    }
    
    private final class Subscription: BackendSubscription {
        private let subscription: ElementCallBackendSubscription
        
        init(_ subscription: ElementCallBackendSubscription) {
            self.subscription = subscription
        }
        
        func cancel() {
            subscription.cancel()
        }
    }
}

nonisolated extension ElementCallMatrixBackendError {
    var ffi: FfiBackendError {
        .Failed(errcode: errorCode,
                status: statusCode.flatMap(UInt16.init(exactly:)),
                retryAfterMs: retryAfter?.inMilliseconds,
                permanent: isPermanent,
                reason: reason)
    }
}
