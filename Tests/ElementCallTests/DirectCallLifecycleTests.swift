//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
@testable import ElementCallKit
@testable import ElementCallUI
import Testing

@MainActor
struct DirectCallLifecycleTests {
    @Test
    func membershipObserversReceiveIndependentOrderedSnapshotsAndFinish() async {
        let call = MatrixRTCCall(rtcCall: FakeRtcCall())
        var first = call.membershipSnapshots().makeAsyncIterator()
        var second = call.membershipSnapshots().makeAsyncIterator()
        #expect(await first.next() == [])
        #expect(await second.next() == [])
        let joined = [member("me"), member("peer")]
        call.updateMembers(joined)
        call.updateMembers([])
        #expect(await first.next() == joined)
        #expect(await second.next() == joined)
        #expect(await first.next() == [])
        #expect(await second.next() == [])
        call.stop()
        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
        var afterStop = call.membershipSnapshots().makeAsyncIterator()
        #expect(await afterStop.next() == [])
        #expect(await afterStop.next() == nil)
    }
    
    @Test
    func concurrentHangupsDeliverOneDepartureAndOneDismissal() async throws {
        let core = FakeRtcCall(holdsLeave: true)
        let controller = ElementCallController.fake(connection: .connected)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: true),
                                   room: ElementCallFakeRoom(), connection: .connected, rtcCall: MatrixRTCCall(rtcCall: core))
        var dismissals = 0
        let subscription = controller.actions.sink { action in
            if case .ended = action {
                dismissals += 1
            }
        }
        controller.hangUp()
        controller.hangUp()
        try await waitUntil { core.hasPendingLeave }
        #expect(core.leaveCount == 1)
        #expect(dismissals == 0)
        core.answerLeave()
        try await waitUntil { controller.connection == .ended(.left) }
        await drain()
        #expect(dismissals == 1)
        #expect(controller.lastDeparture?.result == .confirmed)
        subscription.cancel()
    }
    
    #if targetEnvironment(simulator)
    @Test
    func initialCameraFailureIsVisibleAndKeepsAudioConnected() async {
        let controller = ElementCallController.fake(connection: .connected)
        let media = MatrixRTCMediaSession(localMemberID: "me", mediaSession: FakeMediaSession())
        controller.setPreviewState(callData: .init(isAudioCall: false, isStartingCall: true),
                                   room: ElementCallFakeRoom(), connection: .connected, call: media)
        await controller.applyCameraEnabled(true, on: media)
        #expect(controller.errorMessage?.contains("camera could not start") == true)
        #expect(controller.connection == .connected)
        #expect(!media.isCameraEnabled)
        #expect(!media.hasEnded)
        await media.disconnect()
    }
    #endif
    
    private func makeCall(isDirect: Bool = true) -> (ElementCallController, MatrixRTCCall, FakeRtcCall) {
        let controller = ElementCallController(rtcClient: MatrixRTCClient(transport: ElementCallFakeTransport(userID: "@me:example.org")),
                                               system: ElementCallFakeSystem(), options: .init(), style: .stock, logger: nil)
        let core = FakeRtcCall()
        let call = MatrixRTCCall(rtcCall: core)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: true),
                                   room: ElementCallFakeRoom(), connection: .connected, rtcCall: call)
        controller.follow(call, roomID: call.roomID)
        return (controller, call, core)
    }
    
    private func member(_ user: String, device: String = "one") -> MatrixRTCMembership {
        MatrixRTCMembership(memberID: "\(user)-\(device)", userID: "@\(user):example.org", deviceID: device, application: "m.call")
    }
    
    private func drain() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
    
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() {
                return
            }
            await Task.yield()
        }
        throw FakeRtcCall.RefusedError()
    }
}
