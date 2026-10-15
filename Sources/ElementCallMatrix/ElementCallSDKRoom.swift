//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation
import MatrixRustSDK

/// One room of ``ElementCallSDKTransport``, open for a call: the SDK where its bindings reach, the
/// room's bridge where they do not. Closing it closes the bridge.
final nonisolated class ElementCallSDKRoom: ElementCallMatrixRoomProtocol {
    let roomID: String
    
    private let transport: ElementCallSDKTransport
    private let bridge: any MatrixRTCRoomBridgeProtocol
    private let logger: (any ElementCallLoggingProtocol)?
    
    init(roomID: String, transport: ElementCallSDKTransport, bridge: any MatrixRTCRoomBridgeProtocol, logger: (any ElementCallLoggingProtocol)?) {
        self.roomID = roomID
        self.transport = transport
        self.bridge = bridge
        self.logger = logger
    }
    
    func close() async {
        await transport.closeBridge(roomID: roomID)
    }
    
    // MARK: - Feeds
    
    /// Asked of the homeserver when the store does not know yet, and never answered with a guess:
    /// an unknown state delivers nothing, which keeps the call from joining rather than letting it
    /// join an encrypted room believing it is not.
    func isEncrypted() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task { @MainActor [transport, roomID, logger] in
                guard let room = try? transport.room(roomID) else {
                    continuation.finish()
                    return
                }
                let state: EncryptionState
                do {
                    state = try await room.latestEncryptionState()
                } catch {
                    logger?.log(.warning, "could not fetch the encryption state of \(roomID): \(error)")
                    state = room.encryptionState()
                }
                switch state {
                case .encrypted: continuation.yield(true)
                case .notEncrypted: continuation.yield(false)
                case .unknown: logger?.log(.error, "the encryption state of \(roomID) is unknown, the call cannot join")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    /// Re-read on every room info update rather than subscribed directly: the SDK exposes members as
    /// a snapshot iterator, and room info is what changes when someone joins or leaves.
    func joinedMemberIDs() -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let task = Task { @MainActor [transport, roomID] in
                guard let room = try? transport.room(roomID) else {
                    continuation.finish()
                    return
                }
                
                let updates = AsyncStream<Void> { infoContinuation in
                    let handle = room.subscribeToRoomInfoUpdates(listener: RoomInfoRelay { infoContinuation.yield(()) })
                    infoContinuation.onTermination = { _ in handle.cancel() }
                }
                
                // Room info fires on any state change in the room, most of which leave membership
                // alone, so the list is only forwarded when it actually differs.
                var lastEmitted: [String]?
                func emitIfChanged() async {
                    guard let members = await Self.joinedMembers(of: room)?.sorted(),
                          Self.shouldEmit(members, lastEmitted: lastEmitted) else { return }
                    lastEmitted = members
                    continuation.yield(members)
                }
                
                await emitIfChanged()
                for await _ in updates {
                    await emitIfChanged()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    
    /// Whether a freshly read membership is worth forwarding.
    ///
    /// Compared as a sorted list so the question is membership rather than whatever order the store
    /// happened to return. Deliberately **not** compared by count: one person leaving as another
    /// joins keeps the count identical while the membership differs, and the core would carry on
    /// encrypting media for whoever left.
    ///
    /// An empty list is never forwarded. It is never true either, since we are in the room: it is
    /// the store not having loaded the members yet, and the core would ignore a set without us.
    nonisolated static func shouldEmit(_ members: [String], lastEmitted: [String]?) -> Bool {
        !members.isEmpty && members != lastEmitted
    }
    
    /// A store read rather than a network call, but not a cached value either: three store queries
    /// and a deserialise per member. Cheap enough to do per update, which is why this is not
    /// throttled, but worth measuring if a very large room ever misbehaves.
    @MainActor
    private static func joinedMembers(of room: Room) async -> [String]? {
        guard let iterator = try? await room.membersNoSync() else { return nil }
        var joined = [String]()
        while let chunk = iterator.nextChunk(chunkSize: 100) {
            joined.append(contentsOf: chunk.filter { $0.membership == .join }.map(\.userId))
        }
        return joined
    }
    
    /// The released bindings have no sticky-event feed, so there are never any. Delivered rather
    /// than withheld, because the core waits for a first set before the room is ready; the
    /// room-state format, the only one this transport can join, reads membership from state.
    func stickyEvents() -> AsyncStream<[ElementCallRoomEvent]> {
        AsyncStream { continuation in
            continuation.yield([])
            continuation.finish()
        }
    }
    
    func stateEvents(eventType: String) -> AsyncStream<[ElementCallRoomEvent]> {
        bridge.stateEvents(eventType: eventType)
    }
    
    func timelineEvents(eventTypes: [String]) -> AsyncStream<[ElementCallRoomEvent]> {
        bridge.timelineEvents(eventTypes: eventTypes)
    }
    
    func redactions() -> AsyncStream<String> {
        bridge.redactions()
    }
    
    /// Neither path can answer yet: the SDK's relations come back as typed content, with no raw
    /// JSON and no encryption information, and the widget API has no relations request. A hand
    /// raised before we joined therefore shows only once it changes.
    func relations(eventID: String, relType: String, eventType: String) async throws -> [ElementCallRoomEvent] {
        throw MatrixRTCTransportError.notSupported("Relations are not available with the released SDK")
    }
    
    func rtcTransports() async throws -> String {
        try await bridge.rtcTransports().mapTransportError()
    }
    
    // MARK: - Sends
    
    func sendStateEvent(eventType: String, stateKey: String, contentJSON: String) async throws -> String {
        try await transport.onMain { [roomID] transport in
            try await transport.sdkCall("sendStateEventRaw(\(eventType))", in: roomID) { room in
                try await room.sendStateEventRaw(eventType: eventType, stateKey: stateKey, content: contentJSON)
            }
        }
    }
    
    /// Sticky events (MSC4354) need bindings the released SDK lacks, so only the room-state format
    /// can be joined, and that never sends one.
    func sendStickyEvent(eventType: String, contentJSON: String, durationMs: UInt64) async throws -> String {
        throw MatrixRTCTransportError.notSupported("Sticky events are not available with the released SDK")
    }
    
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async throws -> String {
        try await bridge.sendDelayedEvent(eventType: eventType, stateKey: stateKey, contentJSON: contentJSON, delayMs: delayMs).mapTransportError()
    }
    
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async throws {
        try await bridge.updateDelayedEvent(delayID: delayID, action: action).mapTransportError()
    }
    
    /// Through the bridge, which reports the event ID; the SDK's own `sendRaw` does not.
    func sendRoomEvent(eventType: String, contentJSON: String) async throws -> String {
        try await bridge.sendRoomEvent(eventType: eventType, contentJSON: contentJSON).mapTransportError()
    }
    
    func redactEvent(eventID: String, reason: String?) async throws {
        try await transport.onMain { [roomID] transport in
            try await transport.sdkCall("redact", in: roomID) { room in
                try await room.redact(eventId: eventID, reason: reason)
            }
        }
    }
}

/// Turns the SDK's listener callback into something a stream can await.
private final class RoomInfoRelay: RoomInfoListener {
    private let onUpdate: @Sendable () -> Void
    
    init(onUpdate: @escaping @Sendable () -> Void) {
        self.onUpdate = onUpdate
    }
    
    func call(roomInfo: RoomInfo) {
        onUpdate()
    }
}
