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

/// The Matrix side of a call, over the Rust SDK. A host builds one of these with its `Client` and
/// hands it to ``ElementCallStack``; there is nothing else for it to implement.
///
/// Main-actor bound, because the SDK's room and client objects are, and because the core awaits
/// every send. The feeds hop onto the main actor inside their streams.
///
/// What the released bindings do not expose yet, delayed events, the room-state and timeline feeds,
/// to-device messaging and room event IDs, goes through a per-room ``MatrixRTCRoomBridgeProtocol``,
/// opened with the room and closed with it. See `Widget/` for what retires that, and note that
/// MSC4515 transport discovery already came off the stopgap list.
@MainActor
public final class ElementCallSDKTransport: ElementCallMatrixTransportProtocol {
    public nonisolated let userID: String
    public nonisolated let deviceID: String
    
    private let client: Client
    private let logger: (any ElementCallLoggingProtocol)?
    private var liveBridges = [String: LiveBridge]()
    /// The core subscribes to to-device once; bridges come and go with calls.
    private nonisolated let toDeviceRelay = ToDeviceRelay()
    
    public init?(client: Client, logger: (any ElementCallLoggingProtocol)? = nil) {
        guard let userID = try? client.userId(), let deviceID = try? client.deviceId() else {
            logger?.log(.error, "no user or device ID, cannot serve a call")
            return nil
        }
        self.client = client
        self.logger = logger
        self.userID = userID
        self.deviceID = deviceID
    }
    
    // MARK: - Rooms
    
    public nonisolated func openRoom(roomID: String) async throws -> any ElementCallMatrixRoomProtocol {
        try await onMain { transport in
            let bridge = try await transport.openBridge(roomID: roomID)
            return ElementCallSDKRoom(roomID: roomID, transport: transport, bridge: bridge, logger: transport.logger)
        }
    }
    
    func closeBridge(roomID: String) async {
        let live = liveBridges.removeValue(forKey: roomID)
        live?.toDeviceForwarder.cancel()
        await live?.bridge.stop()
    }
    
    /// A bridge and the task pumping its to-device messages into the relay, kept together so they
    /// cannot exist apart.
    ///
    /// They were separate dictionaries once, and that cost an afternoon. A bridge used to be opened
    /// either when joining or, earlier, by transport discovery, and the version that only started the
    /// pump when joining skipped it whenever discovery had already opened one. Media keys then
    /// arrived at the bridge and reached nobody, so no participant's frames decrypted and every
    /// remote tile was black with `missingKey` in its stats. Audio survived because it is keyed the
    /// same way but far more forgiving of a late key.
    private struct LiveBridge {
        let bridge: any MatrixRTCRoomBridgeProtocol
        let toDeviceForwarder: Task<Void, Never>
    }
    
    /// The only place a bridge is created, so everything a bridge needs is wired in one spot.
    private func openBridge(roomID: String) async throws -> any MatrixRTCRoomBridgeProtocol {
        if let live = liveBridges[roomID] {
            return live.bridge
        }
        guard let bridge = try WidgetDriverFactory.makeBridge(room: room(roomID), roomID: roomID, logger: logger) else {
            throw MatrixRTCTransportError.failed("Cannot open a Matrix bridge for \(roomID)")
        }
        // Subscribed before the start, so nothing the driver hands over once it is running can
        // arrive ahead of the subscriber. A failed start closes the feed, which ends it.
        let toDeviceMessages = bridge.toDeviceMessages()
        if case .failure(let error) = await bridge.start() {
            throw error.transportError
        }
        
        let forwarder = Task { [relay = toDeviceRelay] in
            for await message in toDeviceMessages {
                relay.publish(message)
            }
        }
        liveBridges[roomID] = LiveBridge(bridge: bridge, toDeviceForwarder: forwarder)
        return bridge
    }
    
    // MARK: - Session-wide
    
    /// The core does not say which room the keys are for, and the bridge does not need it either: it
    /// encrypts whenever its room is encrypted. Only one call runs at a time.
    public nonisolated func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async throws -> [String: [String]] {
        let bridge = try await onMain { transport -> any MatrixRTCRoomBridgeProtocol in
            if transport.liveBridges.count > 1 {
                transport.logger?.log(.warning, "\(transport.liveBridges.count) live bridges, sending to-device through the first")
            }
            guard let bridge = transport.liveBridges.values.first?.bridge else {
                throw MatrixRTCTransportError.failed("No live call to send to-device messages through")
            }
            return bridge
        }
        return try await bridge.sendToDeviceMessage(eventType: eventType, messages: messages).mapTransportError()
    }
    
    public nonisolated func toDeviceMessages(eventTypes: [String]) -> AsyncStream<MatrixRTCToDeviceMessage> {
        toDeviceRelay.subscribe(eventTypes: eventTypes)
    }
    
    public nonisolated func requestOpenIDToken() async throws -> MatrixRTCOpenIDToken {
        let token = try await onMain { transport -> OpenIdToken in
            do {
                return try await transport.client.requestOpenidToken()
            } catch {
                throw error.transportError
            }
        }
        return MatrixRTCOpenIDToken(accessToken: token.accessToken,
                                    tokenType: token.tokenType,
                                    matrixServerName: token.matrixServerName,
                                    expiresIn: TimeInterval(token.expiresInSeconds))
    }
    
    // MARK: - For the rooms
    
    func room(_ roomID: String) throws -> Room {
        guard let room = try? client.getRoom(roomId: roomID) else {
            throw MatrixRTCTransportError.failed("Not joined to \(roomID)")
        }
        return room
    }
    
    /// Logs an SDK failure and passes on what the homeserver said. The message never includes event
    /// content.
    func sdkCall<T>(_ description: String, in roomID: String, _ body: (Room) async throws -> T) async throws -> T {
        do {
            return try await body(room(roomID))
        } catch let error as MatrixRTCTransportError {
            throw error
        } catch {
            logger?.log(.error, "\(description) failed in \(roomID): \(error)")
            throw error.transportError
        }
    }
    
    nonisolated func onMain<T: Sendable>(_ body: @escaping @MainActor (ElementCallSDKTransport) async throws -> T) async throws -> T {
        try await Task { @MainActor in try await body(self) }.value
    }
}
