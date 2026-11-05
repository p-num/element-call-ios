//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallUI
import Foundation
import Testing

/// Which reactions the overlay sends up: the cap, reduced motion, and nothing late (037 R2a, R6, R8).
@Suite("Reaction flights")
struct ReactionFlightsTests {
    private let now = Date(timeIntervalSinceReferenceDate: 0)
    
    private func reactions(_ ids: ClosedRange<UInt64>) -> [ElementCallReactionBubble] {
        ids.map { ElementCallReactionBubble(id: $0, emoji: "👏", senderName: "Bob", spread: .zero) }
    }
    
    @Test
    func eachNewReactionRisesOnce() {
        var flights = ElementCallReactionFlights()
        #expect(flights.receive(reactions(1...2), isInitial: false, reduceMotion: false, at: now).map(\.id) == [1, 2])
        // The model publishes again with one more; only that one is new.
        #expect(flights.receive(reactions(1...3), isInitial: false, reduceMotion: false, at: now).map(\.id) == [3])
        #expect(flights.bubbles.map(\.id) == [1, 2, 3])
    }
    
    /// R8: reactions that arrived while the call was minimised are not shown on the way back, but
    /// one arriving after is.
    @Test
    func whatIsAlreadyThereWhenTheOverlayAppearsNeverRises() {
        var flights = ElementCallReactionFlights()
        #expect(flights.receive(reactions(1...3), isInitial: true, reduceMotion: false, at: now).isEmpty)
        #expect(flights.receive(reactions(1...4), isInitial: false, reduceMotion: false, at: now).map(\.id) == [4])
    }
    
    /// R6: nothing rises, and turning reduced motion off later does not release what was held back.
    @Test
    func reducedMotionSendsNothingUpAndNothingLater() {
        var flights = ElementCallReactionFlights()
        #expect(flights.receive(reactions(1...2), isInitial: false, reduceMotion: true, at: now).isEmpty)
        #expect(flights.receive(reactions(1...3), isInitial: false, reduceMotion: false, at: now).map(\.id) == [3])
    }
    
    /// R2a: past thirty, a reaction is dropped rather than queued, so a landing frees a place for the
    /// next arrival but never for the one already turned away.
    @Test
    func pastTheCapAReactionIsDroppedNotQueued() {
        let cap = UInt64(ElementCallReactionFlights.maximumBubbles)
        var flights = ElementCallReactionFlights()
        let launched = flights.receive(reactions(1...(cap + 2)), isInitial: false, reduceMotion: false, at: now)
        #expect(launched.count == ElementCallReactionFlights.maximumBubbles)
        #expect(launched.last?.id == cap)
        
        flights.land(1)
        #expect(flights.receive(reactions(1...(cap + 2)), isInitial: false, reduceMotion: false, at: now).isEmpty)
        #expect(flights.receive(reactions(1...(cap + 3)), isInitial: false, reduceMotion: false, at: now).map(\.id) == [cap + 3])
    }
    
    /// The model drops a reaction at four seconds while its bubble may still be fading out; the
    /// bubble finishes its flight rather than vanishing with the model's entry.
    @Test
    func aBubbleOutlivesItsModelEntryUntilItLands() {
        var flights = ElementCallReactionFlights()
        _ = flights.receive(reactions(1...2), isInitial: false, reduceMotion: false, at: now)
        _ = flights.receive(reactions(2...2), isInitial: false, reduceMotion: false, at: now)
        #expect(flights.bubbles.map(\.id) == [1, 2])
        flights.land(1)
        #expect(flights.bubbles.map(\.id) == [2])
    }
}
