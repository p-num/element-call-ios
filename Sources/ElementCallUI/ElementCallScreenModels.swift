//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation

/// One tile of the call: a member's camera or a member's screen, as the model ranked it.
public nonisolated struct ElementCallTile: Identifiable, Equatable, Sendable {
    /// The member *and* the stream. A member publishing a camera and a screen share is two tiles,
    /// drawn at once, so the member alone names a person rather than a tile — and this is the
    /// `ForEach` identity, so two tiles sharing one would collapse into a single view.
    public let id: MatrixRTCTileID
    public let userID: String
    public internal(set) var displayName: String
    public internal(set) var avatarURL: URL?
    public let isLocal: Bool
    /// Cannot be heard: muted, or no microphone stream reached us at all. The badge collapses the
    /// two on purpose; the stats overlay keeps them apart, where the question is why.
    public internal(set) var isMicrophoneMuted: Bool
    /// This tile's own stream is present and unmuted. On a share tile it is the share.
    public internal(set) var hasVideo: Bool
    /// Loud enough to count as talking. A threshold crossing, not a level: nothing continuous
    /// belongs in a tile, which the whole screen is rebuilt to redraw.
    public internal(set) var isSpeaking: Bool
    /// The hand's place in the queue, as the core numbers it (009 R6); nil with the hand down, or
    /// where no hand is shown (R33).
    public internal(set) var handPosition: Int?
    /// The model marks the tile worth the largest slot — a screen share today, a pin later. It does
    /// not choose a spotlight; `ElementCallSpotlight` is where that is decided.
    public internal(set) var isHero: Bool
    public internal(set) var stats: String?
    /// Whether this tile's media is arriving and can be shown (034 R29, R33, R34).
    public internal(set) var mediaState: ElementCallTileMediaState = .live
    
    public var memberID: String {
        id.memberID
    }
    
    public var kind: MatrixRTCTileKind {
        id.kind
    }
    
    public var isScreenShare: Bool {
        id.kind == .screenShare
    }
    
    public var hasHandRaised: Bool {
        handPosition != nil
    }
    
    /// The name tag's loading indicator shows, and a remote tile draws the avatar rather than its
    /// last frame. Our own tile keeps its live preview, which is local capture (034 R34).
    public var isMediaInterrupted: Bool {
        mediaState != .live
    }
}

/// Why a tile's media is not reaching the screen, if it is not.
public nonisolated enum ElementCallTileMediaState: Equatable, Sendable {
    case live
    /// Our own tile only, until our media server is first up.
    case connecting
    /// The connection carrying it is being re-established, or nothing can reach it. On our own
    /// tile, our own media server (034 R23).
    case reconnecting
    /// It arrives, and cannot be decrypted (034 R33).
    case undecryptable
    /// Its sender's key has not reached us for long enough that the wait is not the moment around a
    /// key rotation: see ``MatrixRTCMediaSession/keysMissingAfter``.
    case keysMissing
    /// The key we hold has not decrypted it for as long: wrong, not late.
    case keyInvalid
    /// Its sender declared it unencrypted in an encrypted call, and the core refused it.
    case notEncrypted
}

/// A message the screen shows once and then forgets. Replaces the host's alert type so the package
/// does not depend on it.
public nonisolated struct ElementCallAlert: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let title: String
    public let message: String
    /// A second button beside Cancel. Nil for a message, which has OK alone.
    public let action: Action?
    
    public nonisolated enum Action: Sendable, Equatable {
        /// The camera is refused: Open settings (042 R11).
        case openSettings
    }
    
    public init(title: String, message: String, action: Action? = nil) {
        self.title = title
        self.message = message
        self.action = action
    }
}

