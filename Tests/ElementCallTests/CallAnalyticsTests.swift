//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementCallHost
@testable import ElementCallKit
@testable import ElementCallUI
import Foundation
import MatrixRtc
import Testing

/// The analytics a real controller reports, through the scripted join: a scripted membership whose
/// status the test plays, and a scripted media session, with everything around them as it ships
/// (044).
@Suite("Call analytics")
@MainActor
struct CallAnalyticsTests {
    private typealias Failure = ElementCallAnalyticsFailure
    
    private let voiceCall = ElementCallData(isAudioCall: true, isStartingCall: true)
    private let connected = MatrixRTCCallStatus.connected(since: .now, isDegraded: false)
    private static let callee = "@bob:example.org"
    private static let secret = "secret server text M_SECRET"
    
    // MARK: - Connected and ended (R6–R8, R11, R25)
    
    @Test
    func aGroupCallIsAttemptedConnectedAndEnded() async throws {
        let fixture = Fixture(isDirect: false)
        fixture.scriptJoin(status: connected)
        fixture.start(voiceCall)
        #expect(fixture.names == ["CallJoinAttempted"])
        
        try await fixture.waitForOutcome()
        #expect(fixture.outcomes == [.connected])
        try await fixture.hangUp()
        
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome", "CallParticipationEnded"])
        #expect(fixture.events.last?.endReason == .left)
        #expect(fixture.events.allSatisfy { $0.callKind == .group })
        fixture.expectNoIdentifiers()
    }
    
    /// R8: connected while it rings, once our microphone is up; never at the pickup. An unanswered
    /// ring is an end, not a failure (R12), with only ourselves in it (R26).
    @Test
    func anOutgoingDMConnectsWhileRinging() async throws {
        let fixture = Fixture(isDirect: true)
        let scripted = fixture.scriptJoin(status: .calling(callee: Self.callee, ring: .sending, media: .connecting))
        fixture.start(voiceCall)
        // The status was applied before the publish, so with the microphone up and the media not,
        // nothing can be on its way.
        try await fixture.waitForThePublish()
        #expect(fixture.outcomes.isEmpty)
        
        scripted.report(.calling(callee: Self.callee, ring: .ringing(sentAt: .now, lifetime: .seconds(60)), media: .connected(isDegraded: false)))
        try await fixture.waitForOutcome()
        #expect(fixture.outcomes == [.connected])
        
        scripted.report(.ended(.unanswered))
        try await fixture.waitUntil { fixture.names.count == 3 }
        
        #expect(fixture.events.last?.endReason == .unanswered)
        #expect(fixture.events.last?.properties["participantsMax"] == .int(1))
        #expect(fixture.failures.isEmpty)
        #expect(fixture.events.allSatisfy { $0.callKind == .dm })
        fixture.expectNoIdentifiers()
    }
    
    /// R9, R24: declined before our media is up.
    @Test
    func aDMDeclinedBeforeConnectedIsAbandonedWithItsReason() async throws {
        let fixture = Fixture(isDirect: true)
        let scripted = fixture.scriptJoin(status: .calling(callee: Self.callee, ring: .sending, media: .connecting))
        fixture.start(voiceCall)
        try await fixture.waitUntil { fixture.controller.call != nil }
        
        scripted.report(.ended(.declined))
        try await fixture.waitForOutcome()
        
        #expect(fixture.outcomes == [.abandoned(endReason: .declined)])
        #expect(fixture.failures.isEmpty)
        try await fixture.waitUntil { fixture.controller.connection.isFinished }
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome"])
    }
    
    /// R9, R24: the user's hang-up while connecting is abandoned, with no reason.
    @Test
    func aHangUpWhileConnectingIsAbandonedWithNoReason() async throws {
        let fixture = Fixture(isDirect: false)
        fixture.scriptJoin(status: .connecting)
        fixture.start(voiceCall)
        try await fixture.waitUntil { fixture.controller.call != nil }
        
        try await fixture.hangUp()
        
        #expect(fixture.outcomes == [.abandoned(endReason: nil)])
        #expect(fixture.failures.isEmpty)
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome"])
    }
    
    // MARK: - The microphone (R8, R16, C6)
    
