//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// The core's one Matrix backend, over the host's transport. The core decides what to send and what
/// to read; this only routes each call to the room the client opened, and passes events through raw.
///
/// The core's calls are flat and carry a room ID. The port is per room, because a room is what holds
/// the host's per-room machinery alive, so ``MatrixRTCClient`` registers each room it opens here
/// before the core subscribes to it, and unregisters it only once the core has left.
final nonisolated class MatrixRTCBackend: MatrixBackend {
    private let transport: any ElementCallMatrixTransportProtocol
    private let rooms = Mutex(Rooms())
    
    private struct Rooms {
        var byID = [String: any ElementCallMatrixRoomProtocol]()
        /// Most recent last, for the one question the core does not scope to a room.
        var order = [String]()
    }
    
    init(transport: any ElementCallMatrixTransportProtocol) {
        self.transport = transport
    }
    
    func register(_ room: any ElementCallMatrixRoomProtocol) {
        rooms.withLock { rooms in
            rooms.byID[room.roomID] = room
            rooms.order.removeAll { $0 == room.roomID }
            rooms.order.append(room.roomID)
        }
    }
    
    func unregister(roomID: String) {
        rooms.withLock { rooms in
            rooms.byID[roomID] = nil
            rooms.order.removeAll { $0 == roomID }
        }
    }
    
    // MARK: - Account
    
    func ownUserId() -> String {
        transport.userID
    }
    
    func ownDeviceId() -> String {
        transport.deviceID
    }
    
    // MARK: - Sends
    
    func sendStickyEvent(roomId: String, eventType: String, contentJson: String, durationMs: UInt64) async throws -> String {
        try await command("sendStickyEvent(\(eventType), \(durationMs)ms)") {
            try await room(roomId).sendStickyEvent(eventType: eventType, contentJSON: contentJson, durationMs: durationMs)
        }
    }
    
    func sendDelayedEvent(roomId: String, eventType: String, stateKey: String?, contentJson: String, delayMs: UInt64) async throws -> String {
        try await command("sendDelayedEvent(\(eventType))") {
            try await room(roomId).sendDelayedEvent(eventType: eventType, stateKey: stateKey, contentJSON: contentJson, delayMs: delayMs)
        }
    }
    
    // Restart and cancel differ only by the action; swapping them retires the membership the
    // delayed leave protects, dropping us out of a live call minutes later. Pinned by tests.
    func restartDelayedEvent(roomId: String, delayId: String) async throws {
        try await command("restartDelayedEvent") {
            try await room(roomId).updateDelayedEvent(delayID: delayId, action: .restart)
        }
    }
    
    func cancelDelayedEvent(roomId: String, delayId: String) async throws {
        try await command("cancelDelayedEvent") {
            try await room(roomId).updateDelayedEvent(delayID: delayId, action: .cancel)
        }
    }
    
    /// Media keys never go out in the clear, and every recipient gets a verdict: one reported as
    /// delivered is never re-sent to, so a failure reported as a success leaves a member keyless.
    func sendToDeviceMessage(recipients: [FfiToDeviceRecipient], messageType: String, contentJson: String) async throws -> [FfiToDeviceDelivery] {
        var messages = [String: [String: String]]()
        for recipient in recipients {
            messages[recipient.userId, default: [:]][recipient.deviceId] = contentJson
        }
        
        MatrixRTCLog.info("sendToDeviceMessage(\(messageType)) to \(recipients.map { "\($0.userId)/\($0.deviceId)" })")
        
        return try await command("sendToDeviceMessage(\(messageType))") {
            let failures = try await transport.sendToDeviceMessage(eventType: messageType, messages: messages)
            return recipients.map { recipient in
                let failed = failures[recipient.userId]?.contains(recipient.deviceId) ?? false
                return FfiToDeviceDelivery(userId: recipient.userId,
                                           deviceId: recipient.deviceId,
                                           error: failed ? "Not delivered by the homeserver" : nil)
            }
        }
    }
    
    func sendStateEvent(roomId: String, eventType: String, stateKey: String, contentJson: String) async throws -> String {
        try await command("sendStateEvent(\(eventType))") {
            try await room(roomId).sendStateEvent(eventType: eventType, stateKey: stateKey, contentJSON: contentJson)
        }
    }
    
    func sendRoomEvent(roomId: String, eventType: String, contentJson: String) async throws -> String {
        try await command("sendRoomEvent(\(eventType))") {
            try await room(roomId).sendRoomEvent(eventType: eventType, contentJSON: contentJson)
        }
    }
    
    func redactEvent(roomId: String, eventId: String, reason: String?) async throws {
        try await command("redactEvent") {
            try await room(roomId).redactEvent(eventID: eventId, reason: reason)
        }
    }
    
    // MARK: - Reads
    
    func subscribeRoom(roomId: String, subjects: FfiRoomSubjects, sink: RoomSink) throws -> BackendSubscription {
        try forwardRoom(roomID: roomId, subjects: subjects, into: sink)
    }
    
    /// One task per subject, so a feed that ends ends only itself. Each delivers from the start of
    /// its stream, which is the current set: that first delivery is what the core waits on before
    /// it treats the room as ready.
    func forwardRoom(roomID: String, subjects: FfiRoomSubjects, into sink: some RoomSubjectSink) throws -> MatrixRTCBackendSubscription {
        let room = try room(roomID)
        MatrixRTCLog.info("Subscribing to \(roomID): state \(subjects.stateEventTypes), timeline \(subjects.timelineEventTypes)")
        
        var tasks = [Task<Void, Never>]()
        tasks.append(Task {
            for await events in room.stickyEvents() {
                sink.onStickyEvents(events: events.map(\.ffi))
            }
        })
        for eventType in subjects.stateEventTypes {
            tasks.append(Task {
                for await events in room.stateEvents(eventType: eventType) {
                    sink.onStateEvents(eventType: eventType, events: events.map(\.ffi))
                }
            })
        }
        tasks.append(Task {
            for await userIDs in room.joinedMemberIDs() {
                sink.onJoinedMembers(userIds: userIDs)
            }
        })
        tasks.append(Task {
            for await isEncrypted in room.isEncrypted() {
                sink.onEncryption(encrypted: isEncrypted)
            }
        })
        if !subjects.timelineEventTypes.isEmpty {
            tasks.append(Task {
                for await events in room.timelineEvents(eventTypes: subjects.timelineEventTypes) {
                    sink.onTimelineEvents(events: events.map(\.ffi))
                }
            })
        }
        tasks.append(Task {
            for await eventID in room.redactions() {
                sink.onRedaction(eventId: eventID)
            }
        })
        return MatrixRTCBackendSubscription(tasks: tasks)
    }
    
    func subscribeToDevice(eventTypes: [String], sink: ToDeviceSink) throws -> BackendSubscription {
        forwardToDevice(eventTypes: eventTypes, into: sink)
    }
    
    func forwardToDevice(eventTypes: [String], into sink: some ToDeviceSubjectSink) -> MatrixRTCBackendSubscription {
        MatrixRTCLog.info("Subscribing to to-device \(eventTypes)")
        let task = Task { [transport] in
            for await message in transport.toDeviceMessages(eventTypes: eventTypes) {
                sink.onToDeviceMessage(message: message.ffi)
            }
        }
        return MatrixRTCBackendSubscription(tasks: [task])
    }
    
    func relations(roomId: String, eventId: String, relType: String, eventType: String) async throws -> [FfiEventIn] {
        try await command("relations(\(relType), \(eventType))") {
            try await room(roomId).relations(eventID: eventId, relType: relType, eventType: eventType).map(\.ffi)
        }
    }
    
    func openidToken() async throws -> FfiOpenIdToken {
        try await command("openidToken") {
            let token = try await transport.requestOpenIDToken()
            return FfiOpenIdToken(accessToken: token.accessToken,
                                  tokenType: token.tokenType,
                                  matrixServerName: token.matrixServerName,
                                  expiresInSecs: UInt64(max(0, token.expiresIn)))
        }
    }
    
    /// Homeserver-wide, but the port answers it per room, so it is asked of the room opened last. The
    /// core asks only while a room is joining, so there always is one.
    func rtcTransports() async throws -> String {
        try await command("rtcTransports") {
            guard let room = rooms.withLock({ rooms in rooms.order.last.flatMap { rooms.byID[$0] } }) else {
                throw MatrixRTCTransportError.failed("No open room to ask for the homeserver's RTC transports")
            }
            let transports = try await room.rtcTransports()
            MatrixRTCLog.info("Homeserver offers \(transports)")
            return transports
        }
    }
    
    // MARK: - Private
    
    private func room(_ roomID: String) throws(FfiBackendError) -> any ElementCallMatrixRoomProtocol {
        guard let room = rooms.withLock({ $0.byID[roomID] }) else {
            throw FfiBackendError.Failed(errcode: nil, status: nil, reason: "No open room for \(roomID)")
        }
        return room
    }
    
    /// Every failure leaves as an `FfiBackendError` carrying what the homeserver said, if anything.
    /// The core classifies it: which refusals retire the delayed leave is its decision, not ours.
    private func command<T>(_ description: String, _ body: () async throws -> T) async throws(FfiBackendError) -> T {
        do {
            return try await body()
        } catch let error as FfiBackendError {
            MatrixRTCLog.error("\(description) failed: \(error)")
            throw error
        } catch let error as MatrixRTCTransportError {
            switch error {
            case .notSupported(let message):
                MatrixRTCLog.warning("\(description) is not supported: \(message)")
                throw FfiBackendError.Failed(errcode: nil, status: nil, reason: "\(description): \(message)")
            case .failed(let message, let errcode, let httpStatus):
                MatrixRTCLog.error("\(description) failed (\(errcode ?? "no errcode"), \(httpStatus.map(String.init) ?? "no status")): \(message)")
                throw FfiBackendError.Failed(errcode: errcode, status: httpStatus, reason: "\(description): \(message)")
            }
        } catch {
            MatrixRTCLog.error("\(description) failed: \(error)")
            throw FfiBackendError.Failed(errcode: nil, status: nil, reason: "\(description): \(error)")
        }
    }
}

