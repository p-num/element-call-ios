//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCallHost
import ElementCallKit
import Foundation
import Testing

/// A real controller over the real core, starting calls in rooms that never open: what a host's unit
/// tests get from `ElementCallFakeMatrixBackend`, and the one place a hang-up can land while the
/// join is still waiting for its room.
///
/// Every test hangs up what it started and waits for the join to unwind. A call left joining fails
/// when the core stops waiting for its room, 30 seconds on, in whichever test is running by then.
@Suite("Hanging up while joining")
@MainActor
struct HangUpWhileJoiningTests {
    private let callData = ElementCallData(isAudioCall: true, isStartingCall: false)
    private let first = ElementCallFakeRoom(roomID: "!first:example.org")
    private let second = ElementCallFakeRoom(roomID: "!second:example.org")
    
    /// No call, so nothing reaches the audio engine or the media server, which is what a host's
    /// tests need from this fake.
    @Test
    func aCallInARoomThatNeverOpensStaysJoining() async throws {
        let fixture = Fixture()
        fixture.controller.startCall(callData, room: first)
        try await fixture.waitForTheRoom(first)
        
        // Ample for a room that opens: the fake answers everything at once.
        try await Task.sleep(for: .milliseconds(500))
        #expect(fixture.controller.connection == .joining)
        #expect(fixture.controller.rtcCall == nil)
        #expect(fixture.controller.call == nil)
        
        try await fixture.hangUp(first)
    }
    
    /// The hang-up cancels the join, and the cancel makes the wait for the room throw. That throw
    /// used to fail a call that had already ended: `.failed` in place of `.ended(.left)`, and the
    /// system told twice.
    @Test
    func hangingUpWhileJoiningEndsTheCallOnce() async throws {
        let fixture = Fixture()
        fixture.controller.startCall(callData, room: first)
        try await fixture.waitForTheRoom(first)
        
        try await fixture.hangUp(first)
        
        #expect(fixture.controller.connection == .ended(.left))
        #expect(fixture.recorder.endedCount == 1)
        #expect(fixture.systemEnds == [.end(roomID: first.roomID, reason: .local)])
    }
    
    /// A host that starts the next call on `.ended` starts it before the cancelled join has
    /// unwound, so the failure the join used to report landed on the new call and ended it.
    @Test
    func aCallStartedAsTheLastOneEndsKeepsJoining() async throws {
        let fixture = Fixture()
        fixture.recorder.onEnded = { [controller = fixture.controller, callData, second] in
            controller.reset()
            controller.startCall(callData, room: second)
        }
        fixture.controller.startCall(callData, room: first)
        try await fixture.waitForTheRoom(first)
        
        try await fixture.hangUp(first)
        try await fixture.waitForTheRoom(second)
        
        #expect(fixture.controller.connection == .joining)
        #expect(fixture.controller.room?.roomID == second.roomID)
        #expect(fixture.systemEnds == [.end(roomID: first.roomID, reason: .local)])
        
        try await fixture.hangUp(second)
        #expect(fixture.systemEnds == [.end(roomID: first.roomID, reason: .local),
                                       .end(roomID: second.roomID, reason: .local)])
    }
    
    // MARK: - Helpers
    
    private final class Fixture {
        let system: ElementCallFakeSystem
        let logger: ElementCallFakeLogger
        let controller: ElementCallController
        let recorder: Recorder
        
        init() {
            let system = ElementCallFakeSystem()
            let logger = ElementCallFakeLogger()
            let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                                   system: system,
                                                   options: ElementCallOptions(),
                                                   style: .stock,
                                                   logger: logger)
            self.system = system
            self.logger = logger
            self.controller = controller
            recorder = Recorder(controller)
        }
        
        var systemEnds: [ElementCallFakeSystem.Request] {
            system.requests.filter {
                if case .end = $0 {
                    true
                } else {
                    false
                }
            }
        }
        
        /// The system is asked to start the call just before the room is opened, so from here the
        /// join is waiting for a room that never comes.
        func waitForTheRoom(_ room: ElementCallFakeRoom) async throws {
            try await waitUntil { [system] in
                system.requests.contains {
                    if case .start(roomID: room.roomID, displayName: _, isVideo: _) = $0 {
                        true
                    } else {
                        false
                    }
                }
            }
        }
        
        /// Hangs up and waits for the join to unwind as well as for the call to end, so a test sees
        /// what the join does on its way out. It says so in the log, or fails.
        ///
        /// Waits on the action rather than the connection: a host starting a call on `.ended` moves
        /// the connection on before anything here can read `.ended` in it.
        func hangUp(_ room: ElementCallFakeRoom) async throws {
            let endedCount = recorder.endedCount
            controller.hangUp()
            try await waitUntil { [recorder] in recorder.endedCount > endedCount }
            try await waitUntil { [logger] in
                logger.records.contains { $0.level == .error || $0.message.hasPrefix("join of \(room.roomID) was cancelled") }
            }
        }
        
        private func waitUntil(_ condition: @escaping () -> Bool) async throws {
            try await deferFulfillment(values(condition)) { $0 }.fulfill()
        }
    }
    
    /// Collected through a reference so the closure has somewhere to write that outlives the call.
    private final class Recorder {
        private(set) var endedCount = 0
        /// Run on the first `.ended` only, the way a host starts the call it was waiting to start.
        var onEnded: (() -> Void)?
        private var cancellable: AnyCancellable?
        
        init(_ controller: ElementCallController) {
            cancellable = controller.actions.sink { [weak self] action in
                guard let self, case .ended = action else { return }
                endedCount += 1
                let onEnded = onEnded
                self.onEnded = nil
                onEnded?()
            }
        }
    }
}
