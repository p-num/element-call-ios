//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// `@testable` for `MatrixRTCCall`'s internal initialiser and the controller's seams.
import Combine
@testable import ElementCallHost
@testable import ElementCallKit
import Foundation
import MatrixRtc
import Testing

/// What a join asks the core for, and the controller following the call's status from there:
/// connected at the core's moment rather than when our own media is up, and ended by the core
/// without leaving a second time.
@Suite("Call status")
@MainActor
struct CallStatusTests {
    private let starting = ElementCallData(isAudioCall: false, isStartingCall: true)
    
    @Test
    func onlyStartingADirectCallRings() {
        let startingAudio = ElementCallData(isAudioCall: true, isStartingCall: true)
        let joining = ElementCallData(isAudioCall: false, isStartingCall: false)
        
        #expect(ElementCallController.kind(for: starting, isDirect: true) == .direct(ring: .video))
        #expect(ElementCallController.kind(for: startingAudio, isDirect: true) == .direct(ring: .audio))
        #expect(ElementCallController.kind(for: joining, isDirect: true) == .direct(ring: nil))
        #expect(ElementCallController.kind(for: starting, isDirect: false) == .group(notify: .video))
        #expect(ElementCallController.kind(for: joining, isDirect: false) == .group(notify: nil))
    }
    
