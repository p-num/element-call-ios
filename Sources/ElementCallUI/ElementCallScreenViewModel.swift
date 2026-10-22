//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCallHost
import ElementCallKit
import SwiftUI

/// What the views read and write. Kept as a separate object from the view model so the views take
/// one observable thing and hold no reference to the call itself.
@Observable
@MainActor
public final class ElementCallScreenContext {
    public fileprivate(set) var viewState: ElementCallScreenViewState
    /// Bound by the screen, so an alert shows once and clears itself.
    public var alertInfo: ElementCallAlert?
    /// The tile filling the screen, if any. Written by the view, like `alertInfo` above and unlike
    /// everything in `viewState`: which tile you are looking at is a way of looking rather than a
    /// fact about the call, and the controller neither knows nor needs to. It could not live in
    /// `viewState` in any case, which `refresh()` rebuilds wholesale from the controller.
    ///
    /// A tile rather than a member, because a sharer is two tiles and the whole point of the gesture
    /// is that it takes you to the one you double-tapped.
    public var fullscreenTileID: MatrixRTCTileID?
    /// The hero the user swiped the spotlight to, when there are several. Here for the same reason
    /// `fullscreenTileID` is: which hero you are looking at is a way of looking rather than a fact
    /// about the call, and `refresh()` rebuilds `viewState` wholesale. Followed by identity — a hero
    /// arriving ahead of it in the stack does not change what is shown — and cleared by the view
    /// model once it is no longer a hero, so a share that stops and restarts does not jump back in
    /// front of whatever the user has moved on to.
    public var shownHeroID: MatrixRTCTileID? {
        didSet {
            // A harness has no view model to resolve it on the next refresh, so it applies the
            // one transition a swipe asks for, the way its handler applies the toggles. In hero
            // mode there is no held speaker to lose, so the rule's memory is nil here honestly.
            guard isHarness, shownHeroID != oldValue else { return }
            viewState.spotlightID = ElementCallSpotlight.choose(tiles: viewState.tiles, shownHeroID: shownHeroID, lastSpeakerID: nil).tileID
        }
    }
    
    /// The corner our own floating tile is in (019 R18, R20). A way of looking, like the tile full
    /// screen, so it lives here rather than in `viewState`: it outlives rotation, the grid and
    /// minimizing, and only the end of the call puts it back.
    public var ownTileCorner: ElementCallOwnTileCorner = .bottomRight
    
    /// Whether the full-screen chrome is up. Down to begin with, so entering full screen is the
    /// picture and nothing else, and a single tap brings the controls back.
    public var isFullscreenChromeVisible = false
    /// Whether the stage's own chrome is up, and why not (spec 017). Here for the reason the flag
    /// above is: a preview and the harness can construct the context, and nothing else.
    var stageChrome = ElementCallChromeVisibility()
    /// Asks the stage to scroll to an offset, in points from the top of the content. For a harness
    /// playing a scenario's `scroll` frames; a host never needs it. Each request carries its own
    /// identity, so asking for the same offset twice scrolls twice.
    public var scrollRequest: ElementCallScrollRequest?
    /// Colours, fonts, icons, avatars and text, all supplied by the host.
    public let style: ElementCallStyle
    
    fileprivate var handler: ((ElementCallScreenViewAction) -> Void)?
    /// Built by ``harness(state:style:onHostAction:)``: transitions are faked here, not projected.
    private var isHarness = false
    
    fileprivate init(viewState: ElementCallScreenViewState, style: ElementCallStyle) {
        self.viewState = viewState
        self.style = style
    }
    
    /// Builds a context around a state written by hand, with nothing behind it.
    ///
    /// This is the seam that makes a connected call renderable without one. The live view model
    /// needs a `MatrixRTCMediaSession` to produce tiles, and that class wraps handles from the Rust core and
    /// cannot be constructed in a test. The view state it projects into is a plain struct, so a
    /// preview skips the projection and writes the answer. Tiles claiming video draw their avatar,
    /// because there is no call to pull frames from, which is what a snapshot wants anyway.
    public static func preview(state: ElementCallScreenViewState,
                               style: ElementCallStyle = .stock) -> ElementCallScreenContext {
        ElementCallScreenContext(viewState: state, style: style)
    }
    