    /// The status says connected, but the microphone never publishes: a join failure, never
    /// `connected`.
    @Test
    func aMicrophoneThatWillNotPublishIsAJoinFailure() async throws {
        let fixture = Fixture(isDirect: false, publishError: MatrixRTCError.media("no microphone"))
        fixture.scriptJoin(status: connected)
        fixture.start(voiceCall)
        try await fixture.waitUntil { fixture.session.published.count == 1 }
        
        try await fixture.advancePastTheGrace { !fixture.failures.isEmpty }
        
        #expect(fixture.outcomes == [.failed])
        #expect(fixture.failures == [Failure(cause: .microphoneFailed, phase: .joining(.media, .mediaConnection))])
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome", "CallFailure"])
        fixture.expectNoIdentifiers()
    }
    
    /// C6: the core ending the call inside the grace is what is reported.
    @Test
    func theCoresEndInsideTheGraceIsReportedInstead() async throws {
        let fixture = Fixture(isDirect: false, publishError: MatrixRTCError.media("no microphone"))
        let scripted = fixture.scriptJoin(status: connected)
        fixture.start(voiceCall)
        // In the grace: the controller is asleep on the clock for its first 50 ms step.
        try await fixture.waitUntil { fixture.clock.sleeperDeadlines.contains(.milliseconds(50)) }
        
        scripted.report(.ended(.connectionClosed(reason: .budget, message: Self.secret)))
        try await fixture.waitForOutcome()
        try await fixture.advancePastTheGrace { fixture.controller.connection.isFinished }
        try await Task.sleep(for: .milliseconds(20))
        
        #expect(fixture.outcomes == [.failed])
        #expect(fixture.failures == [Failure(cause: .connectionLostBudget, phase: .joining(.media, .unknown))])
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome", "CallFailure"])
        fixture.expectNoIdentifiers()
    }
    
    // MARK: - participantsMax (R26)
    
