//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementCallHost
@testable import ElementCallKit
import Foundation
import Testing

/// Incoming answers use startCall just like outgoing calls. A waiting answer reaches it after the
/// previous call's teardown and reset. This exercises both entries, retaining the real permission,
/// system-claim and publication path, with only the room/core join replaced by a scripted seam.
@Suite("Native answer microphone authorization", .timeLimit(.minutes(1)))
@MainActor
struct NativeAnswerMediaPermissionsTests {
    @Test(arguments: [false, true])
    func anAuthorizedAnswerPublishesWithoutPrompting(afterPreviousCall: Bool) async throws {
        let fixture = Fixture()
        try await fixture.prepareAnswer(afterPreviousCall: afterPreviousCall, permission: .granted)
        fixture.answer()
        
        try await fixture.waitForMicrophone()
        #expect(fixture.permissions.requests.isEmpty)
        #expect(fixture.starts.count == 1)
        try await fixture.hangUp()
    }
    
    @Test(arguments: [false, true])
    func aGrantAllowsOneAnswerAndOneMicrophonePublication(afterPreviousCall: Bool) async throws {
        let fixture = Fixture()
        try await fixture.prepareAnswer(afterPreviousCall: afterPreviousCall, permission: .notAsked)
        fixture.holdPermission()
        defer { fixture.answerPermission(false) }
        fixture.answer()
        try await fixture.waitForPermission()
        
        // Admission may read while the dependency waits. A repeated answer must not start a second
        // request, claim the system call or publish membership/media before the first answer settles.
        #expect(fixture.permissions.permission(for: .microphone) == .notAsked)
        fixture.answer()
        await drain()
        fixture.expectNothingJoined()
        #expect(fixture.permissions.requests == [.microphone])
        
        fixture.answerPermission(true)
        try await fixture.waitForMicrophone()
        #expect(fixture.permissions.requests == [.microphone])
        #expect(fixture.starts.count == 1)
        #expect(fixture.publications.count == 1)
        try await fixture.hangUp()
    }
    
    @Test(arguments: [false, true])
    func aDeniedAnswerEndsWithoutClaimingOrPublishing(afterPreviousCall: Bool) async throws {
        let fixture = Fixture()
        try await fixture.prepareAnswer(afterPreviousCall: afterPreviousCall, permission: .notAsked)
        fixture.holdPermission()
        defer { fixture.answerPermission(false) }
        fixture.answer()
        try await fixture.waitForPermission()
        fixture.answerPermission(false)
        
        try await waitUntil { fixture.ends == [.end(roomID: fixture.room.roomID, reason: .failed)] }
        #expect(fixture.controller.connection == .failed(.microphoneRefused))
        #expect(fixture.permissions.requests == [.microphone])
        fixture.expectNothingJoined()
        fixture.controller.hangUp()
        #expect(fixture.dismissals == 1)
    }
    
    /// The permission port maps both denied and restricted states to refused. Neither is requested.
    @Test(arguments: [false, true])
    func aPreviouslyRefusedAnswerDoesNotPromptAgain(afterPreviousCall: Bool) async throws {
        let fixture = Fixture()
        try await fixture.prepareAnswer(afterPreviousCall: afterPreviousCall, permission: .refused)
        fixture.answer()
        
        #expect(fixture.controller.connection == .failed(.microphoneRefused))
        try await waitUntil { fixture.ends == [.end(roomID: fixture.room.roomID, reason: .failed)] }
        #expect(fixture.permissions.requests.isEmpty)
        fixture.expectNothingJoined()
        fixture.controller.hangUp()
        #expect(fixture.dismissals == 1)
    }
    
    @Test
    func aRefusalSettlingBeforeTheJoinTaskRunsCannotBypassTheGate() async throws {
        let fixture = Fixture()
        fixture.permissions.microphone = .notAsked
        fixture.answer()
        // No suspension: startCall has read notAsked but its run task has not read it yet.
        fixture.permissions.microphone = .refused
        
        try await waitUntil { fixture.ends == [.end(roomID: fixture.room.roomID, reason: .failed)] }
        #expect(fixture.controller.connection == .failed(.microphoneRefused))
        #expect(fixture.permissions.requests.isEmpty)
        fixture.expectNothingJoined()
        fixture.controller.hangUp()
    }
    
    @Test(arguments: [false, true], [false, true])
    func aLatePermissionReplyCannotReviveACancelledAnswer(endsFromSystem: Bool, granted: Bool) async throws {
        let fixture = Fixture()
        fixture.permissions.microphone = .notAsked
        fixture.holdPermission()
        defer { fixture.answerPermission(false) }
        fixture.answer()
        try await fixture.waitForPermission()
        
        if endsFromSystem {
            // Expiry/end of the answered CallKit invitation is delivered through the system port.
            fixture.system.send(.endCallRequested(roomID: fixture.room.roomID))
        } else {
            // A host invalidating a waiting answer calls hangUp through the same cancellation path.
            fixture.controller.hangUp()
        }
        try await waitUntil { fixture.ends == [.end(roomID: fixture.room.roomID, reason: .local)] }
        #expect(fixture.dismissals == 1)
        
        fixture.answerPermission(granted)
        try await waitUntil { fixture.permissionReplies == 1 }
        await drain()
        #expect(fixture.controller.connection == .ended(.left))
        #expect(fixture.ends.count == 1)
        #expect(fixture.dismissals == 1)
        #expect(fixture.permissions.requests == [.microphone])
        fixture.expectNothingJoined()
    }
    