/// `Equatable` so ``ElementCallScreenViewModel`` can decline to republish an unchanged projection.
/// Never hand-write `==` here: synthesis picks up a new member for free, and a hand-written one
/// silently stops covering the member somebody adds next -- which is the same failure as the bug
/// the conformance exists to fix.
public nonisolated struct ElementCallScreenViewState: Equatable, Sendable {
    public var roomName: String
    /// Whether the room is a direct chat. False until the room has been read.
    public var isDirect = false
    public var connection: ElementCallConnection = .idle
    /// Whether the call was started as a voice call, which the ringing screen's icon says.
    public var isAudioCall = false
    /// Whom a direct call is ringing, while it rings; resolved from the room's members, so a name
    /// may still be loading.
    public var callee: ElementCallMemberProfile?
    public var connectedAt: Date?
    public var memberCount = 0
    /// Ourselves first, then the model's ranking untouched. See ``ElementCallScreenViewModel``.
    public var tiles: [ElementCallTile] = []
    public var isMicrophoneMuted = false
    public var isCameraEnabled = false
    public var isFrontCamera = true
    public var isScreenSharing = false
    /// Everywhere the call can come out of, external hardware first. See `ElementCallController`.
    public var audioOutputs: [CallAudioOutput] = []
    public var audioOutput: CallAudioOutput?
    public var isTileStatsVisible = false
    public var isDeveloperModeEnabled = false
    /// The reactions to draw, oldest first, once each has waited out its spread (037).
    public var reactions: [ElementCallReactionBubble] = []
    /// Whether received reactions rise as bubbles, from Preferences (043 R6).
    public var showsReactions = true
    /// Whether received reactions play their sound. Shown, greyed, while ``showsReactions`` is off
    /// (043 R7).
    public var playsReactionSounds = true
    /// The format the next join uses, from Developer options (043 R11, R14).
    public var membershipFormat: MatrixRTCMembershipFormat = .roomState
    /// The codec the next join publishes video with, from Developer options (043 R15).
    public var videoCodec: MatrixRTCVideoCodec = .auto
    /// What Developer options offers for the codec: Auto, then what this device encodes (043 R15).
    public var videoCodecs: [MatrixRTCVideoCodec] = [.auto]
    /// How loud the call's sound effects play, 0 to 1 of the call's level (037 R22).
    public var soundEffectsVolume: Float = 0.5
    /// The sheet open over the call, if any. Closed by the screen when the call is minimised, enters
    /// Picture in Picture or ends, since there is no room for it there (037 R12a, 009 R27).
    public var presentedSheet: ElementCallSheet?
    public var isScreenSharingEnabled = false
    /// Our hand as the user asked for it, from our own tile, which the core moves at once and
    /// keeps there until it lands or is refused (009 R5, 034 C12).
    public var isHandRaised = false
    /// Joined: there is a membership to put a hand on.
    public var isHandRaiseAvailable = false
    /// Our homeserver answers. While it does not, the hand is disabled: a raise could not reach
    /// anyone (034 R15).
    public var isSignallingReachable = true
    /// Our own media server is being reconnected, so a share could not start (034 R15).
    public var isOwnMediaReconnecting = false
    /// What the service interruptions list shows, at most one entry per kind; empty when nothing is
    /// interrupted, which is when the indicator goes (034 R35).
    public var interruptions: [ElementCallInterruption] = []
    
    public var isRinging: Bool {
        if case .calling = connection {
            true
        } else {
            false
        }
    }
    
    /// One other person, filling the stage (019 R4). Nobody to queue behind, and no edge of the
    /// tile's own for a ring, so no hand is shown or offered (009 R33).
    public var isOneToOne: Bool {
        ElementCallSmallCallLayout.isFullBleed(tiles)
    }
    
    /// The tiles as the screen shows them: with no hands in a one-to-one call, where the hands are
    /// still up but not drawn (009 R33). Applied by the view model, the previews and the harness
    /// alike, since only the tile list says whether a call is one-to-one.
    static func showingHands(_ tiles: [ElementCallTile]) -> [ElementCallTile] {
        ElementCallSmallCallLayout.isFullBleed(tiles) ? tiles.map { $0.withHandHidden() } : tiles
    }
    
    /// Mic, camera and hang-up are never disabled by an interruption: a mute made during one holds
    /// and applies when media resumes (034 R15).
    public var isHandControlEnabled: Bool {
        isSignallingReachable
    }
    
    /// Sending needs a membership to relate the reaction to, and a homeserver to send it to.
    public var isReactionControlEnabled: Bool {
        isHandRaiseAvailable && isSignallingReachable
    }
    
    /// What this call offers beyond mic, camera, audio and hang-up, in the menu's order.
    public var extraActions: [ElementCallBarAction] {
        var actions: [ElementCallBarAction] = []
        if showsRaiseHandControl {
            actions.append(.raisedHand)
        }
        if showsReactionControl {
            actions.append(.reactions)
        }
        if isScreenSharingEnabled {
            actions.append(.screenShare)
        }
        return actions
    }
    
    /// The control before hang-up, if any. The bar keeps to five full-size controls (009 R17), so
    /// what else the call offers goes behind `…`; design found six in a row busy. A single action
    /// is its own button, since `…` over one entry is a tap for nothing.
    public var barSlot: ElementCallBarSlot? {
        let actions = extraActions
        switch actions.count {
        case 0: return nil
        case 1: return .action(actions[0])
        default: return .more
        }
    }
    
    /// While our hand is up, the bar says so and offers to lower it, since the control that raised
    /// it is behind `…` (009 R2).
    public var showsRaisedHandBanner: Bool {
        showsRaiseHandControl && isHandRaised
    }
    
    /// Reactions are for a group, under the hand's rule (009 R33): between two people a word does
    /// the same. People rather than tiles, as for the hand.
    public var showsReactionControl: Bool {
        isHandRaiseAvailable && peopleCount >= 3
    }
    
    /// Starting a share needs our media server; stopping one never does, so a share in progress can
    /// always be ended.
    public var isScreenShareControlEnabled: Bool {
        isScreenSharing || !isOwnMediaReconnecting
    }
    
    /// From three people, ourselves included: alone or one-to-one there is nobody to queue behind
    /// (009 R33). People rather than tiles, since a share is a second tile for one person. Unless
    /// our hand is already up from before: it must always be possible to lower it (009 R2).
    public var showsRaiseHandControl: Bool {
        isHandRaiseAvailable && (peopleCount >= 3 || isHandRaised)
    }
    
    /// A share is a second tile for one person, so it does not count.
    private var peopleCount: Int {
        tiles.count { !$0.isScreenShare }
    }
    
    /// False while minimized, in the bar or the system window: the tiles unmount so only the window decodes.
    public var isMaximized = true
    
    /// Which tile gets the largest slot, or nil when every tile is the same size.
    ///
    /// Stored rather than computed, because the answer has memory: which hero the user swiped to,
    /// and who spoke last while nobody is speaking. `ElementCallSpotlight` decides it in `refresh()`
    /// and this is the one copy the stage, the Picture in Picture window and the tests all read.
    /// Never ourselves, and never the head of the ranking just for being the head of it.
    public var spotlightID: MatrixRTCTileID?
    /// Who the small-call layout raises and Picture in Picture follows (019 R9, R15). Stored for the
    /// reason `spotlightID` is: it holds the last speaker through silence.
    public var smallCallSpeakerID: MatrixRTCTileID?
    /// Whether the device has a camera on each side, so the flip button means something (019 R24).
    public var canSwitchCamera = false
    
    /// The tile the Picture in Picture window continues, and whether it must be that one. In a
    /// small call it is the speaker, else the first to arrive, else ourselves, and exactly that
    /// tile (019 R15); otherwise the spotlight, with the window's own fallbacks (003 R68).
    public var pictureInPictureTile: (id: MatrixRTCTileID?, isExact: Bool) {
        guard ElementCallSmallCallLayout.applies(to: tiles) else { return (spotlightID, false) }
        return (ElementCallSmallCallLayout.pictureInPictureTile(tiles: tiles, speakerID: smallCallSpeakerID), true)
    }
    
    public var isVideoCall: Bool {
        isCameraEnabled || tiles.contains { $0.hasVideo || $0.isScreenShare }
    }
    
    public var isLoudspeaker: Bool {
        audioOutput?.kind == .speaker
    }
    
    /// With only the phone's own outputs the choice is speaker or not, and the control bar toggles;
    /// a headset, wired, Bluetooth or a car makes it a menu.
    public var hasExternalAudioOutput: Bool {
        audioOutputs.contains { !$0.isBuiltIn }
    }
}

