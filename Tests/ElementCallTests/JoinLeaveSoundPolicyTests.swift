//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Testing

/// What spec 024 leaves to the platforms once the core has said who joined or left: the cap and the
/// throttle. Which changes are announced at all (R1, R2, R6, R7, R8) is the core's and tested there.
nonisolated struct JoinLeaveSoundPolicyTests {
    private func ms(_ value: Int) -> Duration {
        .milliseconds(value)
    }
    
    @Test
    func theCapIsOnTheCountAfterTheChange() {
        // R4: with a cap of 8, a leave from 9 to 8 plays and a join from 8 to 9 does not.
        var policy = JoinLeaveSoundPolicy(participantCap: 8)
        let played = [
            policy.shouldPlay(.join, participantCount: 9, at: ms(0)),
            policy.shouldPlay(.leave, participantCount: 8, at: ms(0)),
            policy.shouldPlay(.join, participantCount: 8, at: ms(1000))
        ]
        #expect(played == [false, true, true])
    }
    
    @Test
    func aBurstOfOneKindPlaysOnce() {
        // R5: within 500 ms of a join sound starting, further joins play nothing, and are not queued.
        var policy = JoinLeaveSoundPolicy(participantCap: 8)
        let played = [
            policy.shouldPlay(.join, participantCount: 3, at: ms(0)),
            policy.shouldPlay(.join, participantCount: 4, at: ms(0)),
            policy.shouldPlay(.join, participantCount: 5, at: ms(300)),
            policy.shouldPlay(.join, participantCount: 6, at: ms(600))
        ]
        #expect(played == [true, false, false, true])
    }
    
    @Test
    func joinsAndLeavesAreThrottledSeparately() {
        // R5's example: a join and a leave 200 ms apart both play.
        var policy = JoinLeaveSoundPolicy(participantCap: 8)
        let played = [
            policy.shouldPlay(.join, participantCount: 3, at: ms(0)),
            policy.shouldPlay(.leave, participantCount: 2, at: ms(200)),
            policy.shouldPlay(.leave, participantCount: 1, at: ms(400))
        ]
        #expect(played == [true, true, false])
    }
    
    @Test
    func theWindowRunsFromTheSoundThatPlayedNotFromTheOnesThatDidNot() {
        var policy = JoinLeaveSoundPolicy(participantCap: 8)
        let played = [
            policy.shouldPlay(.join, participantCount: 3, at: ms(0)),
            policy.shouldPlay(.join, participantCount: 4, at: ms(400)),
            // 500 ms after the first, not after the suppressed one at 400.
            policy.shouldPlay(.join, participantCount: 5, at: ms(500))
        ]
        #expect(played == [true, false, true])
    }
    
    @Test
    func aCappedChangeOpensNoWindow() {
        var policy = JoinLeaveSoundPolicy(participantCap: 8)
        let played = [
            policy.shouldPlay(.join, participantCount: 9, at: ms(0)),
            policy.shouldPlay(.leave, participantCount: 8, at: ms(100)),
            policy.shouldPlay(.join, participantCount: 8, at: ms(100))
        ]
        #expect(played == [false, true, true])
    }
    
    @Test
    func silencedIsForGood() {
        // R7: teardown never sounds like people leaving.
        var policy = JoinLeaveSoundPolicy(participantCap: 8)
        policy.silence()
        let played = [CallSoundEffect.join, .leave].map { policy.shouldPlay($0, participantCount: 2, at: ms(10000)) }
        #expect(played == [false, false])
    }
}