    @Test(arguments: [false, true])
    func aLatePermissionReplyCannotAffectAReplacementAnswer(granted: Bool) async throws {
        let fixture = Fixture()
        fixture.permissions.microphone = .notAsked
        fixture.holdPermission()
        defer { fixture.answerPermission(false) }
        fixture.answer()
        try await fixture.waitForPermission()
        try await fixture.hangUp()
        fixture.controller.reset()
        
        // The replacement has its own permission result, as when permission changed in Settings.
        fixture.permissions.microphone = .granted
        fixture.answer()
        try await fixture.waitForMicrophone()
        let replacement = fixture.controller.call
        fixture.answerPermission(granted)
        try await waitUntil { fixture.permissionReplies == 1 }
        await drain()
        
        #expect(fixture.controller.call === replacement)
        #expect(fixture.controller.isInCall)
        #expect(fixture.starts.count == 1)
        #expect(fixture.publications.count == 1)
        #expect(fixture.permissions.requests == [.microphone])
        try await fixture.hangUp()
    }
    
    // MARK: - Helpers
    
    private final class Fixture {
        let room = ElementCallFakeRoom(roomID: "!answer:example.org")
        let system = ElementCallFakeSystem()
        let permissions = ElementCallFakeMediaPermissions()
        let controller: ElementCallController
        private var pendingPermission: CheckedContinuation<Bool, Never>?
        private var cancellable: AnyCancellable?
        private var media: [FakeMediaSession] = []
        private(set) var joins = 0
        private(set) var permissionReplies = 0
        private(set) var dismissals = 0
        
        init() {
            controller = ElementCallController(backend: ElementCallFakeMatrixBackend(), system: system,
                                               options: .init(), preferences: ElementCallFakePreferencesStore(),
                                               permissions: permissions)
            controller.clock = MatrixRTCManualClock()
            controller.isAudioEnabled = false
            controller.scriptedJoin = { [weak self] in
                guard let self else { throw CancellationError() }
                joins += 1
                let transport = FakeMediaSession()
                media.append(transport)
                return (MatrixRTCCall(rtcCall: FakeRTCCall(intent: .audio)),
                        MatrixRTCMediaSession(localMemberID: "me", mediaSession: transport, capturesCamera: false, capturesMicrophone: false))
            }
            cancellable = controller.actions.sink { [weak self] action in
                if case .ended = action {
                    self?.dismissals += 1
                }
            }
        }
        
        var starts: [ElementCallFakeSystem.Request] {
            system.requests.filter {
                if case .start(roomID: room.roomID, displayName: _, isVideo: _) = $0 {
                    true
                } else {
                    false
                }
            }
        }
        
        var ends: [ElementCallFakeSystem.Request] {
            system.requests.filter {
                if case .end(roomID: room.roomID, reason: _) = $0 {
                    true
                } else {
                    false
                }
            }
        }
        
        var publications: [FakeMediaSession] {
            media.filter { $0.published.contains { $0.kind == .microphone } }
        }
        
        func prepareAnswer(afterPreviousCall: Bool, permission: ElementCallMediaPermission) async throws {
            if afterPreviousCall {
                let previousRoom = ElementCallFakeRoom(roomID: "!previous:example.org")
                controller.startCall(.init(isAudioCall: true, isStartingCall: false), room: previousRoom)
                try await waitUntil { !publications.isEmpty }
                controller.hangUp()
                try await waitUntil { system.requests.contains(.end(roomID: previousRoom.roomID, reason: .local)) }
                controller.reset()
                media.removeAll()
                joins = 0
                dismissals = 0
            }
            permissions.microphone = permission
        }
        
        func answer() {
            controller.startCall(.init(isAudioCall: true, isStartingCall: false), room: room)
        }
        
        func holdPermission() {
            permissions.answers = { [weak self] _ in
                guard let self else { return false }
                let granted = await withCheckedContinuation { pendingPermission = $0 }
                permissionReplies += 1
                return granted
            }
        }
        
        func waitForPermission() async throws {
            try await waitUntil { pendingPermission != nil }
            #expect(permissions.requests == [.microphone])
            expectNothingJoined()
        }
        
        func answerPermission(_ granted: Bool) {
            let pending = pendingPermission
            pendingPermission = nil
            pending?.resume(returning: granted)
        }
        
        func waitForMicrophone() async throws {
            try await waitUntil { !publications.isEmpty }
            #expect(joins == 1)
            #expect(publications.allSatisfy { $0.published.filter { $0.kind == .microphone }.count == 1 })
        }
        
        func expectNothingJoined() {
            #expect(starts.isEmpty)
            #expect(joins == 0)
            #expect(publications.isEmpty)
            #expect(controller.rtcCall == nil)
            #expect(controller.call == nil)
        }
        
        func hangUp() async throws {
            let previousEnds = ends.count
            controller.hangUp()
            try await waitUntil { ends.count == previousEnds + 1 }
        }
    }
}

@MainActor
private func drain() async {
    for _ in 0..<50 {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
}