extension ElementCallTile {
    /// A copy with a different stats string. The overlay draws when a tile carries one, so turning
    /// it on means rewriting the tiles rather than setting a flag; a live screen rebuilds them from
    /// receive statistics on every refresh, and the harness has to do the same by hand.
    func withStats(_ stats: String?) -> ElementCallTile {
        var tile = self
        tile.stats = stats
        return tile
    }
    
    /// A copy with no hand shown, whoever's tile it is; the hand is still up (009 R33).
    nonisolated func withHandHidden() -> ElementCallTile {
        var tile = self
        tile.handPosition = nil
        return tile
    }
    
    /// Our own hand, for the harness, which has no call to read it back from.
    func withHandPosition(_ handPosition: Int?) -> ElementCallTile {
        guard isLocal else { return self }
        var tile = self
        tile.handPosition = handPosition
        return tile
    }
    
    /// Our own mute and camera, taken from the controls rather than from the tile; anyone else's
    /// tile comes back unchanged. The reason is latency rather than preference: a mute tap has to
    /// reach the badge before the transport round-trips. The model publishes per-tile state
    /// immediately, but that is a promise about its own coalescing window, not about the round trip.
    /// The live composition and the harness both go through here, so a harness tap changes our
    /// tile exactly as a real one does.
    func withLocalMedia(isMicrophoneMuted: Bool, hasVideo: Bool) -> ElementCallTile {
        guard isLocal else { return self }
        var tile = self
        tile.isMicrophoneMuted = isMicrophoneMuted
        tile.hasVideo = hasVideo
        return tile
    }
}

