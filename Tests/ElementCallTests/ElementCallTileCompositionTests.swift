//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
@testable import ElementCallUI
import Foundation
import Testing

/// What the screen makes of the model's ranking: which tiles exist, in what order, and what the two
/// questions derived from that list answer.
///
/// None of this had a test before, because the only path to it went through `refresh()`, which needs
/// a live call. The composition is a pure function now for exactly this reason: it is where an
/// index-versus-identity mistake would produce the wrong person's mute state rather than a crash.
@MainActor
struct ElementCallTileCompositionTests {
    private let me = MatrixRTCTileID(memberID: "@alice:example.com:ME")
    
    private func tile(_ name: String, kind: MatrixRTCTileKind = .person, isLocal: Bool = false, isHero: Bool = false, isSpeaking: Bool = false) -> MatrixRTCTile {
        MatrixRTCTile(id: MatrixRTCTileID(memberID: isLocal ? me.memberID : "@\(name):example.com:DEVICE", kind: kind),
                      userID: "@\(name):example.com",
                      isLocal: isLocal,
                      isHero: isHero,
                      hasVideo: kind == .screenShare,
                      isSpeaking: isSpeaking)
    }
    
    private func compose(ranked: [MatrixRTCTile], own: MatrixRTCTile?) -> [ElementCallTile] {
        compose(roster: MatrixRTCTileRoster(ranked), own: own)
    }
    
    private func compose(roster: MatrixRTCTileRoster, own: MatrixRTCTile?) -> [ElementCallTile] {
        ElementCallScreenViewModel.tiles(roster: roster,
                                         own: own,
                                         profiles: [:],
                                         youLabel: "You",
                                         isLocalMicrophoneMuted: false,
                                         localHasVideo: false)
    }
    
    // MARK: - Composition
    
    /// The model never ranks us, so where we go is the app's decision rather than an accident of
    /// whatever the transport happened to return. First, which is where the roster always put us.
    @Test
    func theOwnTileIsFirstAndTheModelsOrderIsKeptAfterIt() {
        let ranked = [tile("carol"), tile("bob"), tile("dan")]
        let composed = compose(ranked: ranked, own: tile("alice", isLocal: true))
        #expect(composed.first?.isLocal == true)
        #expect(composed.dropFirst().map(\.id) == ranked.map(\.id))
    }
    
    /// A member publishing both is two tiles sharing one member ID — which is the case every
    /// member-keyed assumption in the app used to get wrong.
    @Test
    func aSharerBecomesTwoTilesSharingOneMemberID() {
        let composed = compose(ranked: [tile("frank", kind: .screenShare, isHero: true), tile("frank")],
                               own: tile("alice", isLocal: true))
        let franks = composed.filter { $0.memberID == "@frank:example.com:DEVICE" }
        #expect(franks.count == 2)
        #expect(Set(franks.map(\.id)).count == 2)
        #expect(franks.filter(\.isScreenShare).count == 1)
    }
    
    /// Our own tile cannot be ranked, so nothing can mark it a hero. Asserted rather than assumed
    /// because it arrives on a different surface from the list and carries the same fields.
    @Test
    func weAreNeverHeroEvenIfSomethingUpstreamSaysSo() {
        let composed = compose(ranked: [], own: tile("alice", isLocal: true, isHero: true))
        #expect(composed.first?.isHero == false)
    }
    
    /// The model publishes our mute and camera too, but ours are overridden locally: a mute tap has
    /// to reach the badge before the transport round-trips.
    @Test
    func ourOwnMuteAndCameraComeFromTheCallRatherThanTheModel() {
        let own = MatrixRTCTile(id: me, userID: "@alice:example.com", isLocal: true, hasVideo: false, isMicrophoneMuted: false)
        let composed = ElementCallScreenViewModel.tiles(roster: .empty,
                                                        own: own,
                                                        profiles: [:],
                                                        youLabel: "You",
                                                        isLocalMicrophoneMuted: true,
                                                        localHasVideo: true)
        #expect(composed.first?.isMicrophoneMuted == true)
        #expect(composed.first?.hasVideo == true)
    }
    
    // MARK: - The detail window
    
    /// Composition walks the **order**, never `ranked`: under a declared window `ranked` silently
    /// drops every tile without detail, and the grid would shorten as you scroll. A tile the window
    /// does not cover still composes, from its reference — a name and an avatar with nothing live —
    /// and the tiles the window does cover carry their detail, joined by identity rather than index.
    @Test
    func everyTileInTheOrderComposesWhetherOrNotItHasDetail() {
        let bob = tile("bob", isSpeaking: true)
        let carol = tile("carol")
        let windowed = MatrixRTCTileRoster(order: MatrixRTCTileRoster([carol, bob]).order, detail: [bob.id: bob])
        let composed = compose(roster: windowed, own: tile("alice", isLocal: true))
        #expect(composed.map(\.id) == [tile("alice", isLocal: true).id, carol.id, bob.id])
        let reference = composed[1]
        #expect(reference.displayName == "@carol:example.com")
        #expect(reference.hasVideo == false)
        #expect(reference.isSpeaking == false)
        #expect(reference.isMicrophoneMuted == false)
        #expect(reference.hasHandRaised == false)
        #expect(composed[2].isSpeaking == true, "detail is joined by identity, not by position")
    }
    
    /// A hero is a property of the reference, so a hero outside the window is still a hero: the
    /// spotlight and the stack are decided from the order, before any detail arrives.
    @Test
    func aReferenceKeepsItsHeroFlagAndItsProfile() {
        let share = tile("frank", kind: .screenShare, isHero: true)
        let windowed = MatrixRTCTileRoster(order: MatrixRTCTileRoster([share]).order, detail: [:])
        let profiles = ["@frank:example.com": ElementCallMemberProfile(userID: "@frank:example.com", displayName: "Frank", avatarURL: URL(string: "https://example.com/frank.png"))]
        let composed = ElementCallScreenViewModel.tiles(roster: windowed,
                                                        own: nil,
                                                        profiles: profiles,
                                                        youLabel: "You",
                                                        isLocalMicrophoneMuted: false,
                                                        localHasVideo: false)
        #expect(composed.first?.isHero == true)
        #expect(composed.first?.displayName == "Frank")
        #expect(composed.first?.avatarURL?.lastPathComponent == "frank.png")
    }
    
    /// A tile outside the detail window has no record, only a reference — and the reference has to
    /// be enough to draw an avatar with a name, which both resolve through the user ID. Without it
    /// an out-of-window tile is not a degraded tile but an empty one.
    @Test
    func aReferenceOutsideTheWindowStillNamesItsUser() {
        let bob = tile("bob")
        let windowed = MatrixRTCTileRoster(order: MatrixRTCTileRoster([bob, tile("carol")]).order,
                                           detail: [bob.id: bob])
        #expect(windowed.detail.count == 1)
        let outside = windowed.order.last
        #expect(outside?.id == tile("carol").id)
        #expect(outside?.userID == "@carol:example.com")
    }
}
