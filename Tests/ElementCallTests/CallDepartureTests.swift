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
import Testing

@MainActor
struct CallDepartureTests {
    @Test(arguments: [true, false])
    func repeatedLeaveSharesTheOriginalPendingResult(succeeds: Bool) async throws {
        let core = FakeRtcCall(holdsLeave: true)
        let call = MatrixRTCCall(rtcCall: core)
        let first = Task { await call.leave() }
        try await waitForLeave(core)
        var secondCompleted = false
        let second = Task {
            let result = await call.leave()
            secondCompleted = true
            return result
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(!secondCompleted)
        #expect(core.leaveCount == 1)
        core.answerLeave(failingWith: succeeds ? nil : FakeRtcCall.RefusedError())
        let expected: MatrixRTCLeaveResult = succeeds ? .confirmed : .failed
        #expect(await first.value == expected)
        #expect(await second.value == expected)
        #expect(await call.leave() == expected)
        #expect(core.leaveCount == 1)
    }
    
    @Test(arguments: [true, false])
    func localEndedCarriesTheActualDepartureResult(succeeds: Bool) async throws {
        let core = FakeRtcCall(holdsLeave: true)
        let controller = ElementCallController.fake(connection: .connected)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: true),
                                   room: ElementCallFakeRoom(), connection: .connected,
                                   rtcCall: MatrixRTCCall(rtcCall: core))
        var ended = false
        let observer = controller.actions.sink { action in
            if case .ended = action {
                ended = true
            }
        }
        controller.hangUp()
        try await waitForLeave(core)
        #expect(!ended)
        #expect(controller.lastDeparture == nil)
        core.answerLeave(failingWith: succeeds ? nil : FakeRtcCall.RefusedError())
        for _ in 0..<1000 where !ended {
            await Task.yield()
        }
        #expect(ended)
        let departure = ElementCallDeparture(roomID: "!room:example.org", result: succeeds ? .confirmed : .failed)
        #expect(controller.lastDeparture == departure)
        controller.reset()
        #expect(controller.lastDeparture == departure)
        observer.cancel()
    }
    
    private func waitForLeave(_ core: FakeRtcCall) async throws {
        for _ in 0..<1000 {
            if core.hasPendingLeave {
                return
            }
            await Task.yield()
        }
        throw FakeRtcCall.RefusedError()
    }
}
