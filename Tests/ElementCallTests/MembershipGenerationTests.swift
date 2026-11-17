//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import MatrixRtc
import Testing

@MainActor
struct MembershipGenerationTests {
    @Test
    func mapsEveryCoreIdentityKindWithoutInferringMissingGenerations() {
        let cases: [(JoinedMembership, MatrixRTCParticipationGeneration)] = [
            (membership(kind: .perJoinMemberId, timestamp: nil), .perJoinMemberID),
            (membership(kind: .perJoinMemberId, timestamp: UInt64.max), .perJoinMemberID),
            (membership(timestamp: 0), .legacy(createdTimestampMilliseconds: 0)),
            (membership(timestamp: UInt64.max), .legacy(createdTimestampMilliseconds: UInt64.max)),
            (membership(timestamp: nil), .unavailable),
            (membership(kind: .unavailable, timestamp: nil), .unavailable),
            (membership(kind: .unavailable, timestamp: 123), .unavailable)
        ]
        for (membership, expected) in cases {
            let mapped = MatrixRTCMembership(membership)
            #expect(mapped.participationGeneration == expected)
            #expect(mapped.memberID == "legacy-device-member")
            #expect(mapped.userID == "@alice:example.org")
            #expect(mapped.deviceID == "DEVICE")
            #expect(mapped.application == "m.call")
        }
    }
    
    @Test
    func stickyRefreshKeepsGenerationAndALegacyRejoinChangesIt() {
        let first = MatrixRTCMembership(membership(timestamp: 123))
        var refreshed = membership(timestamp: 123)
        refreshed.membershipEventId = "$a-new-sticky-event"
        #expect(MatrixRTCMembership(refreshed) == first)
        let rejoined = MatrixRTCMembership(membership(timestamp: 124))
        #expect(rejoined.memberID == first.memberID)
        #expect(rejoined != first)
        #expect(Set([first, MatrixRTCMembership(refreshed), rejoined]).count == 2)
    }
    
    @Test
    func independentObserversReceiveGenerationChangesIncludingEmptySnapshots() async {
        let call = MatrixRTCCall(rtcCall: FakeRTCCall())
        var first = call.membershipSnapshots().makeAsyncIterator()
        var second = call.membershipSnapshots().makeAsyncIterator()
        #expect(await first.next() == [])
        #expect(await second.next() == [])
        let joined = [MatrixRTCMembership(membership(timestamp: 123))]
        let rejoined = [MatrixRTCMembership(membership(timestamp: 124))]
        call.updateMembers(joined)
        call.updateMembers(rejoined)
        call.updateMembers([])
        call.stop()
        for expected in [joined, rejoined, []] {
            #expect(await first.next() == expected)
            #expect(await second.next() == expected)
        }
        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
    }
    
    private func membership(kind: FfiMembershipIdentityKind = .legacyMembershipTimestamp, timestamp: UInt64?) -> JoinedMembership {
        JoinedMembership(roomId: "!room:example.org", slotId: "m.call#room", sender: "@alice:example.org",
                         senderDeviceId: "DEVICE", stickyKey: "sticky-key", memberId: "legacy-device-member",
                         membershipEventId: "$original-event", membershipTs: timestamp, identityKind: kind,
                         application: "m.call", transports: [], canSubscribe: [])
    }
}
