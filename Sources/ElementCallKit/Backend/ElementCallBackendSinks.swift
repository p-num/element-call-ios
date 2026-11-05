//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc

/// Where the host delivers a room's subjects. Every call returns at once and may come from any thread.
///
/// Sticky events, state events and joined members are each delivered as the room's **complete
/// current set** for that subject, never as a change; an empty set means none.
public final nonisolated class ElementCallRoomSink: Sendable {
    private let sink: any RoomSinkProtocol
    
    init(_ sink: any RoomSinkProtocol) {
        self.sink = sink
    }
    
    public func deliverStickyEvents(_ events: [ElementCallMatrixEvent]) {
        sink.onStickyEvents(events: events.map(\.ffi))
    }
    
    /// Under the type the core subscribed to, whatever spelling the event itself carries.
    public func deliverStateEvents(_ events: [ElementCallMatrixEvent], ofType eventType: String) {
        sink.onStateEvents(eventType: eventType, events: events.map(\.ffi))
    }
    
    /// Never empty: we are in the room, so an empty read is the store not having loaded the members
    /// yet, and the core ignores a set without us.
    public func deliverJoinedMembers(_ userIDs: [String]) {
        sink.onJoinedMembers(userIds: userIDs)
    }
    
    /// Never a guess: the core treats cleartext membership as valid in an unencrypted room, so deliver
    /// nothing until the client knows.
    public func deliverEncryption(isEncrypted: Bool) {
        sink.onEncryption(encrypted: isEncrypted)
    }
    
    public func deliverTimelineEvents(_ events: [ElementCallMatrixEvent]) {
        sink.onTimelineEvents(events: events.map(\.ffi))
    }
    
    public func deliverRedaction(ofEventID eventID: String) {
        sink.onRedaction(eventId: eventID)
    }
}

/// Where the host delivers to-device messages of the subscribed types.
public final nonisolated class ElementCallToDeviceSink: Sendable {
    private let sink: any ToDeviceSinkProtocol
    
    init(_ sink: any ToDeviceSinkProtocol) {
        self.sink = sink
    }
    
    public func deliver(_ message: ElementCallToDeviceMessage) {
        sink.onToDeviceMessage(message: FfiToDeviceMessageIn(sender: message.sender,
                                                             eventType: message.eventType,
                                                             contentJson: message.contentJSON,
                                                             encryption: message.encryption.ffi))
    }
}

// MARK: - Bindings

nonisolated extension ElementCallMatrixEvent {
    var ffi: FfiEventIn {
        FfiEventIn(eventId: eventID,
                   sender: sender,
                   eventType: eventType,
                   stateKey: stateKey,
                   originServerTs: originServerTimestamp.millisecondsSince1970,
                   contentJson: contentJSON,
                   encryption: encryption.ffi)
    }
}

nonisolated extension ElementCallEventEncryption {
    var ffi: FfiEventEncryption {
        switch self {
        case .cleartext:
            FfiEventEncryption(encrypted: false, senderDeviceId: nil, senderConfirmed: nil)
        case .encrypted(let senderDeviceID, let isSenderConfirmed):
            FfiEventEncryption(encrypted: true, senderDeviceId: senderDeviceID, senderConfirmed: isSenderConfirmed)
        }
    }
}

nonisolated extension Date {
    /// Clamped at the epoch: the bindings take an unsigned count.
    var millisecondsSince1970: UInt64 {
        UInt64(max(0, (timeIntervalSince1970 * 1000).rounded()))
    }
}

nonisolated extension Duration {
    /// Clamped at zero, as above.
    var inMilliseconds: UInt64 {
        let (seconds, attoseconds) = components
        return UInt64(max(0, seconds * 1000 + attoseconds / 1_000_000_000_000_000))
    }
}
