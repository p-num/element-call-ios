//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
@testable import ElementCallKit
import ElementCallUI
import Testing

@MainActor
struct ParticipantCountTests {
    @Test(arguments: ["me", "peer"])
    func theScreenCountsThreePeopleAcrossFourDevices(duplicateUser: String) async throws {
        let call = MatrixRTCCall(rtcCall: FakeRtcCall())
        let people = [member("me"), member("peer"), member("third")]
        call.updateMembers(people + [member(duplicateUser, device: "two")])
        let controller = ElementCallController.fake(connection: .connected)
        controller.setPreviewState(callData: .init(isAudioCall: true, isStartingCall: false),
                                   room: ElementCallFakeRoom(), connection: .connected, rtcCall: call)
        let viewModel = ElementCallScreenViewModel(controller: controller)
        
        let initialCount = try await deferFulfillment(values { viewModel.context.viewState.memberCount }) { $0 > 0 }.fulfill()
        #expect(initialCount == 3)
        // Device memberships remain available for media and departure handling.
        #expect(call.members.count == 4)
        
        call.updateMembers(people)
        #expect(call.memberCount == 3)
        
        let onePersonLeft = deferFulfillment(values { viewModel.context.viewState.memberCount }) { $0 == 2 }
        call.updateMembers(Array(people.prefix(2)))
        #expect(try await onePersonLeft.fulfill() == 2)
        
        let everyoneLeft = deferFulfillment(values { viewModel.context.viewState.memberCount }) { $0 == 0 }
        call.updateMembers([])
        #expect(try await everyoneLeft.fulfill() == 0)
    }
    
    private func member(_ user: String, device: String = "one") -> MatrixRTCMembership {
        MatrixRTCMembership(memberID: "\(user)-\(device)", userID: "@\(user):example.org", deviceID: device, application: "m.call")
    }
}