    /// Like ``preview(state:style:)``, but with taps wired to the state they would change.
    ///
    /// The previews want a still: one fixed state and no behaviour. The example harness wants the
    /// menu and the control bar to answer, and it has no view model to route through — a controller
    /// produces no tiles until it has actually joined, so a harness built on one could only show a
    /// spinner. So the transitions a harness can honestly fake are applied to the view state here,
    /// which is also the only place they can be: `handler` is fileprivate on purpose, so that a
    /// host cannot reach in and drive the screen behind its own view model's back.
    ///
    /// Only the reversible ones are applied here. Minimize, hang up and dismiss belong to a host —
    /// where a minimized call goes, and whether a screen is dismissed, are its decisions — so they
    /// are handed to `onHostAction` rather than faked, the same way the live view model hands them
    /// to ``ElementCallController``. That closure is notification travelling outwards, which is why
    /// it does not weaken the rule above: nothing outside has gained a way to drive the screen.
    ///
    /// Passing nil leaves them inert, which used to be the only honest answer: a harness with
    /// nowhere to return to would have been stranded on a dead screen. A harness that is a host —
    /// the example app, which has a fixture catalogue to go back to — passes a closure instead.
    public static func harness(state: ElementCallScreenViewState,
                               style: ElementCallStyle = .stock,
                               onHostAction: ((ElementCallScreenViewAction) -> Void)? = nil) -> ElementCallScreenContext {
        let context = ElementCallScreenContext(viewState: state, style: style)
        context.isHarness = true
        // Weakly, or the context owns a closure that owns the context.
        context.handler = { [weak context] action in
            guard let context else { return }
            switch action {
            case .toggleTileStats:
                let isVisible = !context.viewState.isTileStatsVisible
                context.viewState.isTileStatsVisible = isVisible
                context.viewState.tiles = context.viewState.tiles.map {
                    $0.withStats(isVisible ? ElementCallPreviewFixtures.sampleStats : nil)
                }
            case .toggleMicrophone:
                context.viewState.isMicrophoneMuted.toggle()
                context.applyLocalMedia()
            case .toggleCamera:
                context.viewState.isCameraEnabled.toggle()
                context.applyLocalMedia()
            case .switchCamera:
                context.viewState.isFrontCamera.toggle()
            case .toggleScreenShare:
                context.viewState.isScreenSharing.toggle()
            case .toggleLoudspeaker:
                let state = context.viewState
                context.viewState.audioOutput = state.isLoudspeaker ? state.audioOutputs.first { $0.kind != .speaker } ?? .receiver : .speaker
            case let .selectAudioOutput(output):
                context.viewState.audioOutput = output
            case .toggleRaisedHand:
                let isRaised = !context.viewState.isHandRaised
                context.viewState.isHandRaised = isRaised
                // Queued after every remote hand, as the harness numbers hands (009 C7).
                let position = isRaised ? 1 + context.viewState.tiles.count { !$0.isLocal && $0.hasHandRaised } : nil
                context.viewState.tiles = ElementCallScreenViewState.showingHands(context.viewState.tiles.map { $0.withHandPosition(position) })
            case .minimize, .hangUp, .dismiss:
                onHostAction?(action)
            }
        }
        return context
    }
    
    /// Our own tile follows the controls, as the live composition makes it: without this a harness
    /// camera tap lit the button and left our tile on its avatar.
    private func applyLocalMedia() {
        viewState.tiles = viewState.tiles.map {
            $0.withLocalMedia(isMicrophoneMuted: viewState.isMicrophoneMuted, hasVideo: viewState.isCameraEnabled)
        }
    }
    
    public func send(viewAction: ElementCallScreenViewAction) {
        handler?(viewAction)
    }
}

/// One request to scroll the stage. See ``ElementCallScreenContext/scrollRequest``.
public nonisolated struct ElementCallScrollRequest: Equatable, Sendable {
    public let offset: CGFloat
    public let id = UUID()
    
    public init(offset: CGFloat) {
        self.offset = offset
    }
}

/// Projects the session-scoped ``ElementCallController`` into a view state. The controller owns the
/// call; this only renders it and forwards taps.
///
/// It reads the controller directly rather than subclassing a host view-model base class, because
/// the controller is already observable and the extra indirection only made sense inside the host's
/// own architecture.
@MainActor
public final class ElementCallScreenViewModel {
    public let context: ElementCallScreenContext
    
    /// The call whose frames the tiles draw; nil until media is connected.
    public var call: MatrixRTCMediaSession? {
        controller.call
    }
    
    /// Placed behind the spotlight tile so the system can start Picture in Picture from it.
    public var pictureInPictureSourceView: UIView {
        controller.pictureInPictureSourceView
    }
    
