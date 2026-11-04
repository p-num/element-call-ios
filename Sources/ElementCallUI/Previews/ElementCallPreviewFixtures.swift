//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation

/// Shared fixtures for previews, so every snapshot is built from the same people and the diffs
/// between them mean something.
///
/// Public because the example harness is built from them too, the way the port fakes are: a UI test
/// and a snapshot then describe the same Alice, Bob and Carol, and `ElementCallTile`'s memberwise
/// initialiser is internal, so there is no other way to make one from outside.
public enum ElementCallPreviewFixtures {
    public static func tile(_ name: String,
                            kind: MatrixRTCTileKind = .person,
                            isLocal: Bool = false,
                            isMuted: Bool = false,
                            hasVideo: Bool = false,
                            isHero: Bool = false,
                            isSpeaking: Bool = false,
                            handPosition: Int? = nil,
                            stats: String? = nil) -> ElementCallTile {
        let user = "@\(name.lowercased()):example.com"
        return ElementCallTile(id: MatrixRTCTileID(memberID: "\(user):DEVICE", kind: kind),
                               userID: user,
                               displayName: isLocal ? "You" : name,
                               avatarURL: nil,
                               isLocal: isLocal,
                               isMicrophoneMuted: isMuted,
                               hasVideo: hasVideo,
                               isSpeaking: isSpeaking,
                               handPosition: handPosition,
                               isHero: isHero,
                               stats: stats)
    }
    
    /// A member's screen, which is a tile of its own beside their camera rather than a state of it.
    ///
    /// Separate from ``tile(_:kind:isLocal:isMuted:hasVideo:isHero:isSpeaking:handPosition:stats:)``
    /// so a fixture cannot build one and forget that it shares a member ID with that member's
    /// camera. That sharing is the whole of what changed, and nothing in the suite covered it.
    public static func share(_ name: String, isHero: Bool = true) -> ElementCallTile {
        tile(name, kind: .screenShare, hasVideo: true, isHero: isHero)
    }
    
    /// What the stats overlay looks like on a tile that is receiving properly, in the shape
    /// `ElementCallScreenViewModel.describe(...)` produces. Illustrative numbers: there is no call
    /// behind a fixture, so the harness cannot have real ones.
    public static let sampleStats = """
    1280x720 @ 30 fps
    asked auto
    e2ee: ok
    pkts 4821 lost 3
    frames 4802 dropped 19
    concealed 0%
    """
    
    public static let alice = tile("Alice", isLocal: true)
    public static let bob = tile("Bob", isMuted: true)
    public static let carol = tile("Carol", isSpeaking: true)
    
    /// In the model's order, which is what the stage renders: Carol is speaking, so she is the head
    /// of the ranking and so the spotlight. Ourselves at index 0, where the view model splices us.
    public static let group = [alice, carol, bob, tile("Dan"), tile("Erin"), tile("Frank"), tile("Grace"), tile("Heidi")]
    
    /// The one fixture with a member on two tiles: Frank's screen is the hero and his camera is
    /// still in the strip. Every member-keyed thing that survived the migration is wrong on this
    /// array — the accessibility identifier, the released set, the `ForEach` identity, the Picture
    /// in Picture source view.
    public static let sharingGroup = [alice, share("Frank"), tile("Frank", hasVideo: true), carol, bob, tile("Dan")]
    
    /// More than ten remote members and nobody a hero: "few talk, many listen", the speaker in the
    /// spotlight and everyone else in a grid that scrolls under it.
    public static let listenModeGroup = group + ["Ivan", "Judy", "Ken", "Liam"].map { tile($0) }
    
    /// Two heroes: the spotlight stacks them and shows one, with a pill and dots to say which.
    public static let twoSharesGroup = [alice, share("Frank"), share("Grace"), tile("Frank", hasVideo: true), carol, bob, tile("Dan"), tile("Grace")]
    
