//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

/// Everything the call needs from the host's Matrix client. Implement it once per session, over the
/// host's own client; the core subscribes, orders and parses. `SDKMatrixBackend` in the example app
/// is the reference over the Rust SDK.
///
/// Ours rather than the core's `MatrixBackend`, which it is adapted to: the bindings are generated
/// from Rust, so they spell `roomId`, `contentJson` and `delayMs`, and a host conforming to them
/// directly has to repeat those names in its own code.
///
/// Sends take the event type already in its wire spelling: send it verbatim. Every send returns the
/// homeserver's event ID, or for a delayed send the MSC4140 delay ID.
public nonisolated protocol ElementCallMatrixBackendProtocol: AnyObject, Sendable {
    /// The account the client is logged in as.
    var userID: String { get }
    /// The device the client is logged in as.
    var deviceID: String { get }
    
    /// `duration` is how long the homeserver keeps the sticky entry; pass it through verbatim. The core
    /// re-sends before it elapses.
    func sendStickyEvent(roomID: String, eventType: String, contentJSON: String, duration: Duration) async throws(ElementCallMatrixBackendError) -> String
    
    /// The room-state format's dead man's switch. A homeserver that refuses delayed events
    /// (`M_UNRECOGNIZED`, or matrix.org's `M_FORBIDDEN`) does not fail the join: report its error
    /// code and the core stops asking.
    func sendDelayedStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String, delay: Duration) async throws(ElementCallMatrixBackendError) -> String
    
    /// The sticky formats' dead man's switch (MSC4140 and MSC4354), kept `stickyDuration` once it
    /// fires. A client that cannot send one answers `M_UNRECOGNIZED`; never send a plain delayed event
    /// instead, which fires without ending the membership.
    func sendDelayedStickyEvent(roomID: String, eventType: String, contentJSON: String, stickyDuration: Duration, delay: Duration) async throws(ElementCallMatrixBackendError) -> String
    
    /// MSC4140's restart action. Never emulate it with cancel-and-resend.
    func restartDelayedEvent(roomID: String, delayID: String) async throws(ElementCallMatrixBackendError)
    
    func cancelDelayedEvent(roomID: String, delayID: String) async throws(ElementCallMatrixBackendError)
    
    /// Olm-encrypted, to exactly these devices. Returns the ones it could not reach, with why: every
    /// other recipient counts as delivered and is never sent to again, so a failure reported as a
    /// success leaves that member without our media key.
    func sendToDeviceMessage(eventType: String, contentJSON: String, to recipients: [ElementCallDevice]) async throws(ElementCallMatrixBackendError) -> [ElementCallDevice: String]
    
    func sendStateEvent(roomID: String, eventType: String, stateKey: String, contentJSON: String) async throws(ElementCallMatrixBackendError) -> String
    
    /// A plain message-like send, encrypted by the client in an encrypted room.
    func sendRoomEvent(roomID: String, eventType: String, contentJSON: String) async throws(ElementCallMatrixBackendError) -> String
    
    func redactEvent(roomID: String, eventID: String, reason: String?) async throws(ElementCallMatrixBackendError)
    
    /// Delivers `subjects` for the room into `sink`: the current sets first, an empty one included,
    /// then every change, until the subscription is cancelled. The core treats a room as ready only
    /// once each subject has delivered once.
    ///
    /// Synchronous: register the client's listeners and return, delivering from the host's own tasks.
    /// The bindings cannot hand an object back from an asynchronous foreign method.
    func subscribeToRoom(roomID: String, subjects: ElementCallRoomSubjects, sink: ElementCallRoomSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription
    
    /// Delivers every decrypted to-device message of `eventTypes` into `sink` until the subscription
    /// is cancelled. Synchronous, as ``subscribeToRoom(roomID:subjects:sink:)``.
    func subscribeToDeviceMessages(eventTypes: [String], sink: ElementCallToDeviceSink) throws(ElementCallMatrixBackendError) -> ElementCallBackendSubscription
    
    /// `GET /rooms/{roomID}/relations/{eventID}/{relationshipType}/{eventType}`, decrypted. A backend
    /// that cannot serve them answers empty rather than failing.
    func relations(roomID: String, eventID: String, relationshipType: String, eventType: String) async throws(ElementCallMatrixBackendError) -> [ElementCallMatrixEvent]
    
    /// A fresh OpenID token for the account.
    func openIDToken() async throws(ElementCallMatrixBackendError) -> ElementCallOpenIDToken
    
    /// The homeserver's MSC4195 LiveKit token: `POST` the request to its `get_token` endpoint and
    /// return the `jwt` of the answer. Asked only for a transport naming an SFU `url` without a
    /// `livekit_service_url`. A client that cannot make the request answers `M_UNRECOGNIZED` with
    /// status 404, as a homeserver without the endpoint would.
    func liveKitToken(for request: ElementCallLiveKitTokenRequest) async throws(ElementCallMatrixBackendError) -> String
    
    /// The `rtc_transports` array of `GET /_matrix/client/v1/rtc/transports`, as JSON; `[]` when the
    /// homeserver lacks the endpoint.
    func rtcTransportsJSON() async throws(ElementCallMatrixBackendError) -> String
}