    private let controller: ElementCallController
    private var observationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var profiles: [String: ElementCallMemberProfile] = [:]
    private var hasRequestedDismissal = false
    /// Who the spotlight showed last in listen mode, so it keeps showing them while nobody speaks
    /// rather than emptying or falling back to the head of the ranking (003 R7). Nil whenever the
    /// call is not in listen mode, which is what makes a hero appearing or the call shrinking clear
    /// it (R3, R9).
    private var lastSpeakerID: MatrixRTCTileID?
    
    public init(controller: ElementCallController) {
        self.controller = controller
        let room = controller.room
        profiles = room?.memberProfiles ?? [:]
        context = ElementCallScreenContext(viewState: .init(roomName: room?.displayName ?? "",
                                                            isDirect: room?.isDirect ?? false),
                                           style: controller.style)
        context.handler = { [weak self] action in self?.process(viewAction: action) }
        
        // Seeded here rather than in refresh() because the options are immutable for the life of
        // the controller, so this is a fact about construction, not something to re-read. It also
        // has to be true before the first render: refresh() runs inside observe()'s Task, which has
        // not happened yet when a preview or a snapshot draws, and a control gated on one of these
        // would be missing from that first frame.
        context.viewState.isDeveloperModeEnabled = controller.options.isDeveloperModeEnabled
        context.viewState.isScreenSharingEnabled = controller.options.isScreenSharingEnabled
        context.viewState.canSwitchCamera = MatrixRTCMediaSession.canSwitchCamera
        
        if let room {
            room.displayNamePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] name in self?.context.viewState.roomName = name }
                .store(in: &cancellables)
            