    /// No call object exists in a preview, so `hasVideo` here only changes the badges, not the
    /// picture: a tile with nothing to draw falls back to its avatar.
    public static func connected(tiles: [ElementCallTile],
                                 isDirect: Bool = false,
                                 isMicrophoneMuted: Bool = false,
                                 isScreenSharing: Bool = false,
                                 isTileStatsVisible: Bool = false,
                                 isScreenSharingEnabled: Bool = false,
                                 audioOutputs: [CallAudioOutput] = phoneAudioOutputs) -> ElementCallScreenViewState {
        var state = ElementCallScreenViewState(roomName: "Product | Lobby")
        state.isDirect = isDirect
        state.connection = .connected
        // Deliberately nil: the status line renders this as a live counting timer, so even a
        // fixed date produces a different image on every run. The duration is not what these
        // snapshots are for.
        state.connectedAt = nil
        // Members, not tiles: a sharer is two tiles and one person, and the badge on the spotlight
        // counts people. A real call reads this off the session's memberships.
        state.memberCount = tiles.filter { !$0.isScreenShare }.count
        state.tiles = ElementCallScreenViewState.showingHands(tiles)
        // The screen's own rule, so a preview cannot show a spotlight the app would not choose.
        state.spotlightID = ElementCallSpotlight.choose(tiles: tiles, shownHeroID: nil, lastSpeakerID: nil).tileID
        state.smallCallSpeakerID = ElementCallSmallCallLayout.speaker(tiles: tiles, held: nil)
        // The simulator has no camera, so the flip button would never be drawn or tested otherwise.
        state.canSwitchCamera = true
        state.isMicrophoneMuted = isMicrophoneMuted
        state.isScreenSharing = isScreenSharing
        state.isTileStatsVisible = isTileStatsVisible
        // The first is where a real route starts: the headset when there is one, else the earpiece.
        state.audioOutputs = audioOutputs
        state.audioOutput = audioOutputs.first
        // Developer mode on, so the previews cover the fullest top bar; the gate is pinned by
        // DeveloperModeTests rather than by an image. Screen share only where a preview asks for
        // it: with the raised hand it is a sixth control, and six do not fit along a phone's bar
        // (009 R17), so on by default every reference would show the bar clipped. A share already
        // running was enabled by the host, so it implies the flag.
        state.isDeveloperModeEnabled = true
        state.isScreenSharingEnabled = isScreenSharingEnabled || isScreenSharing
        // Connected is joined, so there is a membership to raise a hand on.
        state.isHandRaiseAvailable = true
        return state
    }
    
    /// A direct call ringing Bob (030). He is not a tile, having not joined: the screen draws his
    /// avatar from his profile, with our own tile over it once our media is up.
    public static func ringing(isAudioCall: Bool = false, isMediaUp: Bool = true) -> ElementCallScreenViewState {
        let own = tile("Alice", isLocal: true, hasVideo: !isAudioCall)
        var state = connected(tiles: isMediaUp ? [own] : [], isDirect: true)
        state.roomName = "Bob"
        state.connection = .calling(callee: bob.userID, ring: .ringing(sentAt: .distantPast, lifetime: .seconds(90)))
        state.callee = ElementCallMemberProfile(userID: bob.userID, displayName: "Bob", avatarURL: nil)
        state.isAudioCall = isAudioCall
        state.isCameraEnabled = !isAudioCall
        return state
    }
    
    /// An iPhone with nothing plugged in or paired: the control bar's audio button is a toggle.
    public static let phoneAudioOutputs: [CallAudioOutput] = [.receiver, .speaker]
    /// AirPods connected: the button is a menu, and the call starts in the AirPods.
    public static let headsetAudioOutputs: [CallAudioOutput] = [CallAudioOutput(kind: .bluetooth, id: "airpods", name: "AirPods Pro"),
                                                                .receiver,
                                                                .speaker]
    
    public static func noCall() -> MatrixRTCMediaSession? {
        nil
    }
}