    @Test
    func theCoresStatusIsMappedToDatesAndDurations() {
        let ringing = MatrixRTCCallStatus(.calling(callee: callee, ring: .ringing(sentAtMs: 1500, lifetimeMs: 90000), media: .connected(degraded: true)))
        #expect(ringing == .calling(callee: callee,
                                    ring: .ringing(sentAt: Date(timeIntervalSince1970: 1.5), lifetime: .seconds(90)),
                                    media: .connected(isDegraded: true)))
        #expect(ringing.isDegraded)
        
        let connected = MatrixRTCCallStatus(.connected(sinceMs: 2000, degraded: false))
        #expect(connected == .connected(since: Date(timeIntervalSince1970: 2), isDegraded: false))
        #expect(!connected.isDegraded)
        
        #expect(MatrixRTCCallStatus(.ended(reason: .connectionClosed(reason: .neverConnected, message: "gone"))) == .ended(.connectionClosed(reason: .neverConnected, message: "gone")))
    }
    
    /// Our media is up while the callee's phone still rings, and none of that is connected: the
    /// timer and the system call start at the pickup (030 R20, R31).
    @Test
    func aDirectCallConnectsAtThePickupAndEndsWithoutLeavingAgain() async throws {
        let fixture = start(status: .calling(callee: callee, ring: .sending, media: .connecting))
        #expect(fixture.controller.connection == .calling(callee: callee, ring: .sending))
        
        fixture.rtcCall.statusSubscription.push(.calling(callee: callee, ring: .ringing(sentAtMs: 10000, lifetimeMs: 90000), media: .connected(degraded: false)))
        try await waitUntil { fixture.controller.connection == .calling(callee: callee, ring: .ringing(sentAt: Date(timeIntervalSince1970: 10), lifetime: .seconds(90))) }
        #expect(fixture.controller.connectedAt == nil)
        #expect(!fixture.system.requests.contains(.connected(roomID: roomID)))
        
        fixture.rtcCall.statusSubscription.push(.connected(sinceMs: 20000, degraded: false))
        try await waitUntil { fixture.controller.connection == .connected }
        #expect(fixture.controller.connectedAt == Date(timeIntervalSince1970: 20))
        
        // A reconnect keeps the call's duration and does not connect the system call twice.
        fixture.rtcCall.statusSubscription.push(.connected(sinceMs: 20000, degraded: true))
        try await waitUntil { fixture.call.status.isDegraded }
        #expect(fixture.controller.connectedAt == Date(timeIntervalSince1970: 20))
        #expect(fixture.system.requests.count { $0 == .connected(roomID: roomID) } == 1)
        
        fixture.rtcCall.statusSubscription.push(.ended(reason: .othersLeft))
        try await waitUntil { fixture.controller.connection == .ended(.othersLeft) }
        #expect(fixture.rtcCall.leaveCount == 0)
        try await waitUntil { fixture.system.requests.last == .end(roomID: roomID, reason: .remoteEnded) }
    }
    
    @Test
    func aDeclineEndsTheCallUnconnected() async throws {
        let fixture = start(status: .calling(callee: callee, ring: .sending, media: .connecting))
        
        fixture.rtcCall.statusSubscription.push(.ended(reason: .declined))
        try await waitUntil { fixture.controller.connection == .ended(.declined) }
        #expect(fixture.rtcCall.leaveCount == 0)
        #expect(!fixture.system.requests.contains(.connected(roomID: roomID)))
    }
    
    @Test
    func aGroupCallConnectsWithOurMedia() async throws {
        let fixture = start(status: .connecting)
        #expect(fixture.controller.connection == .connectingMedia)
        
        fixture.rtcCall.statusSubscription.push(.connected(sinceMs: 5000, degraded: false))
        try await waitUntil { fixture.controller.connection == .connected }
        #expect(fixture.system.requests.contains(.connected(roomID: roomID)))
    }
    
    /// The screen closes at the decline, and the call's audio, which ending the system call takes
    /// away, only once the decline's sound has played (030 R13, R25).
    @Test
    func aDeclineSoundPlaysOutBeforeTheSystemCallEnds() async throws {
        let clock = MatrixRTCManualClock()
        let fixture = start(status: .calling(callee: callee, ring: .sending, media: .connecting), clock: clock)
        
        fixture.rtcCall.statusSubscription.push(.ended(reason: .declined))
        try await waitUntil { fixture.controller.connection == .ended(.declined) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!fixture.system.requests.contains(.end(roomID: roomID, reason: .remoteEnded)))
        
        clock.advance(by: Self.endSoundLength)
        try await waitUntil { fixture.system.requests.last == .end(roomID: roomID, reason: .remoteEnded) }
    }
    
    @Test
    func hangingUpLeaves() async throws {
        let fixture = start(status: .calling(callee: callee, ring: .sending, media: .connecting))
        
        fixture.controller.hangUp()
        try await waitUntil { fixture.controller.connection == .ended(.left) }
        #expect(fixture.rtcCall.leaveCount == 1)
        // Nothing to play out, so nothing to wait for.
        try await waitUntil { fixture.system.requests.last == .end(roomID: roomID, reason: .local) }
    }
    
    /// The system hears only a hang-up as ours; the other side's ends and the call's own failures
    /// are reported as what they were (030 R32).
    @Test
    func theSystemIsToldWhoEndedTheCall() {
        #expect(ElementCallController.systemReason(for: .left) == .local)
        #expect(ElementCallController.systemReason(for: .declined) == .remoteEnded)
        #expect(ElementCallController.systemReason(for: .othersLeft) == .remoteEnded)
        #expect(ElementCallController.systemReason(for: .empty) == .remoteEnded)
        #expect(ElementCallController.systemReason(for: .slotClosed) == .remoteEnded)
        #expect(ElementCallController.systemReason(for: .unanswered) == .unanswered)
        #expect(ElementCallController.systemReason(for: .ringNotSent) == .failed)
        #expect(ElementCallController.systemReason(for: .connectionClosed(reason: .budget, message: "gone")) == .failed)
    }
    
    /// A failure we showed is ended by our own leave, and is still a failure to the system.
    @Test
    func aFailedCallIsReportedFailed() async throws {
        let fixture = start(status: .connecting)
        fixture.controller.setPreviewState(callData: starting, room: ElementCallFakeRoom(), connection: .failed(.other("Media failed")), rtcCall: fixture.call)
        
        fixture.controller.hangUp()
        try await waitUntil { fixture.system.requests.last == .end(roomID: roomID, reason: .failed) }
    }
    
    /// A lost connection is a failure the screen explains before it goes (034 R27): the host hears
    /// `.ended` only once the user closes it, and the core, which has left already, is not asked to
    /// leave again.
    @Test
    func aLostConnectionStaysOnScreenUntilClosed() async throws {
        let fixture = start(status: .connected(sinceMs: 1000, degraded: false))
        let recorder = Recorder(fixture.controller)
        
        fixture.rtcCall.statusSubscription.push(.ended(reason: .connectionClosed(reason: .budget, message: "budget spent")))
        try await waitUntil { fixture.controller.connection == .failed(.connectionLost(.budget)) }
        try await waitUntil { fixture.system.requests.last == .end(roomID: roomID, reason: .failed) }
        #expect(!recorder.sawEnded)
        #expect(fixture.rtcCall.leaveCount == 0)
        
        fixture.controller.hangUp()
        #expect(recorder.sawEnded)
        #expect(fixture.rtcCall.leaveCount == 0)
        #expect(fixture.controller.connection == .failed(.connectionLost(.budget)))
    }
    
    /// The reason is on the call screen, so a minimized call that fails comes back to show it.
    @Test
    func aMinimizedCallThatFailsIsRestored() async throws {
        let fixture = start(status: .connected(sinceMs: 1000, degraded: false))
        let recorder = Recorder(fixture.controller)
        fixture.controller.setMaximized(false)
        
        fixture.rtcCall.statusSubscription.push(.ended(reason: .connectionClosed(reason: .refused, message: "403")))
        try await waitUntil { fixture.controller.isMaximized }
        #expect(fixture.controller.connection == .failed(.connectionLost(.refused)))
        #expect(recorder.sawRestoreRequested)
    }
    
    /// Each cause has its own words, so both platforms can say the same thing for it (034 R27).
    @Test
    func everyFailureIsWordedOnItsOwn() {
        let texts = [ElementCallFailure.connectionLost(.budget), .connectionLost(.refused), .connectionLost(.neverConnected), .joinTimedOut, .joinRefused]
            .map(\.text)
        #expect(Set(texts).count == texts.count)
        #expect(ElementCallFailure.other("Media failed").text == "Media failed")
    }
    
    @Test
    func aRingNobodyAnsweredIsReportedUnanswered() async throws {
        let fixture = start(status: .calling(callee: callee, ring: .sending, media: .connecting))
        
        fixture.rtcCall.statusSubscription.push(.ended(reason: .unanswered))
        try await waitUntil { fixture.controller.connection == .ended(.unanswered) }
        // The timeout's sound is a second of silence here, on the real clock.
        try await waitUntil { fixture.system.requests.last == .end(roomID: roomID, reason: .unanswered) }
        #expect(fixture.rtcCall.leaveCount == 0)
    }
    
    // MARK: - Helpers
    
    private let roomID = "!room:example.org"
    private let callee = "@bob:example.org"
    
    /// Collected through a reference so the closure has somewhere to write that outlives the call.
    private final class Recorder {
        var actions: [ElementCallControllerAction] = []
        var cancellable: AnyCancellable?
        
        init(_ controller: ElementCallController) {
            cancellable = controller.actions.sink { [self] action in actions.append(action) }
        }
        
        var sawEnded: Bool {
            actions.contains {
                if case .ended = $0 {
                    true
                } else {
                    false
                }
            }
        }
        
        var sawRestoreRequested: Bool {
            actions.contains {
                if case .restoreRequested = $0 {
                    true
                } else {
                    false
                }
            }
        }
    }
    
    private struct Fixture {
        let controller: ElementCallController
        let system: ElementCallFakeSystem
        let rtcCall: FakeRTCCall
        let call: MatrixRTCCall
    }
    
    /// One second of silence for each end sound, so a test knows exactly how long one lasts.
    private static let endSoundLength = Duration.seconds(1)
    
    @Test
    func aStaleCoreStatusCannotEndAReplacementInTheSameRoom() async throws {
        let fixture = start(status: .connected(sinceMs: 1, degraded: false))
        let replacement = MatrixRTCCall(rtcCall: FakeRTCCall())
        fixture.controller.setPreviewState(callData: starting, room: ElementCallFakeRoom(),
                                           connection: .connected, rtcCall: replacement)
        fixture.controller.follow(replacement, roomID: roomID)
        fixture.rtcCall.statusSubscription.push(.ended(reason: .othersLeft))
        try await waitUntil { fixture.call.status == .ended(.othersLeft) }
        #expect(fixture.controller.rtcCall === replacement)
        #expect(fixture.controller.connection == .connected)
        #expect(!fixture.system.requests.contains(.end(roomID: roomID, reason: .remoteEnded)))
        fixture.call.stop()
        replacement.stop()
    }
    
    @Test
    func aQueuedCoreEndCannotEndAReplacementInTheSameRoom() async {
        let fixture = start(status: .ended(reason: .othersLeft))
        let replacement = MatrixRTCCall(rtcCall: FakeRTCCall())
        fixture.controller.setPreviewState(callData: starting, room: ElementCallFakeRoom(),
                                           connection: .connected, rtcCall: replacement)
        for _ in 0..<50 {
            await Task.yield()
        }
        #expect(fixture.controller.rtcCall === replacement)
        #expect(fixture.controller.connection == .connected)
        #expect(!fixture.system.requests.contains(.end(roomID: roomID, reason: .remoteEnded)))
        fixture.call.stop()
        replacement.stop()
    }
    
    private func start(status: FfiCallStatus, clock: any Clock<Duration> = ContinuousClock()) -> Fixture {
        let system = ElementCallFakeSystem()
        let controller = ElementCallController(backend: ElementCallFakeMatrixBackend(),
                                               system: system,
                                               options: ElementCallOptions(),
                                               style: .stock,
                                               logger: nil)
        let rtcCall = FakeRTCCall(status: status)
        let silence = [Float](repeating: 0, count: 48000)
        let audio = CallAudio(soundEffects: CallSoundEffectRenderer(join: [], leave: [], raiseHand: [], declined: silence, timeout: silence))
        let call = MatrixRTCCall(rtcCall: rtcCall, audio: audio, clock: clock)
        controller.setPreviewState(callData: starting, room: ElementCallFakeRoom(), connection: .joining, rtcCall: call)
        call.start()
        controller.follow(call, roomID: roomID)
        return Fixture(controller: controller, system: system, rtcCall: rtcCall, call: call)
    }
    
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}
