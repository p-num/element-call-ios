//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Foundation
import Testing

/// Which status sounds like what, spec 030 R23 and R25.
nonisolated struct RingingSoundPolicyTests {
    private let ringing = MatrixRTCCallStatus.calling(callee: "@bob:example.org",
                                                      ring: .ringing(sentAt: .now, lifetime: .seconds(90)),
                                                      media: .connecting)
    
    @Test
    func theRingbackPlaysOnlyOnceTheRingIsOut() {
        #expect(RingingSoundPolicy.playsRingback(ringing))
        #expect(!RingingSoundPolicy.playsRingback(.calling(callee: "@bob:example.org", ring: .sending, media: .connecting)))
        #expect(!RingingSoundPolicy.playsRingback(.connected(since: .now, isDegraded: false)))
        #expect(!RingingSoundPolicy.playsRingback(.ended(.declined)))
    }
    
    @Test
    func onlyADeclineAndATimeoutHaveAnEndSound() {
        #expect(RingingSoundPolicy.endSound(.ended(.declined)) == .declined)
        #expect(RingingSoundPolicy.endSound(.ended(.unanswered)) == .timeout)
        for reason in [MatrixRTCEndReason.left, .othersLeft, .ringNotSent, .empty, .slotClosed, .connectionClosed(message: "")] {
            #expect(RingingSoundPolicy.endSound(.ended(reason)) == nil)
        }
        #expect(RingingSoundPolicy.endSound(ringing) == nil)
    }
}