/// A received reaction, as a bubble rising over the call (037 R1).
public nonisolated struct ElementCallReactionBubble: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let emoji: String
    /// Fixed when the bubble appears: a profile that loads, or a sender who leaves, meanwhile does
    /// not change it (037 R7a).
    public let senderName: String
    /// How long it waited before showing, which comes off its time on screen, so that every bubble
    /// is gone four seconds after its reaction arrived (037 R1a, R2b).
    public let spread: Duration
    
    public init(id: UInt64, emoji: String, senderName: String, spread: Duration = .zero) {
        self.id = id
        self.emoji = emoji
        self.senderName = senderName
        self.spread = spread
    }
}

/// What the call screen has open over it, one at a time: Preferences and More are system sheets, and
/// the reaction picker is drawn over the call by the screen itself.
/// What the control bar offers beyond its fixed four (`ElementCallScreenViewState.extraActions`).
public nonisolated enum ElementCallBarAction: Sendable, Hashable {
    case raisedHand
    case reactions
    case screenShare
}

/// What the control bar shows before hang-up (`ElementCallScreenViewState.barSlot`).
public nonisolated enum ElementCallBarSlot: Sendable, Hashable {
    /// The only extra action, as a button of its own.
    case action(ElementCallBarAction)
    /// `…`, opening the More sheet with every extra action.
    case more
}

public nonisolated enum ElementCallSheet: Sendable, Hashable, Identifiable {
    case preferences
    /// Shown only with the host's developer mode (043 R4).
    case developerOptions
    /// The bar's `…`: what else the call offers.
    case more
    case reactions
    
    public var id: Self {
        self
    }
    
    /// The settings menu's sheets, which stay open across rotation and backgrounding, as settings
    /// do; the others were opened for a moment that has passed (043 R5, 009 R27).
    public var isSettings: Bool {
        switch self {
        case .preferences, .developerOptions: true
        case .more, .reactions: false
        }
    }
}

public nonisolated enum ElementCallScreenViewAction: Sendable {
    case toggleMicrophone
    case toggleCamera
    case switchCamera
    case toggleScreenShare
    case toggleLoudspeaker
    case toggleRaisedHand
    case selectAudioOutput(CallAudioOutput)
    case toggleTileStats
    case present(ElementCallSheet)
    case dismissSheet
    case sendReaction(MatrixRTCReactionKind)
    case setShowsReactions(Bool)
    case setPlaysReactionSounds(Bool)
    case setMembershipFormat(MatrixRTCMembershipFormat)
    case setVideoCodec(MatrixRTCVideoCodec)
    case setSoundEffectsVolume(Float)
    /// The slider was let go: one short sound at the volume chosen (037 R24).
    case playSoundEffectsVolumeSample
    case minimize
    case hangUp
    case dismiss
    /// The app's page in the system Settings, for a refused microphone or camera (042 R7, R11).
    case openSettings
}
