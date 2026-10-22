//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// A to-device message delivered by the homeserver, decrypted, with what the client reports about how
/// it arrived. The core decides what that information means; the host only passes it on.
public nonisolated struct MatrixRTCToDeviceMessage: Sendable {
    public let eventType: String
    public let attestedSenderID: String
    public let senderDeviceID: String?
    /// Nil when the client does not say. Never inferred from ``wasEncrypted``.
    public let isSenderCrossSigned: Bool?
    public let wasEncrypted: Bool
    public let contentJSON: String
    
    public init(eventType: String, attestedSenderID: String, senderDeviceID: String?, isSenderCrossSigned: Bool?, wasEncrypted: Bool, contentJSON: String) {
        self.eventType = eventType
        self.attestedSenderID = attestedSenderID
        self.senderDeviceID = senderDeviceID
        self.isSenderCrossSigned = isSenderCrossSigned
        self.wasEncrypted = wasEncrypted
        self.contentJSON = contentJSON
    }
}

/// How the client decrypted a room event, as it reports it.
public nonisolated struct ElementCallEventEncryptionInfo: Sendable, Hashable {
    public let senderDeviceID: String?
    /// Nil when the client does not say.
    public let isSenderCrossSigned: Bool?
    
    public init(senderDeviceID: String?, isSenderCrossSigned: Bool?) {
        self.senderDeviceID = senderDeviceID
        self.isSenderCrossSigned = isSenderCrossSigned
    }
}

/// A room event as the client holds it: decrypted, raw, never parsed by the host.
public nonisolated struct ElementCallRoomEvent: Sendable, Hashable {
    public let eventID: String
    public let sender: String
    /// The wire spelling, unstable prefixes included.
    public let eventType: String
    /// Nil for a message-like event.
    public let stateKey: String?
    /// Milliseconds since the epoch.
    public let originServerTimestamp: UInt64
    /// `{}` for a redacted event.
    public let contentJSON: String
    /// Nil for a cleartext event, or when the client does not say.
    public let encryptionInfo: ElementCallEventEncryptionInfo?
    
    public init(eventID: String,
                sender: String,
                eventType: String,
                stateKey: String?,
                originServerTimestamp: UInt64,
                contentJSON: String,
                encryptionInfo: ElementCallEventEncryptionInfo?) {
        self.eventID = eventID
        self.sender = sender
        self.eventType = eventType
        self.stateKey = stateKey
        self.originServerTimestamp = originServerTimestamp
        self.contentJSON = contentJSON
        self.encryptionInfo = encryptionInfo
    }
}

public nonisolated enum MatrixRTCDelayedEventAction: Sendable {
    case cancel, restart
}

/// How the host reports a failed operation. The core classifies failures itself, from the
/// homeserver's `errcode` and status, so report those whenever the client has them rather than
/// deciding what they mean.
public nonisolated enum MatrixRTCTransportError: Error, Sendable, Equatable {
    /// The client has no way to do this at all, such as a send its SDK has no binding for.
    case notSupported(String)
    /// The operation failed; `errcode` and `httpStatus` are the homeserver's, when it answered.
    case failed(String, errcode: String? = nil, httpStatus: UInt16? = nil)
}

/// The Matrix side the core needs, implemented by the host with its SDK proxies. This package never
/// imports the Matrix SDK, so this and ``ElementCallMatrixRoomProtocol`` are the whole contract
/// between the two.
public nonisolated protocol ElementCallMatrixTransportProtocol: AnyObject, Sendable {
    var userID: String { get }
    var deviceID: String { get }
    
    /// Opens a room for a call. The room stays open, and whatever the host holds for it stays alive,
    /// until ``ElementCallMatrixRoomProtocol/close()``: the core still sends through it while it
    /// leaves.
    func openRoom(roomID: String) async throws -> any ElementCallMatrixRoomProtocol
    
    /// Must be encrypted. `messages` is user ID → device ID → content JSON.
    /// - Returns: the recipients that were **not** served, user ID → device IDs.
    func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async throws -> [String: [String]]
    /// Every to-device message of the given types for as long as the stream is iterated.
    func toDeviceMessages(eventTypes: [String]) -> AsyncStream<MatrixRTCToDeviceMessage>
    
    func requestOpenIDToken() async throws -> MatrixRTCOpenIDToken
}

/// One room, open for as long as a call needs it.
///
/// Every set-shaped feed (``isEncrypted()``, ``joinedMemberIDs()``, ``stickyEvents()``,
/// ``stateEvents(eventType:)``) delivers the room's current value first, then the whole value again on
/// every change. An empty set means there is none. The core waits for a first delivery of each before
/// the room is ready, so a feed that holds back an empty set stalls the call before it joins.
public nonisolated protocol ElementCallMatrixRoomProtocol: AnyObject, Sendable {
    var roomID: String { get }
    
    // MARK: Feeds
    
    /// Whether the room is encrypted. Delivers nothing until the client knows; never a guess.
    func isEncrypted() -> AsyncStream<Bool>
    /// The user IDs joined to the room, ourselves included. A set without our own user is ignored by
    /// the core, which then never treats the room as ready.
    func joinedMemberIDs() -> AsyncStream<[String]>
    /// The room's current MSC4354 sticky events.
    func stickyEvents() -> AsyncStream<[ElementCallRoomEvent]>
    /// The room's current state events of exactly this type, one per state key, departures (`{}`)
    /// included.
    func stateEvents(eventType: String) -> AsyncStream<[ElementCallRoomEvent]>
    /// Message-like events of these types as they arrive, in batches rather than sets.
    func timelineEvents(eventTypes: [String]) -> AsyncStream<[ElementCallRoomEvent]>
    /// The ID of every event redacted from now on.
    func redactions() -> AsyncStream<String>
    /// The events relating to `eventID` by `relType`, of `eventType`, decrypted.
    func relations(eventID: String, relType: String, eventType: String) async throws -> [ElementCallRoomEvent]
    
    /// The homeserver's RTC transports, as the JSON array of the MSC4143 `rtc_transports` field,
    /// passed on verbatim; `[]` when it advertises none.
    ///
    /// Homeserver-wide, not room-scoped, and asked here only because a host may need a room to route
    /// the request: the SDK's widget driver serves it per room, as MSC4515. A host with a direct
    /// route answers the same from every room.
    func rtcTransports() async throws -> String
    
    // MARK: Sends (the core decides *what*, these decide *how*)
    
    /// - Returns: the event ID.
    func sendStateEvent(eventType: String, stateKey: String, contentJSON: String) async throws -> String
    /// - Returns: the event ID, or an empty string when the client does not report one.
    func sendStickyEvent(eventType: String, contentJSON: String, durationMs: UInt64) async throws -> String
    /// A delayed state event when `stateKey` is set, a delayed message-like event otherwise.
    /// - Returns: the MSC4140 delay ID.
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async throws -> String
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async throws
    /// - Returns: the event ID.
    func sendRoomEvent(eventType: String, contentJSON: String) async throws -> String
    func redactEvent(eventID: String, reason: String?) async throws
    
    /// Releases whatever the host holds for the room. Called once the core has left and stopped
    /// subscribing.
    func close() async
}
