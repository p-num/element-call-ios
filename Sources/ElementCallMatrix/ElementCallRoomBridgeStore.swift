//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// One room wrapper's ownership of a bridge. Concurrent opens share the bridge, not their lifetime.
nonisolated struct ElementCallRoomBridgeLease: Sendable {
    let roomID: String
    let bridge: any MatrixRTCRoomBridgeProtocol
    fileprivate let id = UUID()
}

/// Keeps pending starts and their message relay together until every room wrapper has closed.
@MainActor
final class ElementCallRoomBridgeStore {
    private struct LiveBridge {
        let bridge: any MatrixRTCRoomBridgeProtocol
        let start: Task<Result<Void, MatrixRTCRoomBridgeError>, Never>
        let toDeviceForwarder: Task<Void, Never>
        var leases: Set<UUID>
        var isReady = false
    }
    
    private let relay: ToDeviceRelay
    private var liveBridges = [String: LiveBridge]()
    
    init(relay: ToDeviceRelay) {
        self.relay = relay
    }
    
    var readyBridges: [any MatrixRTCRoomBridgeProtocol] {
        liveBridges.values.filter(\.isReady).map(\.bridge)
    }
    
    func open(roomID: String, makeBridge: () throws -> any MatrixRTCRoomBridgeProtocol) async throws -> ElementCallRoomBridgeLease {
        var live: LiveBridge
        if let existing = liveBridges[roomID] {
            live = existing
        } else {
            let bridge = try makeBridge()
            // Subscribe before starting the driver so its first keys cannot precede the relay.
            let messages = bridge.toDeviceMessages()
            let forwarder = Task { [relay] in
                for await message in messages {
                    relay.publish(message)
                }
            }
            live = LiveBridge(bridge: bridge, start: Task { await bridge.start() },
                              toDeviceForwarder: forwarder, leases: [])
        }
        let lease = ElementCallRoomBridgeLease(roomID: roomID, bridge: live.bridge)
        live.leases.insert(lease.id)
        // Claim ownership before awaiting negotiation: a second open joins this same start.
        liveBridges[roomID] = live
        
        switch await live.start.value {
        case .success:
            liveBridges[roomID]?.isReady = true
            return lease
        case .failure(let error):
            await close(lease)
            throw error.transportError
        }
    }
    
    func close(_ lease: ElementCallRoomBridgeLease) async {
        guard var live = liveBridges[lease.roomID], live.leases.remove(lease.id) != nil else { return }
        guard live.leases.isEmpty else {
            liveBridges[lease.roomID] = live
            return
        }
        // Release the cache before awaiting stop. A new bridge can now open in this room, and a
        // repeated old close cannot remove it because that bridge does not hold this lease.
        liveBridges.removeValue(forKey: lease.roomID)
        live.toDeviceForwarder.cancel()
        await live.bridge.stop()
    }
}