/// Cancels every feed of one subscription. Idempotent, as the core requires: cancelling a finished
/// task does nothing.
final nonisolated class MatrixRTCBackendSubscription: BackendSubscription {
    private let tasks: [Task<Void, Never>]
    
    init(tasks: [Task<Void, Never>]) {
        self.tasks = tasks
    }
    
    func cancel() {
        tasks.forEach { $0.cancel() }
    }
}

/// The FFI's `RoomSink`, as a protocol: the real one can only be made by the core, so tests deliver
/// into a recording one instead.
nonisolated protocol RoomSubjectSink: Sendable {
    func onStickyEvents(events: [FfiEventIn])
    func onStateEvents(eventType: String, events: [FfiEventIn])
    func onJoinedMembers(userIds: [String])
    func onEncryption(encrypted: Bool)
    func onTimelineEvents(events: [FfiEventIn])
    func onRedaction(eventId: String)
}

extension RoomSink: RoomSubjectSink { }

/// The FFI's `ToDeviceSink`, as a protocol, for the same reason as ``RoomSubjectSink``.
nonisolated protocol ToDeviceSubjectSink: Sendable {
    func onToDeviceMessage(message: FfiToDeviceMessageIn)
}

extension ToDeviceSink: ToDeviceSubjectSink { }

nonisolated extension ElementCallRoomEvent {
    var ffi: FfiEventIn {
        FfiEventIn(eventId: eventID,
                   sender: sender,
                   eventType: eventType,
                   stateKey: stateKey,
                   originServerTs: originServerTimestamp,
                   contentJson: contentJSON,
                   encryption: FfiEventEncryption(encrypted: encryptionInfo != nil,
                                                  senderDeviceId: encryptionInfo?.senderDeviceID,
                                                  senderCrossSigned: encryptionInfo?.isSenderCrossSigned))
    }
}

nonisolated extension MatrixRTCToDeviceMessage {
    var ffi: FfiToDeviceMessageIn {
        FfiToDeviceMessageIn(sender: attestedSenderID,
                             eventType: eventType,
                             contentJson: contentJSON,
                             encryption: FfiEventEncryption(encrypted: wasEncrypted,
                                                            senderDeviceId: senderDeviceID,
                                                            senderCrossSigned: isSenderCrossSigned))
    }
}
