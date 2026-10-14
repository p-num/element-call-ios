//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit

/// Which tile gets the largest slot, decided by the screen from the model's order.
///
/// The model ranks and marks heroes; it does not choose a spotlight. The screen does, and the rule
/// is deliberately **not** "the head of the ranking": with nobody a hero and a call small enough to
/// see everyone at once there is no spotlight at all, and every tile is the same size. Promoting the
/// top-ranked tile whenever nobody shared is what shipped before this, and it is the one thing the
/// layout spec names as wrong (003 R3).
///
/// Pure and static so the rule is tested on its own; `refresh()` needs a live call and cannot be.
enum ElementCallSpotlight {
    enum Choice: Equatable {
        /// A hero, chosen by identity from the stack (R20, R21).
        case hero(MatrixRTCTileID)
        /// "Few talk, many listen": the speaker, or the last one while nobody speaks (R6, R7).
        case speaker(MatrixRTCTileID)
        case none
        
        var tileID: MatrixRTCTileID? {
            switch self {
            case .hero(let id), .speaker(let id): id
            case .none: nil
            }
        }
    }
    
    /// More remote *members* than this and the call is in listen mode. Members, not tiles: our own
    /// tile and screen-share tiles do not count (R4). The value is the spec's working one; it is
    /// crossed at once, in both directions, with no margin of our own around it (R5).
    static let listenModeThreshold = 10
    
    /// The heroes in the model's order, which is the order the stack shows them in (R20).
    static func heroes(in tiles: [ElementCallTile]) -> [MatrixRTCTileID] {
        tiles.filter { $0.isHero && !$0.isLocal }.map(\.id)
    }
    
    /// - Parameters:
    ///   - tiles: ourselves first, then the model's order, as the view model composes them.
    ///   - shownHeroID: the hero the user is looking at, if they picked one. Followed by identity,
    ///     so a hero arriving ahead of it in the stack does not change what is shown; once it is
    ///     no longer a hero the first hero is shown instead (R21, R60).
    ///   - lastSpeakerID: who the spotlight showed last in listen mode. Held while nobody is
    ///     speaking rather than falling back to the top-ranked tile (R7).
    static func choose(tiles: [ElementCallTile],
                       shownHeroID: MatrixRTCTileID?,
                       lastSpeakerID: MatrixRTCTileID?) -> Choice {
        // Never ourselves, whatever we are doing (R2): our tile is not in the ranking, and this
        // is where that stops being an accident of the splice and becomes a rule.
        let remote = tiles.filter { !$0.isLocal }
        let heroes = remote.filter(\.isHero)
        // When any hero exists the spotlight shows only heroes; the speaker is never spotlit
        // beside or instead of one (R9).
        if let shown = heroes.first(where: { $0.id == shownHeroID }) ?? heroes.first {
            return .hero(shown.id)
        }
        let members = remote.filter { !$0.isScreenShare }
        guard members.count > listenModeThreshold else { return .none }
        if let speaking = members.first(where: \.isSpeaking) {
            return .speaker(speaking.id)
        }
        // The held speaker has to still be in the call; a departed one is dropped rather than
        // replaced by the head of the ranking, so the slot empties honestly.
        if let held = members.first(where: { $0.id == lastSpeakerID }) {
            return .speaker(held.id)
        }
        return .none
    }
}