            room.isDirectPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isDirect in self?.context.viewState.isDirect = isDirect }
                .store(in: &cancellables)
            
            room.memberProfilesPublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] profiles in
                    self?.profiles = profiles
                    self?.refresh()
                }
                .store(in: &cancellables)
        }
        
        observe()
    }
    
    private func process(viewAction: ElementCallScreenViewAction) {
        switch viewAction {
        // Through the controller rather than the call, which does not exist yet while we are joining
        // -- and the controls are already on screen and tappable by then.
        case .toggleMicrophone:
            controller.setMicrophoneMuted(!controller.isMicrophoneMuted)
        case .toggleCamera:
            controller.setCameraEnabled(!controller.isCameraEnabled)
        case .switchCamera:
            controller.switchCamera()
        case .toggleScreenShare:
            controller.setScreenShareEnabled(!(controller.call?.isScreenSharing ?? false))
        case .toggleLoudspeaker:
            controller.setLoudspeaker(!controller.isLoudspeaker)
        case let .selectAudioOutput(output):
            controller.selectAudioOutput(output)
        case .toggleRaisedHand:
            controller.setHandRaised(!controller.isHandRaised)
        case .toggleTileStats:
            controller.toggleTileStats()
        case .minimize:
            controller.requestMinimize()
        case .hangUp:
            controller.hangUp()
        case .dismiss:
            controller.reset()
        }
    }
    
    // MARK: - Private
    
    /// Re-reads the controller's snapshot whenever anything it, or the call, publishes changes.
    private func observe() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        self.refresh()
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private func refresh() {
        var state = context.viewState
        state.connection = controller.connection
        state.connectedAt = controller.connectedAt
        state.audioOutputs = controller.audioOutputs
        state.audioOutput = controller.audioOutput
        state.isTileStatsVisible = controller.isTileStatsVisible
        state.isMaximized = controller.isMaximized
        state.memberCount = controller.rtcCall?.memberCount ?? 0
        // Above the guard below: these two are the only controls that mean anything before there is
        // a call, and without them a mute tapped while joining draws itself back unmuted.
        state.isMicrophoneMuted = controller.isMicrophoneMuted
        state.isCameraEnabled = controller.isCameraEnabled
        // The membership comes before media, so the hand is offered from the join on.
        state.isHandRaiseAvailable = controller.rtcCall != nil
        state.isHandPending = controller.isHandPending
        state.isHandRaised = controller.isHandRaised
        
        if let message = controller.errorMessage {
            context.alertInfo = ElementCallAlert(title: context.style.strings.error, message: message)
            controller.errorMessage = nil
        }
        
        guard let call = controller.call else {
            state.tiles = []
            state.spotlightID = nil
            // So the next call on a reused view model starts its speaker afresh.
            state.smallCallSpeakerID = nil
            // Only on a change: Observation notifies on every set, and this runs on every wake
            // while there is no call.
            if context.ownTileCorner != .bottomRight {
                context.ownTileCorner = .bottomRight
            }
            lastSpeakerID = nil
            controller.setSpotlightTile(nil)
            publish(state)
            // The call object is gone once the call ended, so this must come after the state is
            // published, and run on the ended transition whether or not `publish(_:)` took: a
            // second wake after the call ended carries an unchanged state, which it declines.
            if case .ended = controller.connection, !hasRequestedDismissal {
                hasRequestedDismissal = true
            }
            return
        }
        
        // A small call is laid out in join order, which the core gives below this (019 R7).
        call.setRankingThreshold(ElementCallSmallCallLayout.rankingThreshold)
        state.isFrontCamera = call.isFrontCamera
        state.isScreenSharing = call.isScreenSharing
        state.isMediaDegraded = call.isMediaDegraded
        
        state.tiles = Self.tiles(roster: call.tiles,
                                 own: call.ownTile,
                                 profiles: profiles,
                                 youLabel: context.style.strings.you,
                                 isLocalMicrophoneMuted: call.isMicrophoneMuted,
                                 localHasVideo: call.isCameraEnabled,
                                 // The flag is read before any stats, so that with the overlay down
                                 // none of them enters this method's observation access list.
                                 // `receiveStats` is rewritten every second whether anyone is looking
                                 // or not, so tracking it cost a full screen rebuild per second.
                                 stats: controller.isTileStatsVisible ? { Self.stats(for: $0, in: call) } : { _ in nil })
        // Here rather than in the tile, which cannot tell a one-to-one call's floating tile from a
        // small call's, and which would miss the full-screen badge drawn by the screen (009 R33).
        state.tiles = ElementCallScreenViewState.showingHands(state.tiles)
        
        let spotlight = ElementCallSpotlight.choose(tiles: state.tiles,
                                                    shownHeroID: context.shownHeroID,
                                                    lastSpeakerID: lastSpeakerID)
        state.spotlightID = spotlight.tileID
        lastSpeakerID = if case .speaker(let id) = spotlight {
            id
        } else {
            nil
        }
        // The speaker carried over from the last refresh is the one the rule holds.
        state.smallCallSpeakerID = ElementCallSmallCallLayout.speaker(tiles: state.tiles, held: state.smallCallSpeakerID)
        // The user's pick is followed by identity for as long as it is a hero; the moment the
        // choice lands elsewhere it is stale, and keeping it would bring that hero straight back
        // to the front if it ever returned.
        if let shown = context.shownHeroID, spotlight != .hero(shown) {
            context.shownHeroID = nil
        }
        // The window continues what the stage shows, so the controller learns it from here rather
        // than deriving its own answer from the ranking; the setter declines an equal value.
        let pictureInPicture = state.pictureInPictureTile
        controller.setSpotlightTile(pictureInPicture.id, isExact: pictureInPicture.isExact)
        
        publish(state)
    }
    
    /// Publishes a projection only when it differs from the one on screen.
    ///
    /// `Equatable` alone would not do it: Observation notifies on every set, equal or not. And
    /// `viewState` is one coarse property that every view reads through, so a wake changing nothing
    /// invalidated all of them -- the top bar's `Menu` included, under the user's finger.
    private func publish(_ state: ElementCallScreenViewState) {
        guard state != context.viewState else { return }
        context.viewState = state
    }
    
    /// The one array every downstream site reads: ourselves, then the model's ranking untouched.
    ///
    /// **Ourselves at index 0, spliced rather than kept apart.** The model publishes our own tile on
    /// its own surface, never in the ranked list — which is what makes "the spotlight is never
    /// ourselves" structural instead of three hand-written guards — but eight sites downstream read
    /// one array and a second collection buys none of them anything. Index 0 because that is where
    /// the transport roster always happened to put us, and where the recorded snapshots expect us;
    /// it was nobody's decision before and it is one now, so `ElementCallStageLayoutTests` asserts it.
    ///
    /// **The ranking is not touched.** Hero, then hands raised earliest first, then speaking, then
    /// video, then join time, damped by the model. Sorting here would fight that damping at a
    /// different period and make the strip twitch on every word.
    ///
    /// **The order, not `ranked`.** Under a declared detail window `ranked` drops every tile the
    /// window does not cover, silently: the count is wrong, the set of streams to release is
    /// computed against the wrong complement, and the grid shortens as you scroll. It compiles and
    /// passes every fixture, because every fixture has detail for everything. So the composition
    /// walks the order and builds a tile from each **reference**, with detail joined by identity
    /// where the window delivered it. A reference alone is a name and an avatar (the user ID
    /// resolves both) with nothing live: no video, not speaking, unmuted, no hand — never a blank.
    ///
    /// Static and pure so it can be tested: `refresh()` needs a live call and cannot be.
    static func tiles(roster: MatrixRTCTileRoster,
                      own: MatrixRTCTile?,
                      profiles: [String: ElementCallMemberProfile],
                      youLabel: String,
                      isLocalMicrophoneMuted: Bool,
                      localHasVideo: Bool,
                      stats: (MatrixRTCTile) -> String? = { _ in nil }) -> [ElementCallTile] {
        func tile(_ ref: MatrixRTCTileRef) -> ElementCallTile {
            if let detail = roster.detail[ref.id] {
                return tile(detail)
            }
            let profile = profiles[ref.userID]
            return ElementCallTile(id: ref.id,
                                   userID: ref.userID,
                                   displayName: profile?.displayName ?? ref.userID,
                                   avatarURL: profile?.avatarURL,
                                   isLocal: false,
                                   isMicrophoneMuted: false,
                                   hasVideo: false,
                                   isSpeaking: false,
                                   handPosition: nil,
                                   isHero: ref.isHero,
                                   stats: nil)
        }
        func tile(_ tile: MatrixRTCTile) -> ElementCallTile {
            let profile = profiles[tile.userID]
            return ElementCallTile(id: tile.id,
                                   userID: tile.userID,
                                   displayName: tile.isLocal ? youLabel : (profile?.displayName ?? tile.userID),
                                   avatarURL: profile?.avatarURL,
                                   isLocal: tile.isLocal,
                                   isMicrophoneMuted: tile.isMicrophoneMuted,
                                   hasVideo: tile.hasVideo,
                                   isSpeaking: tile.isSpeaking,
                                   handPosition: tile.handRaisedPosition,
                                   // Ours is never a hero even if something upstream said so: it is
                                   // not in the ranking, so nothing can rank it.
                                   isHero: tile.isLocal ? false : tile.isHero,
                                   stats: stats(tile))
                // Our own mute and camera come from the call, not the tile: see `withLocalMedia`.
                .withLocalMedia(isMicrophoneMuted: isLocalMicrophoneMuted, hasVideo: localHasVideo)
        }
        return (own.map { [tile($0)] } ?? []) + roster.order.map(tile)
    }
    
    /// The stats overlay's text for one tile, from everything the call knows about that stream.
    private static func stats(for tile: MatrixRTCTile, in call: MatrixRTCMediaSession) -> String? {
        describe(call.receiveStats[MatrixRTCStreamRef(tile.id)],
                 audio: tile.kind == .screenShare ? nil : call.receiveStats[MatrixRTCStreamRef(memberID: tile.memberID, kind: .microphone)],
                 kind: tile.kind,
                 encryption: call.frameEncryption[tile.memberID],
                 video: call.videoInfo(memberID: tile.memberID, kind: tile.kind.videoStreamKind),
                 requested: tile.isLocal ? nil : call.requestedVideoConstraints(memberID: tile.memberID, kind: tile.kind.videoStreamKind))
    }
    
    private static func describe(_ stats: MatrixRTCReceiveStats?,
                                 audio: MatrixRTCReceiveStats?,
                                 kind: MatrixRTCTileKind,
                                 encryption: MatrixRTCFrameEncryptionState?,
                                 video: MatrixRTCVideoInfo?,
                                 requested: MatrixRTCVideoConstraints?) -> String {
        var lines = [String]()
        if let video {
            lines.append("\(video.width)x\(video.height) @ \(video.framesPerSecond) fps")
        } else {
            lines.append("no video")
        }
        if let requested {
            if let size = requested.pixelSize, requested.isVisible {
                lines.append("asked \(Int(size.width))x\(Int(size.height))")
            } else {
                lines.append(requested.isVisible ? "asked auto" : "asked hidden")
            }
        }
        if let encryption {
            lines.append("e2ee: \(encryption)")
        }
        // This tile's own stream: the camera's or the screen's counters.
        if let stats {
            lines.append("pkts \(stats.packetsReceived) lost \(stats.packetsLost)")
            lines.append("frames \(stats.framesDecoded) dropped \(stats.framesDropped)")
        }
        // The member's microphone, on their camera tile only: "concealed" is the one number that tells
        // audio that is silent from audio that is fabricated.
        if let audio {
            var line = "mic pkts \(audio.packetsReceived) lost \(audio.packetsLost)"
            if let concealed = audio.concealedFraction {
                line += String(format: " concealed %.0f%%", concealed * 100)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
