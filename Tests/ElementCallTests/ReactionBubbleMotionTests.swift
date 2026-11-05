//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallUI
import SwiftUI
import Testing

/// The bubble's flight, as a function of time (037 R1a, R2, R3, R21).
nonisolated struct ReactionBubbleMotionTests {
    private let portrait = CGSize(width: 402, height: 874)
    private let landscape = CGSize(width: 874, height: 402)
    
    private func frame(_ motion: ElementCallReactionBubbleMotion, at milliseconds: Int, in stage: CGSize? = nil) -> ElementCallReactionBubbleMotion.Frame {
        motion.frame(at: .milliseconds(milliseconds), in: stage ?? portrait)
    }
    
    @Test
    func itRisesFromBelowTheBottomToPastTheTop() {
        let motion = ElementCallReactionBubbleMotion(seed: 1)
        #expect(frame(motion, at: 0).center.y > portrait.height)
        #expect(frame(motion, at: 4000).center.y < 0)
    }
    
    /// R3: fastest at first.
    @Test
    func theFirstThirdCoversMoreThanTheLast() {
        let motion = ElementCallReactionBubbleMotion(seed: 2)
        let start = frame(motion, at: 0).center.y
        let firstThird = start - frame(motion, at: 1333).center.y
        let lastThird = frame(motion, at: 2667).center.y - frame(motion, at: 4000).center.y
        #expect(firstThird > 3 * lastThird)
    }
    
    /// R3: smaller at first, full size by a third of the way up, then no bigger.
    @Test
    func itIsFullSizeByAThirdOfTheWayUp() {
        let motion = ElementCallReactionBubbleMotion(seed: 3)
        let full = ElementCallReactionBubbleMotion.size(in: portrait)
        #expect(abs(frame(motion, at: 0).scale - full * ElementCallReactionBubbleMotion.startScale) < 0.001)
        // A third of the way up is reached at about 18 % of the flight on this curve.
        let atAThird = (0...4000).first { ElementCallReactionBubbleMotion.rise(at: CGFloat($0) / 4000) >= 1.0 / 3 } ?? 0
        #expect(abs(frame(motion, at: atAThird + 1).scale - full) < 0.001)
        #expect(abs(frame(motion, at: 3000).scale - full) < 0.001)
    }
    
    /// R2: clear of the edges, and the sway stays a sway.
    @Test(arguments: 1...200)
    func itStaysClearOfTheEdges(seed: UInt64) {
        let motion = ElementCallReactionBubbleMotion(seed: seed)
        #expect((0.1...0.9).contains(motion.startX))
        for milliseconds in stride(from: 0, through: 4000, by: 100) {
            let x = frame(motion, at: milliseconds).center.x
            #expect(abs(x - motion.startX * portrait.width) <= 0.03 * portrait.width + 0.001)
        }
    }
    
    @Test
    func oneSeedOnePath() {
        let first = ElementCallReactionBubbleMotion(seed: 42)
        let second = ElementCallReactionBubbleMotion(seed: 42)
        #expect(frame(first, at: 1234) == frame(second, at: 1234))
        #expect(frame(first, at: 1234) != frame(ElementCallReactionBubbleMotion(seed: 43), at: 1234))
    }
    
    /// R1a: fully visible until three seconds from arrival, gone by four, both less the spread.
    @Test
    func itFadesAfterThreeSecondsAndIsGoneByFour() {
        let motion = ElementCallReactionBubbleMotion(seed: 5)
        #expect(frame(motion, at: 0).opacity == 0)
        #expect(frame(motion, at: 2999).opacity == 1)
        #expect((0..<1).contains(frame(motion, at: 3500).opacity))
        #expect(frame(motion, at: 4000).opacity == 0)
        
        let waited = ElementCallReactionBubbleMotion(seed: 5, spread: .milliseconds(400))
        #expect(waited.lifetime == .milliseconds(3600))
        #expect(frame(waited, at: 2599).opacity == 1)
        #expect(frame(waited, at: 3600).opacity == 0)
    }
    
    /// R21: the same flight, smaller, on a landscape stage.
    @Test
    func itIsSmallerInLandscape() {
        let motion = ElementCallReactionBubbleMotion(seed: 6)
        #expect(frame(motion, at: 2000, in: landscape).scale < frame(motion, at: 2000).scale)
        #expect(frame(motion, at: 0, in: landscape).center.y > landscape.height)
        #expect(frame(motion, at: 4000, in: landscape).center.y < 0)
    }
    
    /// The fallback's stand-in for glass flexing: it keeps going all the way up, stays a few percent
    /// either way, and never stretches both ways at once, which would be a pulse rather than a flex.
    @Test(arguments: 1...20)
    func theRoundWobblesAllTheWayUp(seed: UInt64) {
        let motion = ElementCallReactionBubbleMotion(seed: seed)
        let wobbles = stride(from: 0, through: 3900, by: 20).map { frame(motion, at: $0).wobble }
        let amplitude = ElementCallReactionBubbleMotion.wobbleAmplitude
        for wobble in wobbles {
            #expect(abs(wobble.width - 1) <= amplitude + 1e-9 && abs(wobble.height - 1) <= amplitude + 1e-9)
        }
        let lastSecond = wobbles.suffix(50).map(\.width)
        #expect((lastSecond.max() ?? 1) - (lastSecond.min() ?? 1) > amplitude, "Still flexing near the top.")
        #expect(!wobbles.contains { $0.width > 1 + amplitude * 0.9 && $0.height > 1 + amplitude * 0.9 })
    }
}