/// A failure of the host's Matrix client. Pass the homeserver's error on; never classify it: the core
/// decides from `errorCode` and `statusCode` what is retried and which refusals retire a feature for
/// the session.
public nonisolated struct ElementCallMatrixBackendError: Error, Sendable, Equatable {
    /// The Matrix `errcode`, such as `M_LIMIT_EXCEEDED`.
    public var errorCode: String?
    /// The HTTP status, when the client has it.
    public var statusCode: Int?
    /// The homeserver's rate-limit `retry_after_ms`, which the core waits for instead of its own backoff.
    public var retryAfter: Duration?
    /// Only for a failure the client knows is final and no Matrix code describes, such as a room it is
    /// not in. A permanent failure is never retried, so setting it on a transient one loses that send.
    public var isPermanent: Bool
    public var reason: String
    
    public init(errorCode: String? = nil, statusCode: Int? = nil, retryAfter: Duration? = nil, isPermanent: Bool = false, reason: String) {
        self.errorCode = errorCode
        self.statusCode = statusCode
        self.retryAfter = retryAfter
        self.isPermanent = isPermanent
        self.reason = reason
    }
}

/// A room event as the client handed it over. The core parses the content; the host does not.
public nonisolated struct ElementCallMatrixEvent: Sendable, Equatable {
    public var eventID: String
    public var sender: String
    public var eventType: String
    /// Set for state events.
    public var stateKey: String?
    public var originServerTimestamp: Date
    /// The whole decrypted `content` object, as JSON.
    public var contentJSON: String
    public var encryption: ElementCallEventEncryption
    
    public init(eventID: String,
                sender: String,
                eventType: String,
                stateKey: String? = nil,
                originServerTimestamp: Date,
                contentJSON: String,
                encryption: ElementCallEventEncryption) {
        self.eventID = eventID
        self.sender = sender
        self.eventType = eventType
        self.stateKey = stateKey
        self.originServerTimestamp = originServerTimestamp
        self.contentJSON = contentJSON
        self.encryption = encryption
    }
}

/// A decrypted to-device message as the client handed it over.
public nonisolated struct ElementCallToDeviceMessage: Sendable, Equatable {
    /// For an encrypted message, the sender the encryption attests to, not the claimed one.
    public var sender: String
    public var eventType: String
    public var contentJSON: String
    public var encryption: ElementCallEventEncryption
    
    public init(sender: String, eventType: String, contentJSON: String, encryption: ElementCallEventEncryption) {
        self.sender = sender
        self.eventType = eventType
        self.contentJSON = contentJSON
        self.encryption = encryption
    }
}

/// How the client says an event arrived. Report only what the client says: a confirmation it cannot
/// give stays `nil`.
public nonisolated enum ElementCallEventEncryption: Sendable, Equatable {
    case cleartext
    /// `isSenderConfirmed` is whether the client vouches for the sender under its own trust settings.
    case encrypted(senderDeviceID: String?, isSenderConfirmed: Bool?)
}

/// One device a to-device message is addressed to.
public nonisolated struct ElementCallDevice: Sendable, Hashable {
    public var userID: String
    public var deviceID: String
    
    public init(userID: String, deviceID: String) {
        self.userID = userID
        self.deviceID = deviceID
    }
}

/// What the core wants delivered for one room.
public nonisolated struct ElementCallRoomSubjects: Sendable, Equatable {
    /// Stable and unstable spellings both listed; deliver each under its own type.
    public var stateEventTypes: [String]
    /// Message-like types to forward as they arrive, redactions included.
    public var timelineEventTypes: [String]
    
    public init(stateEventTypes: [String], timelineEventTypes: [String]) {
        self.stateEventTypes = stateEventTypes
        self.timelineEventTypes = timelineEventTypes
    }
}

/// A Matrix OpenID token, as `POST /_matrix/client/v3/user/{userId}/openid/request_token` returns it.
public nonisolated struct ElementCallOpenIDToken: Sendable, Equatable {
    public var accessToken: String
    public var tokenType: String
    public var matrixServerName: String
    public var expiresIn: Duration
    
    public init(accessToken: String, tokenType: String, matrixServerName: String, expiresIn: Duration) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.matrixServerName = matrixServerName
        self.expiresIn = expiresIn
    }
}

/// The body of an MSC4195 `get_token` request, field for field.
public nonisolated struct ElementCallLiveKitTokenRequest: Sendable, Equatable {
    /// The SFU's homeserver; nil for the account's own, in which case the field is omitted.
    public var serverName: String?
    /// The SFU's WebSocket URL.
    public var url: String
    public var roomID: String
    public var slotID: String
    public var memberID: String
    
    public init(serverName: String?, url: String, roomID: String, slotID: String, memberID: String) {
        self.serverName = serverName
        self.url = url
        self.roomID = roomID
        self.slotID = slotID
        self.memberID = memberID
    }
}

/// What the core calls to end a subscription. Cancelling twice is a no-op.
public final nonisolated class ElementCallBackendSubscription: Sendable {
    private let onCancel: @Sendable () -> Void
    private let isCancelled = Mutex(false)
    
    public init(onCancel: @escaping @Sendable () -> Void = { }) {
        self.onCancel = onCancel
    }
    
    public func cancel() {
        let wasCancelled = isCancelled.withLock { isCancelled in
            defer { isCancelled = true }
            return isCancelled
        }
        guard !wasCancelled else { return }
        onCancel()
    }
}
