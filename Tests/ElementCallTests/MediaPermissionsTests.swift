//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// `@testable` for the controller's scripted join and audio switch.
import Combine
@testable import ElementCallHost
import ElementCallKit
@testable import ElementCallUI
import Foundation
import Testing

/// Spec 042 over the real controller, with the permissions answered by
/// ``ElementCallFakeMediaPermissions``. A join that must not get past the gate runs over
/// ``ElementCallFakeMatrixBackend``, whose room never opens; one that needs media runs over the
/// scripted join the `permission_probe` fixture uses, with the audio engine kept off.
@Suite("Call media permissions")
@MainActor
struct MediaPermissionsTests {
    private let room = ElementCallFakeRoom(roomID: "!room:example.org")
    private let videoCall = ElementCallData(isAudioCall: false, isStartingCall: true)
    private let voiceCall = ElementCallData(isAudioCall: true, isStartingCall: true)
    
    // MARK: - The microphone
    
    /// R9: refused before the call starts, the first frame is the failure, with nothing asked.
    @Test
    func aRefusedMicrophoneFailsTheCallAtOnce() async throws {
        let fixture = Fixture(microphone: .refused)
        fixture.controller.startCall(videoCall, room: room)
        
        #expect(fixture.controller.connection == .failed(.microphoneRefused))
        #expect(fixture.permissions.requests.isEmpty)
        try await waitUntil { fixture.system.requests.contains(.end(roomID: room.roomID, reason: .failed)) }
        #expect(!fixture.system.requests.contains {
            if case .start = $0 {
                true
            } else {
                false
            }
        })
        
        // The screen stays until it is closed (034 R27).
        #expect(fixture.recorder.endedCount == 0)
        fixture.controller.hangUp()
        #expect(fixture.recorder.endedCount == 1)
    }
    
    /// R1: nothing is claimed while the dialog is open; a grant then goes on to the join.
    @Test
    func nothingIsClaimedWhileTheMicrophoneIsAsked() async throws {
        let fixture = Fixture(microphone: .notAsked)
        let dialog = fixture.holdDialogs()
        fixture.controller.startCall(videoCall, room: room)
        
        try await waitUntil { fixture.permissions.requests == [.microphone] }
        #expect(fixture.controller.connection == .joining)
        #expect(fixture.system.requests.isEmpty)
        
        dialog.answer(true)
        try await waitUntil { fixture.system.requests.contains {
            if case .start = $0 {
                true
            } else {
                false
            }
        } }
        try await fixture.hangUp()
    }
    
    /// R5, C4: a no fails the call before anything is claimed, and the camera is never asked.
    @Test
    func refusingTheMicrophoneFailsTheCall() async throws {
        let fixture = Fixture(microphone: .notAsked, camera: .notAsked)
        fixture.permissions.answerWhenAsked = false
        fixture.controller.startCall(videoCall, room: room)
        
        try await waitUntil { fixture.controller.connection == .failed(.microphoneRefused) }
        try await waitUntil { fixture.system.requests.contains(.end(roomID: room.roomID, reason: .failed)) }
        #expect(fixture.permissions.requests == [.microphone])
        #expect(fixture.controller.rtcCall == nil)
        #expect(!fixture.system.requests.contains {
            if case .start = $0 {
                true
            } else {
                false
            }
        })
        #expect(fixture.recorder.endedCount == 0)
    }
    
    /// R4: granted, nothing is asked through to a published call.
    @Test
    func grantedPermissionsAskNothing() async throws {
        let fixture = Fixture()
        fixture.scriptJoin()
        fixture.controller.startCall(videoCall, room: room)
        
        try await waitUntil { fixture.controller.call?.isCameraEnabled == true }
        #expect(fixture.permissions.requests.isEmpty)
        try await fixture.hangUp()
    }
    
    // MARK: - The camera
    
    /// R2: the camera after the microphone, never while its dialog is open.
    @Test
    func aVideoCallAsksForTheCameraAfterTheMicrophone() async throws {
        let fixture = Fixture(microphone: .notAsked, camera: .notAsked)
        let dialog = fixture.holdDialogs()
        fixture.scriptJoin()
        fixture.controller.startCall(videoCall, room: room)
        
        try await waitUntil { fixture.permissions.requests == [.microphone] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.permissions.requests == [.microphone])
        
        dialog.answer(true)
        try await waitUntil { fixture.permissions.requests == [.microphone, .camera] }
        dialog.answer(true)
        try await waitUntil { fixture.controller.call?.isCameraEnabled == true }
        try await fixture.hangUp()
    }
    
    /// R3: a voice call asks for the camera only from a tap.
    @Test
    func aVoiceCallAsksForTheCameraOnlyFromATap() async throws {
        let fixture = Fixture(camera: .notAsked)
        fixture.scriptJoin()
        fixture.controller.startCall(voiceCall, room: room)
        
        try await waitUntil { fixture.controller.call != nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.permissions.requests.isEmpty)
        
        fixture.controller.setCameraEnabled(true)
        try await waitUntil { fixture.controller.call?.isCameraEnabled == true }
        #expect(fixture.permissions.requests == [.camera])
        try await fixture.hangUp()
    }
    
    /// R2, C4: a tap while the microphone is being asked records the intent; the camera is asked
    /// once the microphone is answered, and turns on.
    @Test
    func aCameraTapWhileTheMicrophoneIsAskedWaitsForIt() async throws {
        let fixture = Fixture(microphone: .notAsked, camera: .notAsked)
        let dialog = fixture.holdDialogs()
        fixture.scriptJoin()
        fixture.controller.startCall(voiceCall, room: room)
        try await waitUntil { fixture.permissions.requests == [.microphone] }
        
        fixture.controller.setCameraEnabled(true)
        try await waitUntil { fixture.controller.isCameraEnabled }
        #expect(fixture.permissions.requests == [.microphone])
        
        dialog.answer(true)
        try await waitUntil { fixture.permissions.requests == [.microphone, .camera] }
        dialog.answer(true)
        try await waitUntil { fixture.controller.call?.isCameraEnabled == true }
        try await fixture.hangUp()
    }
    
    /// R10: a refused camera reads off from the start, and the call goes on with nothing said.
    @Test
    func aRefusedCameraJoinsWithTheCameraOff() async throws {
        let fixture = Fixture(camera: .refused)
        fixture.scriptJoin()
        fixture.controller.startCall(videoCall, room: room)
        #expect(!fixture.controller.isCameraEnabled)
        
        try await waitUntil { fixture.controller.call != nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.controller.call?.isCameraEnabled == false)
        #expect(fixture.permissions.requests.isEmpty)
        #expect(!fixture.controller.isCameraRefusalNoticePending)
        try await fixture.hangUp()
    }
    
    /// R11: a tap on a refused camera asks nothing and is explained, with a way to the settings.
    @Test
    func aTapOnARefusedCameraIsExplained() async throws {
        let fixture = Fixture(camera: .refused)
        fixture.scriptJoin()
        let viewModel = ElementCallScreenViewModel(controller: fixture.controller)
        fixture.controller.startCall(voiceCall, room: room)
        try await waitUntil { fixture.controller.call != nil }
        
        viewModel.context.send(viewAction: .toggleCamera)
        try await waitUntil { viewModel.context.alertInfo?.action == .openSettings }
        #expect(viewModel.context.alertInfo?.title == L10n.permissionCameraTitle)
        #expect(fixture.permissions.requests.isEmpty)
        #expect(!fixture.controller.isCameraEnabled)
        
        viewModel.context.send(viewAction: .openSettings)
        #expect(fixture.permissions.openSettingsCount == 1)
        try await fixture.hangUp()
    }
    
    /// R12: a grant since the last tap turns the camera on, with no prompt.
    @Test
    func aCameraGrantedSinceTheLastTapTurnsOn() async throws {
        let fixture = Fixture(camera: .refused)
        fixture.scriptJoin()
        fixture.controller.startCall(voiceCall, room: room)
        try await waitUntil { fixture.controller.call != nil }
        
        fixture.permissions.camera = .granted
        fixture.controller.setCameraEnabled(true)
        try await waitUntil { fixture.controller.call?.isCameraEnabled == true }
        #expect(fixture.permissions.requests.isEmpty)
        try await fixture.hangUp()
    }
    
    // MARK: - Helpers
    
    private final class Fixture {
        let system = ElementCallFakeSystem()
        let permissions: ElementCallFakeMediaPermissions
        let controller: ElementCallController
        let recorder: Recorder
        
        init(microphone: ElementCallMediaPermission = .granted, camera: ElementCallMediaPermission = .granted) {
            permissions = ElementCallFakeMediaPermissions(microphone: microphone, camera: camera)
            controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: system,
                                               options: ElementCallOptions(),
                                               style: .stock,
                                               logger: nil,
                                               preferences: ElementCallFakePreferencesStore(),
                                               permissions: permissions)
            controller.clock = MatrixRTCManualClock()
            controller.isAudioEnabled = false
            recorder = Recorder(controller)
        }
        
        /// Every dialog stays open until answered, in the order asked.
        func holdDialogs() -> Dialogs {
            let dialogs = Dialogs()
            permissions.answers = { _ in await dialogs.next() }
            return dialogs
        }
        
        /// A scripted membership, connected, and a scripted media session for it.
        func scriptJoin() {
            let scripted = MatrixRTCScriptedCall(roomID: "!room:example.org", status: .connected(since: .now, isDegraded: false))
            let player = MatrixRTCScenarioPlayer(scenario: MatrixRTCScenario(name: "permissions", frames: []))
            controller.scriptedJoin = { (scripted.call, player.call) }
        }
        
        func hangUp() async throws {
            controller.hangUp()
            for _ in 0..<1000 where !controller.connection.isOver {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(controller.connection.isOver)
        }
    }
    
    /// Dialogs held open, answered one at a time.
    @MainActor
    private final class Dialogs {
        private var pending: [CheckedContinuation<Bool, Never>] = []
        private var early: [Bool] = []
        
        func next() async -> Bool {
            if !early.isEmpty {
                return early.removeFirst()
            }
            return await withCheckedContinuation { pending.append($0) }
        }
        
        func answer(_ granted: Bool) {
            if pending.isEmpty {
                early.append(granted)
            } else {
                pending.removeFirst().resume(returning: granted)
            }
        }
    }
    
    private final class Recorder {
        private(set) var endedCount = 0
        private var cancellable: AnyCancellable?
        
        init(_ controller: ElementCallController) {
            cancellable = controller.actions.sink { [weak self] action in
                if case .ended = action {
                    self?.endedCount += 1
                }
            }
        }
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

private extension ElementCallConnection {
    var isOver: Bool {
        switch self {
        case .ended, .failed, .idle: true
        default: false
        }
    }
}