    @Test
    func participantsMaxFollowsTheCallsSizeFromConnected() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: .connecting)
        // A count before connected is ignored by the reporter, which its own tests pin: nothing
        // here says when the controller's reader has handed one over, so it is not pushed here.
        fixture.start(voiceCall)
        try await fixture.waitForThePublish()
        
        scripted.report(connected)
        try await fixture.waitForOutcome()
        fixture.player.session.push(event: .participantJoined(memberId: "@carol:example.org:C", userId: "@carol:example.org", participantCount: 2))
        fixture.player.session.push(event: .participantJoined(memberId: "@dan:example.org:D", userId: "@dan:example.org", participantCount: 3))
        fixture.player.session.push(event: .participantLeft(memberId: "@dan:example.org:D", participantCount: 2))
        // The events reach the reporter through the session's pump and the controller's reader; a
        // loaded run takes its time.
        try await fixture.waitUntil { fixture.controller.reporter.participantsMax == 3 }
        try await fixture.hangUp()
        
        #expect(fixture.events.last?.properties["participantsMax"] == .int(3))
        fixture.expectNoIdentifiers()
    }
    
    // MARK: - Slot closed (R12, C8)
    
    @Test
    func aSlotClosedBeforeConnectedIsAbandoned() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: .connecting)
        fixture.start(voiceCall)
        try await fixture.waitUntil { fixture.controller.call != nil }
        
        scripted.report(.ended(.slotClosed))
        try await fixture.waitForOutcome()
        
        #expect(fixture.outcomes == [.abandoned(endReason: .slotClosed)])
        #expect(fixture.failures.isEmpty)
    }
    
    @Test
    func aSlotClosedInTheCallIsAnEnd() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: connected)
        fixture.start(voiceCall)
        try await fixture.waitForOutcome()
        
        scripted.report(.ended(.slotClosed))
        try await fixture.waitUntil { fixture.names.count == 3 }
        
        #expect(fixture.events.last?.endReason == .slotClosed)
        #expect(fixture.failures.isEmpty)
    }
    
    // MARK: - Permission (R10)
    
    @Test
    func aMicrophoneAlreadyRefusedIsPermissionRefused() async throws {
        let fixture = Fixture(isDirect: false, microphone: .refused)
        fixture.start(voiceCall)
        try await fixture.waitUntil { fixture.controller.connection.isFinished }
        
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome"])
        #expect(fixture.outcomes == [.permissionRefused])
    }
    
    @Test
    func aMicrophoneRefusedAtTheDialogIsPermissionRefused() async throws {
        let fixture = Fixture(isDirect: false, microphone: .notAsked)
        fixture.permissions.answerWhenAsked = false
        fixture.start(voiceCall)
        try await fixture.waitForOutcome()
        
        #expect(fixture.outcomes == [.permissionRefused])
        #expect(fixture.failures.isEmpty)
    }
    
    // MARK: - Connection lost (R15, R16)
    
    @Test
    func aMediaServerRefusingBeforeConnectedIsAJoinFailure() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: .connecting)
        fixture.start(voiceCall)
        try await fixture.waitUntil { fixture.controller.call != nil }
        
        scripted.report(.ended(.connectionClosed(reason: .refused, message: Self.secret)))
        try await fixture.waitUntil { fixture.names.count == 3 }
        
        #expect(fixture.outcomes == [.failed])
        #expect(fixture.failures == [Failure(cause: .connectionLostRefused, phase: .joining(.media, .unknown))])
        fixture.expectNoIdentifiers()
    }
    
    @Test
    func aMediaServerRefusingAfterConnectedIsAnInCallFailureThenAnEnd() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: connected)
        fixture.start(voiceCall)
        try await fixture.waitForOutcome()
        
        scripted.report(.ended(.connectionClosed(reason: .refused, message: Self.secret)))
        try await fixture.waitUntil { fixture.names.count == 4 }
        
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome", "CallFailure", "CallParticipationEnded"])
        #expect(fixture.failures == [Failure(cause: .connectionLostRefused, phase: .inCall)])
        #expect(fixture.events.last?.endReason == .connectionLost)
        fixture.expectNoIdentifiers()
    }
    
    /// The screen folds a missing `get_token` into the MSC format's failure (043 R18); the event
    /// still names it.
    @Test
    func aMissingTokenEndpointIsNamedWhateverTheScreenShows() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: .connecting)
        fixture.start(voiceCall)
        try await fixture.waitUntil { fixture.controller.call != nil }
        
        scripted.report(.ended(.connectionClosed(reason: .tokenEndpointUnsupported, message: Self.secret)))
        try await fixture.waitUntil { fixture.names.count == 3 }
        
        #expect(fixture.failures == [Failure(cause: .tokenEndpointUnsupported, phase: .joining(.media, .mediaToken))])
        // In the MSC format the screen says the format's failure, from the same loss.
        let screen = ElementCallController.failure(forLoss: .tokenEndpointUnsupported, message: Self.secret, format: .msc)
        guard case .mscJoinFailed = screen else {
            Issue.record("expected mscJoinFailed, got \(screen)")
            return
        }
    }
    
    // MARK: - Before teardown (R13)
    
    @Test
    func aHangUpReportsTheEndBeforeItReturnsAndBeforeTeardown() async throws {
        let fixture = Fixture(isDirect: false)
        fixture.scriptJoin(status: connected)
        let seen = fixture.recordStateAtTheEnd()
        fixture.start(voiceCall)
        try await fixture.waitForOutcome()
        
        fixture.controller.hangUp()
        // Synchronously, before `hangUp()` returns.
        #expect(fixture.names.last == "CallParticipationEnded")
        #expect(seen.state == EndState(hasCall: true, hasSystemEnd: false))
        try await fixture.waitUntil { fixture.controller.connection.isFinished }
    }
    
    @Test
    func anEndFromTheCoreIsReportedBeforeTeardown() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: connected)
        let seen = fixture.recordStateAtTheEnd()
        fixture.start(voiceCall)
        try await fixture.waitForOutcome()
        
        scripted.report(.ended(.othersLeft))
        try await fixture.waitUntil { fixture.names.count == 3 }
        
        #expect(fixture.events.last?.endReason == .othersLeft)
        #expect(seen.state == EndState(hasCall: true, hasSystemEnd: false))
    }
    
    // MARK: - The core's end over a racing hang-up (C8)
    
    /// The callee declines as the caller hangs up: the core has the decline, and the status reader
    /// has not delivered it, when `hangUp()` runs. The decline is what is reported.
    @Test
    func aDeclineTheCoreHasReachedWinsOverAHangUp() async throws {
        let fixture = Fixture(isDirect: true)
        let core = fixture.scriptJoin(core: FakeRTCCall(status: .calling(callee: Self.callee, ring: .sending, media: .connecting)))
        fixture.start(voiceCall)
        try await fixture.waitForThePublish()
        #expect(fixture.outcomes.isEmpty)
        
        core.reach(.ended(reason: .declined))
        fixture.controller.hangUp()
        
        #expect(fixture.outcomes == [.abandoned(endReason: .declined)])
        try await fixture.waitUntil { fixture.controller.connection.isFinished }
        #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome"])
    }
    
    /// After connected the same: the core's reason, not `left`.
    @Test
    func anEndTheCoreHasReachedInTheCallWinsOverAHangUp() async throws {
        let fixture = Fixture(isDirect: true)
        let core = fixture.scriptJoin(core: FakeRTCCall(status: .connected(sinceMs: 0, degraded: false)))
        fixture.start(voiceCall)
        try await fixture.waitForOutcome()
        
        core.reach(.ended(reason: .othersLeft))
        fixture.controller.hangUp()
        
        #expect(fixture.events.last?.endReason == .othersLeft)
        try await fixture.waitUntil { fixture.controller.connection.isFinished }
        #expect(fixture.events.filter { $0.name == "CallParticipationEnded" }.count == 1)
    }
    
    /// Nothing reached: the hang-up is ours, with no reason.
    @Test
    func aHangUpWithNoEndFromTheCoreIsOurs() async throws {
        let fixture = Fixture(isDirect: true)
        fixture.scriptJoin(core: FakeRTCCall(status: .calling(callee: Self.callee, ring: .sending, media: .connecting)))
        fixture.start(voiceCall)
        try await fixture.waitForThePublish()
        
        fixture.controller.hangUp()
        
        #expect(fixture.outcomes == [.abandoned(endReason: nil)])
        try await fixture.waitUntil { fixture.controller.connection.isFinished }
    }
    
    /// The two places the call keeps an end before the controller has it: its status, already
    /// moved on while the controller's reader of ``MatrixRTCCall/statusUpdates`` waits to run, and
    /// the core's own status, ahead of the subscription.
    @Test
    func theCallSaysWhichEndTheCoreHasReached() async throws {
        let core = FakeRTCCall(status: .calling(callee: Self.callee, ring: .sending, media: .connecting))
        let call = MatrixRTCCall(rtcCall: core)
        call.start()
        #expect(call.reachedEnd == nil)
        
        core.statusSubscription.push(.ended(reason: .unanswered))
        for _ in 0..<1000 where call.status != .ended(.unanswered) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(call.reachedEnd == .unanswered)
        
        let ahead = FakeRTCCall(status: .connected(sinceMs: 0, degraded: false))
        let aheadCall = MatrixRTCCall(rtcCall: ahead)
        ahead.reach(.ended(reason: .slotClosed))
        #expect(aheadCall.status == .connected(since: Date(timeIntervalSince1970: 0), isDegraded: false))
        #expect(aheadCall.reachedEnd == .slotClosed)
        call.stop()
    }
    
    // MARK: - Nothing more (R14)
    
    @Test
    func minimizingRebuildingAndRestartingReportNothingMore() async throws {
        let fixture = Fixture(isDirect: false)
        let scripted = fixture.scriptJoin(status: connected)
        fixture.start(voiceCall)
        try await fixture.waitForOutcome()
        let count = fixture.events.count
        
        // Backgrounding. Activation would start the call's audio engine, which a test process
        // cannot, so only the deactivation is sent.
        fixture.system.send(.audioSessionDeactivated)
        fixture.controller.requestMinimize()
        fixture.controller.restore()
        // A host starting the call again on return.
        fixture.controller.startCall(voiceCall, room: fixture.room)
        // A reconnect.
        scripted.report(.connecting)
        scripted.report(connected)
        // Two screens over the controller, as a rotation or a minimize rebuilds it.
        let first = ElementCallScreenViewModel(controller: fixture.controller)
        let second = ElementCallScreenViewModel(controller: fixture.controller)
        try await Task.sleep(for: .milliseconds(200))
        withExtendedLifetime((first, second)) { }
        #expect(fixture.events.count == count)
        
        try await fixture.hangUp()
        #expect(fixture.events.filter { $0.name == "CallParticipationEnded" }.count == 1)
        #expect(fixture.events.filter { $0.name == "CallJoinAttempted" }.count == 1)
    }
    
    // MARK: - No receiver (R2)
    
    @Test
    func aCallWithoutAReceiverIsTheSameCall() async throws {
        func run(withAnalytics: Bool) async throws -> (connections: [String], requests: [ElementCallFakeSystem.Request], actions: [String]) {
            let fixture = Fixture(isDirect: true, hasAnalytics: withAnalytics)
            let scripted = fixture.scriptJoin(status: .calling(callee: Self.callee, ring: .sending, media: .connecting))
            var actions: [String] = []
            let cancellable = fixture.controller.actions.sink { actions.append("\($0)") }
            var connections = ["\(fixture.controller.connection)"]
            fixture.start(voiceCall)
            try await fixture.waitForThePublish()
            connections.append("\(fixture.controller.connection)")
            scripted.report(.calling(callee: Self.callee, ring: .sending, media: .connected(isDegraded: false)))
            try await fixture.waitUntil { fixture.controller.connection == .calling(callee: Self.callee, ring: .sending) }
            connections.append("\(fixture.controller.connection)")
            scripted.report(.ended(.declined))
            try await fixture.waitUntil { fixture.controller.connection.isFinished }
            // The system hears of the end once the decline's sound has played out: wait for it,
            // or a loaded run compares a finished call with one still ending.
            try await fixture.waitUntil(for: .seconds(15)) {
                fixture.system.requests.contains {
                    if case .end = $0 {
                        true
                    } else {
                        false
                    }
                }
            }
            connections.append("\(fixture.controller.connection)")
            cancellable.cancel()
            if withAnalytics {
                #expect(fixture.names == ["CallJoinAttempted", "CallJoinOutcome", "CallParticipationEnded"])
            }
            return (connections, fixture.system.requests, actions)
        }
        
        let with = try await run(withAnalytics: true)
        let without = try await run(withAnalytics: false)
        #expect(with.connections == without.connections)
        #expect(with.requests == without.requests)
        #expect(with.actions == without.actions)
    }
    
    // MARK: - A room that never opens (R16)
    
    @Test
    func aRoomThatNeverOpensIsAnOtherHomeserverFailure() async throws {
        let fixture = Fixture(isDirect: false)
        fixture.start(voiceCall)
        try await fixture.waitUntil(for: .seconds(30)) {
            fixture.clock.sleeperDeadlines.contains(MatrixRTCClient.seedingTimeout)
        }
        
        fixture.clock.advance(by: MatrixRTCClient.seedingTimeout)
        try await fixture.waitUntil(for: .seconds(10)) { fixture.names.count == 3 }
        
        #expect(fixture.outcomes == [.failed])
        #expect(fixture.failures == [Failure(cause: .other, phase: .joining(.homeserver, .unknown))])
        try await fixture.waitUntil { fixture.controller.connection.isFinished }
        fixture.controller.hangUp()
        fixture.expectNoIdentifiers()
    }
    
    // MARK: - Helpers
    
    private final class EndRecorder {
        var state: EndState?
    }
    
    private struct EndState: Equatable, Sendable {
        var hasCall: Bool
        var hasSystemEnd: Bool
    }
    
    private final class Fixture {
        let system = ElementCallFakeSystem()
        let permissions: ElementCallFakeMediaPermissions
        let analytics = ElementCallFakeAnalytics()
        let clock = MatrixRTCManualClock()
        let controller: ElementCallController
        let room: ElementCallFakeRoom
        let session: FakeMediaSession
        /// Whether the media is ``session``, whose publish fails, rather than the scenario player's.
        let publishesFail: Bool
        let player = MatrixRTCScenarioPlayer(scenario: MatrixRTCScenario(name: "analytics", frames: []))
        
        init(isDirect: Bool,
             microphone: ElementCallMediaPermission = .granted,
             publishError: (any Error)? = nil,
             hasAnalytics: Bool = true) {
            room = ElementCallFakeRoom(roomID: "!secretroom:secret.example.org", isDirect: isDirect)
            permissions = ElementCallFakeMediaPermissions(microphone: microphone, camera: .granted)
            session = FakeMediaSession(publishError: publishError)
            publishesFail = publishError != nil
            controller = ElementCallController(backend: ElementCallFakeMatrixBackend(userID: "@secretuser:secret.example.org", deviceID: "SECRETDEVICE"),
                                               system: system,
                                               options: ElementCallOptions(),
                                               style: .stock,
                                               logger: nil,
                                               preferences: ElementCallFakePreferencesStore(),
                                               permissions: permissions,
                                               analytics: hasAnalytics ? analytics : nil)
            controller.clock = clock
            controller.isAudioEnabled = false
        }
        
        var events: [ElementCallAnalyticsEvent] {
            analytics.events
        }
        
        var names: [String] {
            events.map(\.name)
        }
        
        var outcomes: [ElementCallAnalyticsEvent.Outcome] {
            events.compactMap(\.outcome)
        }
        
        var failures: [ElementCallAnalyticsFailure] {
            events.compactMap(\.failure)
        }
        
        /// A scripted membership with `status`, and media: the scenario player's, or one over
        /// ``session`` when a publish is to fail.
        @discardableResult
        func scriptJoin(status: MatrixRTCCallStatus) -> MatrixRTCScriptedCall {
            let scripted = MatrixRTCScriptedCall(roomID: room.roomID, status: status)
            let media = if publishesFail {
                MatrixRTCMediaSession(localMemberID: "@secretuser:secret.example.org:SECRETDEVICE",
                                      mediaSession: session,
                                      capturesCamera: false,
                                      capturesMicrophone: false)
            } else {
                player.call
            }
            let player = publishesFail ? nil : player
            controller.scriptedJoin = {
                await player?.start()
                return (scripted.call, media)
            }
            return scripted
        }
        
        /// A membership over `core`, which the test moves on directly, and the scenario player's media.
        func scriptJoin(core: FakeRTCCall) -> FakeRTCCall {
            let call = MatrixRTCCall(rtcCall: core)
            let player = player
            controller.scriptedJoin = {
                await player.start()
                return (call, player.call)
            }
            return core
        }
        
        func start(_ callData: ElementCallData) {
            controller.startCall(callData, room: room)
        }
        
        func hangUp() async throws {
            controller.hangUp()
            try await waitUntil { controller.connection.isFinished }
        }
        
        /// Until the controller has told the reporter the microphone is published: the join is past
        /// it then, however loaded the run.
        func waitForThePublish() async throws {
            try await waitUntil { controller.reporter.isMicrophonePublished }
        }
        
        func waitForOutcome() async throws {
            try await waitUntil { !outcomes.isEmpty }
        }
        
        /// Steps the controller's clock through the publish failure's grace, a wait at a time.
        func advancePastTheGrace(until condition: () -> Bool) async throws {
            for _ in 0..<200 where !condition() {
                clock.advance(by: .milliseconds(50))
                try await Task.sleep(for: .milliseconds(2))
            }
            try #require(condition())
        }
        
        /// What the controller looked like as `CallParticipationEnded` was delivered.
        func recordStateAtTheEnd() -> EndRecorder {
            let seen = EndRecorder()
            analytics.onTrack = { [controller, system] event in
                guard event.name == "CallParticipationEnded" else { return }
                MainActor.assumeIsolated {
                    let hasSystemEnd = system.requests.contains {
                        if case .end = $0 {
                            true
                        } else {
                            false
                        }
                    }
                    seen.state = EndState(hasCall: controller.rtcCall != nil, hasSystemEnd: hasSystemEnd)
                }
            }
            return seen
        }
        
        /// R17, R18: nothing that identifies the user, the room or the server, and no server text.
        func expectNoIdentifiers() {
            let forbidden = ["secret", "SECRET", room.roomID, "@bob", "example.org", "@carol", "@dan", "no microphone"]
            for event in events {
                for (key, value) in event.properties {
                    guard case .string(let text) = value else { continue }
                    for word in forbidden {
                        #expect(!text.contains(word), "\(event.name).\(key) = \(text)")
                    }
                }
            }
        }
        
        func waitUntil(for timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
            let step = Duration.milliseconds(5)
            for _ in 0..<Int(timeout / step) where !condition() {
                try await Task.sleep(for: step)
            }
            try #require(condition())
        }
    }
}

private extension ElementCallConnection {
    var isFinished: Bool {
        switch self {
        case .ended, .failed: true
        default: false
        }
    }
}
