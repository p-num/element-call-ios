//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import Foundation
import MatrixRustSDK

/// The room's slot state, read from the homeserver rather than the SDK's store: the store only holds
/// sliding sync's `required_state`, which has no slot type, so it reads every room as slotless and the
/// sticky formats could never join. As the core's own SDK backend does (`matrix-rtc-matrix-sdk`
/// `state_snapshot`). Read again whenever the room's sticky set changes, which is when a slot that
/// opened since matters; a failed read is retried and never delivered as "no slots".
final nonisolated class SDKSlotFeed: Sendable {
    /// The `m.rtc.slot` spellings, which the core asks for as state.
    static let eventTypes: Set = ["m.rtc.slot", "org.matrix.msc4143.rtc.slot"]
    private static let retryAfter = Duration.seconds(5)
    
    let handle: TaskHandle
    
    private let client: Client
    private let roomID: String
    private let eventTypes: [String]
    private let logger: (any ElementCallLoggingProtocol)?
    private let wakes: AsyncStream<Void>
    
    init(client: Client, room: Room, eventTypes: [String], logger: (any ElementCallLoggingProtocol)?) {
        self.client = client
        roomID = room.id()
        self.eventTypes = eventTypes
        self.logger = logger
        let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.wakes = wakes
        handle = room.subscribeToStickyEvents(listener: SDKStickyWakeListener { wake.yield() })
    }
    
    func deliver(into sink: ElementCallRoomSink) async {
        await readUntilRead(into: sink)
        for await _ in wakes {
            await readUntilRead(into: sink)
        }
    }
    
    private func readUntilRead(into sink: ElementCallRoomSink) async {
        while !Task.isCancelled {
            do {
                let events = try await readState()
                for eventType in eventTypes {
                    sink.deliverStateEvents(events.filter { $0.eventType == eventType }, ofType: eventType)
                }
                return
            } catch {
                logger?.log(.warning, "could not read the slot state of \(roomID): \(error)")
                try? await Task.sleep(for: Self.retryAfter)
            }
        }
    }
    
    private func readState() async throws -> [ElementCallMatrixEvent] {
        let session = try client.session()
        guard let url = URL(string: session.homeserverUrl)?.appending(path: "_matrix/client/v3/rooms/\(roomID)/state") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let events = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw URLError(.badServerResponse)
        }
        return events.compactMap(Self.event).filter { eventTypes.contains($0.eventType) }
    }
    
    private static func event(_ object: [String: Any]) -> ElementCallMatrixEvent? {
        guard let eventID = object["event_id"] as? String,
              let sender = object["sender"] as? String,
              let eventType = object["type"] as? String,
              let timestamp = (object["origin_server_ts"] as? NSNumber)?.uint64Value,
              let content = object["content"] as? [String: Any],
              let contentData = try? JSONSerialization.data(withJSONObject: content),
              let contentJSON = String(data: contentData, encoding: .utf8) else {
            return nil
        }
        return ElementCallMatrixEvent(eventID: eventID,
                                      sender: sender,
                                      eventType: eventType,
                                      stateKey: object["state_key"] as? String,
                                      originServerTimestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
                                      contentJSON: contentJSON,
                                      encryption: .cleartext)
    }
}

/// Only says that the room's sticky set changed.
private final nonisolated class SDKStickyWakeListener: StickyEventsListener {
    private let onChange: @Sendable () -> Void
    
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }
    
    func onUpdate(update: StickyEventsUpdate) {
        onChange()
    }
}
