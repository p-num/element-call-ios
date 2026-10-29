//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
@testable import ElementCallMatrix
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RoomBridgeOwnershipTests {
    private let roomID = "!room:example.org"
    
    @Test(arguments: [true, false])
    func aCancelledOpenCannotCloseItsReplacement(oldCompletesFirst: Bool) async throws {
        let relay = ToDeviceRelay()
        let store = ElementCallRoomBridgeStore(relay: relay)
        let bridge = HeldRoomBridge(roomID: roomID)
        let spare = HeldRoomBridge(roomID: roomID, result: .success(()))
        var creations = 0
        let makeBridge = {
            creations += 1
            return creations == 1 ? bridge : spare
        }
        let oldCompletion = BridgeOpenGate()
        let replacementCompletion = BridgeOpenGate()
        let oldOpen = Task {
            let lease = try await store.open(roomID: roomID, makeBridge: makeBridge)
            await oldCompletion.wait()
            return lease
        }
        try await waitUntil { await bridge.isStarting }
        oldOpen.cancel()
        var replacementStarted = false
        let replacementOpen = Task {
            replacementStarted = true
            let lease = try await store.open(roomID: roomID, makeBridge: makeBridge)
            await replacementCompletion.wait()
            return lease
        }
        try await waitUntil { replacementStarted }
        #expect(creations == 1)
        #expect(store.readyBridges.isEmpty)
        await bridge.completeStart(.success(()))
        
        let replacement: ElementCallRoomBridgeLease
        if oldCompletesFirst {
            await oldCompletion.release()
            let old = try await oldOpen.value
            await store.close(old)
            #expect(await bridge.stopCount == 0)
            await replacementCompletion.release()
            replacement = try await replacementOpen.value
        } else {
            await replacementCompletion.release()
            replacement = try await replacementOpen.value
            await oldCompletion.release()
            try await store.close(oldOpen.value)
        }
        #expect(replacement.bridge === bridge)
        #expect(store.readyBridges.count == 1)
        #expect(store.readyBridges.first === bridge)
        #expect(await bridge.startCount == 1)
        #expect(await bridge.stopCount == 0)
        
        let message = MatrixRTCToDeviceMessage(eventType: "keys", attestedSenderID: "@peer:example.org", senderDeviceID: "DEVICE",
                                               isSenderCrossSigned: nil, wasEncrypted: true, contentJSON: "{}")
        let received = deferFulfillment(relay.subscribe(eventTypes: [message.eventType]), timeout: .seconds(5)) { $0.contentJSON == message.contentJSON }
        await bridge.emit(message)
        #expect(try await received.fulfill().eventType == message.eventType)
        await store.close(replacement)
        #expect(await bridge.stopCount == 1)
        #expect(store.readyBridges.isEmpty)
    }
    
    @Test
    func anOldLeaseCannotCloseANewBridgeInTheSameRoom() async throws {
        let store = ElementCallRoomBridgeStore(relay: ToDeviceRelay())
        let first = HeldRoomBridge(roomID: roomID, result: .success(()))
        let old = try await store.open(roomID: roomID) { first }
        await store.close(old)
        #expect(await first.stopCount == 1)
        
        let second = HeldRoomBridge(roomID: roomID)
        let opening = Task { try await store.open(roomID: roomID) { second } }
        try await waitUntil { await second.isStarting }
        await store.close(old)
        #expect(await second.stopCount == 0)
        await second.completeStart(.success(()))
        let current = try await opening.value
        await store.close(old)
        #expect(store.readyBridges.first === second)
        #expect(await second.stopCount == 0)
        await store.close(current)
        #expect(await second.stopCount == 1)
    }
    
    @Test
    func aFailedSharedStartReleasesItsOwnersAndAllowsRetry() async throws {
        let store = ElementCallRoomBridgeStore(relay: ToDeviceRelay())
        let bridge = HeldRoomBridge(roomID: roomID)
        var creations = 0
        let makeBridge = {
            creations += 1
            return bridge
        }
        let first = Task { try await store.open(roomID: roomID, makeBridge: makeBridge) }
        try await waitUntil { await bridge.isStarting }
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return try await store.open(roomID: roomID, makeBridge: makeBridge)
        }
        try await waitUntil { secondStarted }
        #expect(creations == 1)
        await bridge.completeStart(.failure(.timedOut))
        await #expect(throws: MatrixRTCTransportError.self) { try await first.value }
        await #expect(throws: MatrixRTCTransportError.self) { try await second.value }
        #expect(await bridge.stopCount == 1)
        #expect(store.readyBridges.isEmpty)
        
        let retryBridge = HeldRoomBridge(roomID: roomID, result: .success(()))
        let retry = try await store.open(roomID: roomID) { retryBridge }
        #expect(store.readyBridges.first === retryBridge)
        await store.close(retry)
        #expect(await retryBridge.stopCount == 1)
    }
    
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() {
                return
            }
            await Task.yield()
        }
        throw FakeRtcCall.RefusedError()
    }
}

