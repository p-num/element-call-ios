//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
@testable import ElementCallUI
import Testing

/// The screen's spotlight rule (spec 003 R2–R9, R20, R21, R60), on its own. The rule used to be
/// "the hero, else the head of the ranking", which is the one implementation the spec names as
/// wrong: a call small enough to see everyone has no spotlight at all.
@MainActor
struct ElementCallSpotlightTests {
    private static let threshold = ElementCallSpotlight.listenModeThreshold
    
    private func tile(_ name: String, kind: MatrixRTCTileKind = .person, isLocal: Bool = false, isHero: Bool = false, isSpeaking: Bool = false) -> ElementCallTile {
        ElementCallTile(id: MatrixRTCTileID(memberID: "@\(name):example.com:DEVICE", kind: kind),
                        userID: "@\(name):example.com",
                        displayName: name,
                        avatarURL: nil,
                        isLocal: isLocal,
                        isMicrophoneMuted: false,
                        hasVideo: kind == .screenShare,
                        isSpeaking: isSpeaking,
                        handPosition: nil,
                        isHero: isHero,
                        stats: nil)
    }
    
    private func members(_ count: Int, speaking: Set<Int> = []) -> [ElementCallTile] {
        (0..<count).map { tile("m\($0)", isSpeaking: speaking.contains($0)) }
    }
    
    private func choose(_ tiles: [ElementCallTile], shownHero: MatrixRTCTileID? = nil, lastSpeaker: MatrixRTCTileID? = nil) -> ElementCallSpotlight.Choice {
        ElementCallSpotlight.choose(tiles: [tile("me", isLocal: true)] + tiles, shownHeroID: shownHero, lastSpeakerID: lastSpeaker)
    }
    
    // MARK: - No hero
    
    /// R3, R5: at the threshold every tile is the same size; one more and the call is in listen
    /// mode. No margin on either side of the line.
    @Test
    func atTheThresholdThereIsNoSpotlightAndOneAboveItThereIs() {
        #expect(choose(members(Self.threshold, speaking: [3])) == .none)
        let eleven = members(Self.threshold + 1, speaking: [3])
        #expect(choose(eleven) == .speaker(eleven[3].id))
    }
    
    /// R4: a screen share is a tile, not a member, and does not count towards the threshold. A
    /// share that is not a hero is not something the model publishes today; it is the only way to
    /// pin the count without a hero taking the answer first.
    @Test
    func screenSharesDoNotCountTowardsTheThreshold() {
        let atThreshold = members(Self.threshold, speaking: [0]) + [tile("s", kind: .screenShare)]
        #expect(choose(atThreshold) == .none)
    }
    
    /// R6: the first tile in the model's order that is marked speaking, not the loudest and not
    /// the head of the ranking.
    @Test
    func inListenModeTheSpotlightIsTheFirstSpeakingTileInOrder() {
        let tiles = members(Self.threshold + 2, speaking: [4, 1, 7])
        #expect(choose(tiles) == .speaker(tiles[1].id))
    }
    
    /// R7: silence keeps the last speaker; it does not empty the slot and does not promote the
    /// head of the ranking.
    @Test
    func whileNobodySpeaksTheLastSpeakerIsHeld() {
        let tiles = members(Self.threshold + 1)
        #expect(choose(tiles, lastSpeaker: tiles[5].id) == .speaker(tiles[5].id))
        #expect(choose(tiles) == .none, "nobody has spoken yet")
    }
    
    /// The held speaker leaving drops the spotlight rather than handing it to whoever is first.
    @Test
    func aHeldSpeakerWhoLeavesIsDroppedNotReplaced() {
        let tiles = members(Self.threshold + 1)
        let gone = tile("gone")
        #expect(choose(tiles, lastSpeaker: gone.id) == .none)
    }
    
    /// R3 on the way down: the call shrinking to the threshold ends listen mode at once, held
    /// speaker or not.
    @Test
    func shrinkingToTheThresholdEndsListenModeEvenWithAHeldSpeaker() {
        let tiles = members(Self.threshold)
        #expect(choose(tiles, lastSpeaker: tiles[2].id) == .none)
    }
    
    // MARK: - Heroes
    
    /// R9: a hero wins over the speaker, however loud; and R2, ourselves never, whatever we are.
    @Test
    func aHeroWinsOverTheSpeakerAndWeAreNeverChosen() {
        let share = tile("frank", kind: .screenShare, isHero: true)
        let tiles = [share] + members(Self.threshold + 1, speaking: [0])
        #expect(choose(tiles, lastSpeaker: tiles[1].id) == .hero(share.id))
        
        let us = tile("me", isLocal: true, isHero: true, isSpeaking: true)
        #expect(ElementCallSpotlight.choose(tiles: [us] + members(Self.threshold + 1), shownHeroID: us.id, lastSpeakerID: us.id) == .none)
    }
    
    /// R20, R21: the first hero by default; a hero arriving ahead of the shown one does not change
    /// what is shown, because the shown one is followed by identity rather than by position.
    @Test
    func theShownHeroIsFollowedByIdentityAsTheStackChanges() {
        let a = tile("a", kind: .screenShare, isHero: true)
        let m = tile("m", kind: .screenShare, isHero: true)
        #expect(choose([a, m] + members(3)) == .hero(a.id))
        #expect(choose([a, m] + members(3), shownHero: m.id) == .hero(m.id))
        #expect(choose([m, a] + members(3), shownHero: m.id) == .hero(m.id), "reordered underneath, still M")
        #expect(ElementCallSpotlight.heroes(in: [tile("me", isLocal: true), m, a]) == [m.id, a.id])
    }
    
    /// R60: the shown hero leaving shows the next one; with none left the slot goes away, or shows
    /// the speaker when the call is in listen mode.
    @Test
    func whenTheShownHeroLeavesTheNextHeroIsShownAndThenTheSpeaker() {
        let a = tile("a", kind: .screenShare, isHero: true)
        let m = tile("m", kind: .screenShare, isHero: true)
        #expect(choose([a] + members(3), shownHero: m.id) == .hero(a.id))
        #expect(choose(members(3), shownHero: m.id) == .none)
        let crowd = members(Self.threshold + 1, speaking: [2])
        #expect(choose(crowd, shownHero: m.id) == .speaker(crowd[2].id))
    }
}