private actor BridgeOpenGate {
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?
    
    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    
    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}

private actor HeldRoomBridge: MatrixRTCRoomBridgeProtocol {
    nonisolated let roomID: String
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var result: Result<Void, MatrixRTCRoomBridgeError>?
    private var startWaiters: [CheckedContinuation<Result<Void, MatrixRTCRoomBridgeError>, Never>] = []
    private nonisolated let messages: AsyncStream<MatrixRTCToDeviceMessage>
    private let messageContinuation: AsyncStream<MatrixRTCToDeviceMessage>.Continuation
    
    init(roomID: String, result: Result<Void, MatrixRTCRoomBridgeError>? = nil) {
        self.roomID = roomID
        self.result = result
        (messages, messageContinuation) = AsyncStream.makeStream()
    }
    
    var isStarting: Bool {
        !startWaiters.isEmpty
    }
    
    func start() async -> Result<Void, MatrixRTCRoomBridgeError> {
        startCount += 1
        if let result {
            return result
        }
        return await withCheckedContinuation { startWaiters.append($0) }
    }
    
    func completeStart(_ result: Result<Void, MatrixRTCRoomBridgeError>) {
        self.result = result
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
    
    func stop() async {
        stopCount += 1
        messageContinuation.finish()
    }
    
    func emit(_ message: MatrixRTCToDeviceMessage) {
        messageContinuation.yield(message)
    }
    
    func sendDelayedEvent(eventType: String, stateKey: String?, contentJSON: String, delayMs: UInt64) async -> Result<String, MatrixRTCRoomBridgeError> {
        .failure(.notRunning)
    }
    
    func updateDelayedEvent(delayID: String, action: MatrixRTCDelayedEventAction) async -> Result<Void, MatrixRTCRoomBridgeError> {
        .failure(.notRunning)
    }
    
    func sendRoomEvent(eventType: String, contentJSON: String) async -> Result<String, MatrixRTCRoomBridgeError> {
        .failure(.notRunning)
    }
    
    func rtcTransports() async -> Result<String, MatrixRTCRoomBridgeError> {
        .failure(.notRunning)
    }
    
    func sendToDeviceMessage(eventType: String, messages: [String: [String: String]]) async -> Result<[String: [String]], MatrixRTCRoomBridgeError> {
        .failure(.notRunning)
    }
    
    nonisolated func stateEvents(eventType: String) -> AsyncStream<[ElementCallRoomEvent]> {
        AsyncStream { $0.finish() }
    }
    
    nonisolated func timelineEvents(eventTypes: [String]) -> AsyncStream<[ElementCallRoomEvent]> {
        AsyncStream { $0.finish() }
    }
    
    nonisolated func redactions() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
    
    nonisolated func toDeviceMessages() -> AsyncStream<MatrixRTCToDeviceMessage> {
        messages
    }
}
