//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// How much of its own chrome a tile draws, which depends on where the layout has put it. One
/// parameter rather than booleans because the three are fixed combinations: nothing wants a name
/// pill without a speaker ring.
enum ElementCallTileAppearance {
    /// In the grid: rounded, named, ringed when talking. The landscape spotlight is a card too, but
    /// the speaking ring is the grid's alone (see `ElementCallTileView.outline`).
    case card
    /// The portrait spotlight, which runs edge to edge as the design draws it: the card's chrome
    /// with square corners. The landscape spotlight is inset from the sensor housing and the rail,
    /// so it stays a card.
    case spotlight
    /// Alone on the screen after a double tap: square, bare, the picture fitted rather than cropped
    /// and zoomable. Its chrome is ``ElementCallFullscreenChrome``, drawn by the screen, because
    /// keeping the name pill clear of the floating controls needs to know where those are.
    case fullscreen
    /// The other person in a one-to-one call, the whole screen behind the chrome (019 R4): square,
    /// with no name, no speaking ring and no raised hand (009 R33). Not ``fullscreen``, which
    /// would allow a zoom and be read by the screen as a tile gone full screen, taking the top bar
    /// and the control bar with it.
    case fullBleed
    /// Our own tile floating over a small call (019 R2): a smaller card.
    case floating
}

/// One participant: video (or the avatar when the camera is off), name and mic badge, the flip
/// button on the self tile, and outlines for the active speaker and a raised hand.
///
/// **Equatable on what it draws**, and the stage compares it (`.equatable()`): every scroll frame
/// re-runs the stage, and none of that is news to the thirty tiles it composes. The closures are
/// left out; for a given tile they route to the same place whichever pass made them.
struct ElementCallTileView: View, Equatable {
    @Environment(\.elementCallStyle) private var style
    let tile: ElementCallTile
    let callProvider: () -> MatrixRTCMediaSession?
    var isSpotlight = false
    var appearance: ElementCallTileAppearance = .card
    var memberCount = 0
    /// Several heroes, one shown: draws the "1 of 3" pill (R19). Only ever set on the spotlight.
    var heroStack: ElementCallStageLayout.HeroStack?
    /// The landscape spotlight: the design draws no name on it, the bar floats over its bottom
    /// edge where the name would be, and landscape is for the shared screen above all. Open
    /// question for design (hq 003 Q2); the count badge and the "1 of 3" pill stay. A small call's
    /// full-bleed tile too (019 R4), for the same reason, and our floating tile. The name is still
    /// spoken.
    var isNameHidden = false
    /// The avatar stands in so no decoder runs for it. The stage never sets it for a composed tile
    /// (a paused tile keeps its last picture); the harness and the previews use it.
    var isVideoSuspended = false
    /// How the layout asks for the picture to sit in the frame; resolved here, where its shape is
    /// known (019 R4).
    var contentFit: ElementCallTileFit = .standard
    /// Whether a double tap, or VoiceOver's action, may take this tile full screen. Not our own
    /// tile in a small call (019 R14).
    var allowsFullscreen = true
    /// The device has a camera on each side, so the flip button does something (019 R24).
    var canSwitchCamera = true
    /// Which camera our own tile shows, spoken as the flip button's value.
    var isFrontCamera = true
    /// The corner our own tile floats in, or nil when it is not floating. Spoken in its label, and
    /// the corners it is not in are offered as actions (019 R25, R26).
    var floatingCorner: ElementCallOwnTileCorner?
    /// A screen reader asked to move our floating tile: a drag does not exist for VoiceOver (R25).
    var onMoveToCorner: (ElementCallOwnTileCorner) -> Void = { _ in }
    /// The picture's upright width over height once a frame lands, for a layout that takes its
    /// shape from it (019 R10, R29). Left out of `==`, like the other closures.
    var onContentAspectChange: (CGFloat?) -> Void = { _ in }
    /// Double tap: in and out of full screen. Defaulted so the previews need not name it, and ahead
    /// of `onAction` rather than after it because that one is the trailing closure at every call
    /// site: a closure declared after it silently becomes the one a trailing closure binds to.
    var onToggleFullscreen: () -> Void = { }
    /// Single tap: raises and lowers the chrome, the full-screen one or the stage's.
    var onToggleChrome: () -> Void = { }
    let onAction: (ElementCallScreenViewAction) -> Void
    
    /// Committed by the end of a gesture; the in-flight part is separate so a cancelled pinch
    /// unwinds itself rather than leaving the picture stranded halfway.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero
    /// The tile in points, for turning a finger's travel into the fraction of the surface the
    /// renderer's pan is expressed in.
    @State private var size: CGSize = .zero
    /// Upright width over height of the picture, once one has been drawn. Without it a pan can only
    /// be clamped as though the picture filled the tile, which over-runs on the letterboxed axis.
    @State private var contentAspect: CGFloat?
    
    private var isFullscreen: Bool {
        appearance == .fullscreen
    }
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tile == rhs.tile
            && lhs.isSpotlight == rhs.isSpotlight
            && lhs.appearance == rhs.appearance
            && lhs.memberCount == rhs.memberCount
            && lhs.heroStack == rhs.heroStack
            && lhs.isNameHidden == rhs.isNameHidden
            && lhs.isVideoSuspended == rhs.isVideoSuspended
            && lhs.contentFit == rhs.contentFit
            && lhs.allowsFullscreen == rhs.allowsFullscreen
            && lhs.canSwitchCamera == rhs.canSwitchCamera
            && lhs.isFrontCamera == rhs.isFrontCamera
            && lhs.floatingCorner == rhs.floatingCorner
    }
    
    /// How far a camera picture in the spotlight is fitted rather than filled (003 R16): it fills
    /// the slot width and a portrait picture is cropped top and bottom within a bounded amount
    /// rather than filled outright. The spec leaves the amount open; this is the value proposed
    /// back to it, and the alternative — plain fill — is the spec's named wrong implementation.
    /// A value on the fit continuum rather than a mode, so it animates across a promotion.
    static let spotlightCameraFit: CGFloat = 0.5
    
    /// The design's avatar on a grid tile.
    static let gridAvatarDiameter: CGFloat = 52
    /// The design's avatar on a tile that fills the stage or a slot of its own: the spotlight, full
    /// screen and a one-to-one call. The ringing avatar is drawn at it too, so the change to the call
    /// at the pickup is one avatar handing over to an identical one (030 R21).
    static let largeAvatarDiameter: CGFloat = 140
    
    private var cornerRadius: CGFloat {
        switch appearance {
        case .fullscreen, .spotlight, .fullBleed: 0
        case .card: 16
        case .floating: 12
        }
    }
    
    private var isLarge: Bool {
        isSpotlight || appearance == .fullscreen || appearance == .fullBleed
    }
    
    var body: some View {
        ZStack {
            // The gestures belong to the picture, and the chrome is layered over it rather than
            // inside it, so that a tap landing on the flip button is a tap on the flip button and
            // nothing else. With the whole stack behind one gesture, double-tapping that button
            // flipped the camera twice *and* went full screen.
            picture
            
            switch appearance {
            case .card, .spotlight, .fullBleed, .floating:
                cardChrome
            case .fullscreen:
                // Drawn by the screen instead, where the controls' clearance is known.
                EmptyView()
            }
            
            if let stats = tile.stats {
                VStack(spacing: 0) {
                    Spacer()
                    Text(stats)
                        .font(.system(size: 9, design: .monospaced))
                        .padding(4)
                        .background(Color.black.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 36)
                // A readout, never a target: without this it would be a dead patch across the
                // bottom of every tile where a double tap does nothing.
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay { outline }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .accessibilityElement(children: .contain)
        // The name is still spoken when it is not drawn. Our own tile says more, since it shows
        // neither name nor microphone: whether our camera is on, and where it floats (019 R26).
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.tile(tile.id))
        // A double tap is how VoiceOver activates anything at all, so the gesture is invisible to
        // it: without this the feature does not exist for anyone using it.
        .accessibilityActions {
            if allowsFullscreen {
                Button("Full screen") { onToggleFullscreen() }
            }
            if let floatingCorner {
                ForEach(Self.cornersToMoveTo(from: floatingCorner), id: \.self) { corner in
                    Button("Move to \(Self.spokenName(of: corner))") { onMoveToCorner(corner) }
                }
            }
        }
    }
    
    private var accessibilityLabel: Text {
        if tile.isLocal {
            return Text(Self.ownLabel(name: tile.displayName, hasVideo: tile.hasVideo, corner: floatingCorner))
        }
        guard isNameHidden else { return Text("") }
        return Text(tile.isScreenShare ? "\(tile.displayName) (Screen share)" : tile.displayName)
    }
    
    /// "You, camera on, bottom right": the corner only while it floats, since inline it is simply
    /// the first tile (019 R26, R27).
    static func ownLabel(name: String, hasVideo: Bool, corner: ElementCallOwnTileCorner?) -> String {
        ([name, hasVideo ? "camera on" : "camera off"] + (corner.map { [spokenName(of: $0)] } ?? [])).joined(separator: ", ")
    }
    
    /// The other three corners, in reading order (019 R25).
    static func cornersToMoveTo(from corner: ElementCallOwnTileCorner) -> [ElementCallOwnTileCorner] {
        ElementCallOwnTileCorner.allCases.filter { $0 != corner }
    }
    
    static func spokenName(of corner: ElementCallOwnTileCorner) -> String {
        switch corner {
        case .topLeft: "top left"
        case .topRight: "top right"
        case .bottomLeft: "bottom left"
        case .bottomRight: "bottom right"
        }
    }
    
    private var picture: some View {
        ZStack {
            style.theme.bgSubtleSecondary
            
            if tile.hasVideo, !isVideoSuspended {
                // The crop opens as the tile grows rather than at the moment it is told to: see
                // ``AnimatableFit``. A share is fitted at *every* size, not only when it is large:
                // the stage can put one in a strip cell now that it is a tile of its own, and
                // cropping a document to a 1.2-wide cell throws away whatever somebody is pointing
                // at. A camera still starts filled, because a centre-cropped face still reads as a
                // face and letterboxing every cell makes a grid look like a contact sheet.
                AnimatableFit(fit: fit) { fit in
                    ElementCallVideoView(memberID: tile.memberID,
                                         kind: tile.kind.videoStreamKind,
                                         isLocal: tile.isLocal,
                                         callProvider: callProvider,
                                         presentation: presentation(fit: fit),
                                         onContentSizeChange: { size in
                                             contentAspect = size.height > 0 ? size.width / size.height : nil
                                             onContentAspectChange(contentAspect)
                                         },
                                         // `hasVideo` is a claim about signalling, not about pixels.
                                         // When the two disagree the tile would be a black rectangle,
                                         // so the avatar holds the space until a frame actually lands.
                                         placeholder: { avatar })
                        // A tile slot (the spotlight in particular) keeps its view identity when the
                        // tile in it changes; without an explicit identity the renderer would stay
                        // attached to the previous tile's stream.
                        .id(tile.id)
                }
            } else {
                if appearance == .fullBleed {
                    ElementCallSoundWaves(isSpeaking: tile.isSpeaking, avatarDiameter: Self.largeAvatarDiameter)
                }
                avatar
            }
        }
        // The clip shape clips hit testing with it, so without this the corners do not answer.
        .contentShape(Rectangle())
        // Attached even where full screen is not allowed, so the tap is still this tile's and does
        // not fall through to the stage, which would toggle the chrome (019 R14, R23).
        .gesture(TapGesture(count: 2).onEnded {
            if allowsFullscreen {
                onToggleFullscreen()
            }
        })
        // Simultaneous rather than exclusive: an exclusive single tap waits out the system's
        // double-tap window, which reads as a tap that did nothing. The screen waits a shorter
        // window of its own instead, and a second tap inside it cancels the toggle (017 R16).
        .simultaneousGesture(TapGesture(count: 1).onEnded { onToggleChrome() })
        // Masked off rather than branched away: an `if` around a modifier changes the view's
        // identity, which would tear down and rebuild the video view, i.e. detach and reattach the
        // stream, every time you entered or left full screen.
        .gesture(zoomAndPan, including: isFullscreen ? .all : .subviews)
        .onChange(of: appearance) { _, appearance in
            guard appearance != .fullscreen else { return }
            zoom = 1
            pan = .zero
        }
    }
    
    // MARK: - Zoom and pan
    
    /// How far in a pinch may go, and how far past its ends a finger may drag before it springs back.
    private static let maximumZoom: CGFloat = 4
    private static let rubberBand: CGFloat = 1.2
    
    /// What the renderer is asked for, at a point on the way between filling and fitting. Only full
    /// screen zooms and pans: a cell is too small to be worth moving a picture around inside.
    private func presentation(fit: CGFloat) -> VideoPresentation {
        guard isFullscreen else { return VideoPresentation(fit: fit) }
        return VideoPresentation(fit: fit, zoom: liveZoom, pan: livePan)
    }
    
    private var liveZoom: CGFloat {
        min(max(zoom * pinch, 1 / Self.rubberBand), Self.maximumZoom * Self.rubberBand)
    }
    
    private var livePan: CGSize {
        clampedPan(CGSize(width: pan.width + drag.width / max(1, size.width),
                          height: pan.height + drag.height / max(1, size.height)),
                   zoom: liveZoom)
    }
    
    /// The pan the picture can actually take at this zoom, as the fraction of the tile the renderer
    /// expects. Clamped here as well as in the renderer so the committed value never runs past the
    /// edge: it would take the same distance of dead travel to drag back into view.
    private func clampedPan(_ pan: CGSize, zoom: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        // Without an aspect yet, assume the picture covers the tile: the honest guess, and it errs
        // towards allowing the pan the renderer will clamp rather than forbidding one it would not.
        let aspect = contentAspect ?? size.width / size.height
        let fitted = aspect > size.width / size.height
            ? CGSize(width: size.width, height: size.width / aspect)
            : CGSize(width: size.height * aspect, height: size.height)
        let overflowX = max(0, fitted.width * zoom - size.width) / 2 / size.width
        let overflowY = max(0, fitted.height * zoom - size.height) / 2 / size.height
        return CGSize(width: min(max(pan.width, -overflowX), overflowX),
                      height: min(max(pan.height, -overflowY), overflowY))
    }
    
    /// Pinch and drag together, so lifting one finger mid-zoom carries on panning from where the
    /// picture is rather than restarting from nothing. The drag needs a minimum distance or it
    /// claims the touch down and no tap ever completes.
    private var zoomAndPan: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                withAnimation(.spring(duration: 0.3)) {
                    zoom = min(max(zoom * value.magnification, 1), Self.maximumZoom)
                    pan = clampedPan(pan, zoom: zoom)
                }
            }
            .simultaneously(with: DragGesture(minimumDistance: 10)
                .updating($drag) { value, state, _ in state = value.translation }
                .onEnded { value in
                    pan = clampedPan(CGSize(width: pan.width + value.translation.width / max(1, size.width),
                                            height: pan.height + value.translation.height / max(1, size.height)),
                                     zoom: zoom)
                })
    }
    
    /// One `.full` avatar at every size, scaled to the size the design gives it, rather than
    /// `.thumbnail` in the grid. A tile changes size inside an animation, and a different view per
    /// size would be re-laid out mid-move, where a frame interpolates and a font size does not: the
    /// letter ran at its own speed beside the circle. A scale is a render transform, so the avatar
    /// moves as one picture whatever the host draws in it, and is the design's size whatever size the
    /// host draws it at.
    private var avatar: some View {
        let diameter = isLarge ? Self.largeAvatarDiameter : Self.gridAvatarDiameter
        return style.avatars.avatar(userID: tile.userID,
                                    displayName: tile.displayName,
                                    avatarURL: tile.avatarURL,
                                    size: .full)
            .scaledAvatar(to: diameter)
    }
    
    private var cardChrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if isSpotlight, memberCount > 0 {
                    badge {
                        style.icons.icon(.userProfile, size: .xSmall, relativeTo: .bodySM)
                        Text("\(memberCount)")
                    }
                }
                // The raised hand belongs to the person, and a person is their camera tile. On a
                // share as well it reads as two people with their hands up.
                if let position = tile.handPosition, !tile.isScreenShare, !isHandInNamePill {
                    ElementCallRaisedHandBadge(position: position)
                }
                Spacer()
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 4) {
                if !isNameHidden {
                    badge {
                        // A screen has no microphone of its own, and a mic glyph on both of one
                        // person's tiles reads as two people. The share glyph says what the tile
                        // is instead.
                        if tile.isScreenShare {
                            style.icons.icon(.shareScreen, size: .xSmall, relativeTo: .bodySM)
                        } else if isHandInNamePill, let position = tile.handPosition {
                            // The number between the hand and the name, as on Android (009 C9).
                            HStack(spacing: 4) {
                                style.icons.icon(.raisedHand, size: .xSmall, relativeTo: .bodySM)
                                Text("\(position)")
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(ElementCallRaisedHandBadge.spokenLabel(position: position))
                        } else {
                            style.icons.icon(tile.isMicrophoneMuted ? .micOff : .micOn, size: .xSmall, relativeTo: .bodySM)
                        }
                        // Named as well as labelled: a share can sit in a grid cell right beside
                        // its owner's camera now, so "(Screen share)" on its own no longer says
                        // whose.
                        Text(tile.isScreenShare ? "\(tile.displayName) (Screen share)" : tile.displayName)
                            .lineLimit(1)
                    }
                }
                if let heroStack {
                    badge { Text("\(heroStack.shown + 1) of \(heroStack.count)") }
                        // One element, so the identifier lands on something a test can find and
                        // VoiceOver reads the position as one phrase.
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.heroIndicator)
                }
                Spacer()
                if tile.isLocal, tile.hasVideo, canSwitchCamera {
                    switchCameraButton
                }
            }
        }
        .padding(8)
    }
    
    /// The spotlight carries a raised hand in its name pill, in the microphone's place, rather than
    /// as a disc in the corner or a ring: it is the one tile that already says who it is in the
    /// large, and the design keeps its corners clear. Only while the pill is drawn, or the hand
    /// would go with it.
    private var isHandInNamePill: Bool {
        isSpotlight && tile.hasHandRaised && !tile.isScreenShare && !isNameHidden
    }
    
    private var switchCameraButton: some View {
        Button { onAction(.switchCamera) } label: {
            style.icons.icon(.switchCamera, size: .small, relativeTo: .bodySM)
                .padding(6)
                .background(Color.black.opacity(0.5), in: Circle())
        }
        .accessibilityLabel("Switch camera")
        // Which camera is in use, so a VoiceOver user hears what the button changed, and a UI test
        // can tell a tap that reached it from one that did not (019 R22).
        .accessibilityValue(isFrontCamera ? "Front camera" : "Back camera")
    }
    
    /// Where the picture sits between filled (0) and fitted (1).
    private var fit: CGFloat {
        if isFullscreen || tile.isScreenShare {
            return 1
        }
        switch contentFit {
        case .fitWhenLandscape:
            // R4's one exception: a landscape picture on a frame taller than it is wide is shown
            // whole. Until the first frame says otherwise, it fills.
            let isLandscapePicture = (contentAspect ?? 0) > 1
            return isLandscapePicture && size.height > size.width ? 1 : 0
        case .standard:
            return isSpotlight ? Self.spotlightCameraFit : 0
        }
    }
    
    /// Inside the tile's bounds and over the picture, so a tile that starts or stops talking does not
    /// change size or move.
    @ViewBuilder
    private var outline: some View {
        // The ring and the hand belong to the person, and a person is their camera tile. Ringing a
        // sharer's screen as well puts two rings round one speaker, which reads as two people
        // talking at once.
        if tile.isScreenShare || isFullscreen {
            EmptyView()
        } else if tile.isSpeaking, appearance == .card || appearance == .floating, !isSpotlight {
            // Not the spotlight, whose position already says who is talking, nor the one other
            // person in a one-to-one call, whose picture has no edge to ring: they have sound waves
            // round their avatar instead (`ElementCallSoundWaves`). A small call's other tiles are
            // ringed like the grid's (019 R9). Speaking wins over a raised hand, which still has
            // its badge.
            ring(style.theme.activeSpeakerBorder(in: size))
        } else if tile.hasHandRaised, !isHandInNamePill {
            ring(style.theme.raisedHandBorder(in: size))
        } else if appearance == .floating {
            // With the camera off our floating tile is the same fill as the tile it overlaps.
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(style.theme.borderInteractiveSecondary, lineWidth: Self.floatingBorderWidth)
        }
    }
    
    /// The speaking and the raised-hand rings: one shape, the theme's layers drawn bottom first.
    private func ring(_ layers: [AnyShapeStyle]) -> some View {
        ZStack {
            ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(layer, lineWidth: 4)
            }
        }
    }
    
    static let floatingBorderWidth: CGFloat = 1.5
    
    private func badge(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 4) { content() }
            .font(style.theme.bodySMSemibold)
            .foregroundStyle(style.theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.5), in: Capsule())
    }
}

/// A raised hand: the design's light disc with a dark hand, lifted off the picture by a shadow
/// rather than sunk into it like the dark name pills, so it reads on any video. Shared by the tile
/// and the full-screen chrome, which draws its own.
///
/// The hand's place in the queue follows the hand, which widens the disc into a pill. Design has no
/// frame for the number; this is Android's, so a mixed call looks the same on both (009 C9).
struct ElementCallRaisedHandBadge: View {
    let position: Int
    
    @Environment(\.elementCallStyle) private var style
    
    var body: some View {
        // 28 pt high round a 20 pt icon. Padding rather than a fixed frame, so the badge grows with
        // the icon at larger text sizes.
        HStack(spacing: 2) {
            style.icons.icon(.raisedHand, size: .small, relativeTo: .bodySM)
            Text("\(position)")
                .font(style.theme.bodySMSemibold)
                .padding(.trailing, 2)
        }
        .foregroundStyle(style.theme.iconOnSolidPrimary)
        .padding(4)
        .background(style.theme.bgActionPrimaryRest, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        // A drawing alone does not exist for VoiceOver (009 R21).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(position: position))
    }
    
    static func spokenLabel(position: Int) -> String {
        "Hand raised, number \(position) in the queue"
    }
}

/// Hands its content the value an animation is currently passing through.
///
/// SwiftUI interpolates what it can see is interpolating, and a value handed across into a
/// `UIViewRepresentable` is not that: it arrives at its destination in one step. So the crop used to
/// spring from filled to fitted in a single frame at the *start* of a move the tile then took half a
/// second to finish, which read as a jolt exactly where the eye was already following something.
/// Conforming a view to `Animatable` is how you ask for the values in between; its `body` is then
/// re-evaluated per frame, which is what carries them down to the renderer.
private struct AnimatableFit<Content: View>: View, Animatable {
    var fit: CGFloat
    let content: (CGFloat) -> Content
    
    var animatableData: CGFloat {
        get { fit }
        set { fit = newValue }
    }
    
    var body: some View {
        content(fit)
    }
}

/// Draws a member's stream while on screen; attaching opens the decoder, detaching closes it
/// (after a linger). The local tile draws the camera directly.
struct ElementCallVideoView<Placeholder: View>: View {
    let memberID: String
    let kind: MatrixRTCStreamKind
    let isLocal: Bool
    let callProvider: () -> MatrixRTCMediaSession?
    var presentation: VideoPresentation = .fill
    var onContentSizeChange: (CGSize) -> Void = { _ in }
    /// Shown until the stream delivers its first frame. See ``FrameGate``.
    @ViewBuilder let placeholder: Placeholder
    
    @State private var slot = VideoFrameSlot()
    @State private var gate = FrameGate()
    /// Only ever set by the example harness. See ``ElementCallPreviewVideo``.
    @Environment(\.elementCallPreviewVideo) private var previewVideo
    
    var body: some View {
        ZStack {
            if !gate.hasFrame {
                placeholder
            }
            VideoTileView(slot: slot,
                          presentation: presentation,
                          onPixelSizeChange: { size in
                              guard !isLocal, let call = callProvider() else { return }
                              call.reportDrawnSize(size, slot: slot, memberID: memberID, kind: kind)
                          },
                          onContentSizeChange: onContentSizeChange)
                // Kept in the tree rather than branched away, so it is attached and drawing before it
                // is shown; swapping it in on the first frame would mean attaching after it.
                .opacity(gate.hasFrame ? 1 : 0)
        }
        .onAppear {
            // Wired before the call is asked for, not after: the harness feeds the same slot, and
            // with this below the guard its first frame would arrive with nothing listening and the
            // avatar would stay up over a picture that was already drawing.
            //
            // A slot reused by this tile may already hold a frame from before it went off screen.
            gate.hasFrame = slot.hasReceivedFrame
            slot.setOnFirstFrame { [gate] in
                Task { @MainActor in gate.hasFrame = true }
            }
            // The harness first, when there is one: a scripted call has a call object and no
            // pictures, so the test pattern has to win over it. Nil in every shipping build.
            if let previewVideo {
                previewVideo.attach(slot, memberID, kind)
                return
            }
            guard let call = callProvider() else { return }
            if isLocal {
                call.localVideo.attach(slot)
            } else {
                call.attachVideo(slot, memberID: memberID, kind: kind)
            }
        }
        .onDisappear {
            slot.setOnFirstFrame(nil)
            if let previewVideo {
                previewVideo.detach(slot)
                return
            }
            guard let call = callProvider() else { return }
            if isLocal {
                call.localVideo.detach(slot)
            } else {
                call.detachVideo(slot, memberID: memberID, kind: kind)
            }
        }
    }
}

/// Carries "a frame has arrived" from the offering thread to the view.
///
/// A reference type because the slot's callback is `@Sendable` and fires off the main actor: it
/// can capture this and hop, where it could not capture the view's own state.
@Observable
private final class FrameGate {
    var hasFrame = false
}

// MARK: - Previews

struct ElementCallTileView_Previews: PreviewProvider, TestablePreview {
    typealias Fixtures = ElementCallPreviewFixtures
    
    static func tileView(_ tile: ElementCallTile,
                         appearance: ElementCallTileAppearance = .card,
                         isSpotlight: Bool = false) -> some View {
        ElementCallTileView(tile: tile,
                            callProvider: Fixtures.noCall,
                            isSpotlight: isSpotlight,
                            appearance: appearance,
                            memberCount: 4) { _ in }
            .frame(width: 180, height: 240)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        tileView(Fixtures.carol)
            .previewDisplayName("Speaking")
        tileView(Fixtures.bob)
            .previewDisplayName("Muted")
        tileView(Fixtures.tile("Erin", handPosition: 1))
            .previewDisplayName("Hand raised")
        tileView(Fixtures.tile("Erin", isSpeaking: true, handPosition: 12))
            .previewDisplayName("Speaking with hand raised")
        tileView(Fixtures.share("Frank"), isSpotlight: true)
            .previewDisplayName("Screen share spotlight")
        tileView(Fixtures.tile("Dan", hasVideo: true, isSpeaking: true, handPosition: 1), isSpotlight: true)
            .previewDisplayName("Spotlight with hand raised")
        // A share in an ordinary strip cell, which it could never be while a share was a flag on its
        // owner's tile that only the spotlight honoured. It is fitted rather than filled at this
        // size for the same reason it is full screen: cropping a document loses what it was showing.
        tileView(Fixtures.share("Frank"))
            .previewDisplayName("Screen share in a cell")
        tileView(Fixtures.tile("Grace", stats: "640x360 @ 30 fps\nasked 640x360\ne2ee: ok\npkts 1200 lost 3"))
            .previewDisplayName("With stats")
        // Bare on purpose: its chrome is ``ElementCallFullscreenChrome``, drawn by the screen.
        tileView(Fixtures.carol, appearance: .fullscreen)
            .previewDisplayName("Full screen")
    }
}

extension View {
    /// The host's avatar scaled to `diameter`, read from the view's own geometry as it draws rather
    /// than measured into state: a measurement lands a pass late, and a one-pass render (a snapshot)
    /// never sees it.
    ///
    /// Framed at `diameter` too, because a scale draws smaller without taking less room: the host's
    /// 140 pt avatar, scaled to 52, still asked for 140 pt and pushed our 100 pt camera-off tile
    /// wider than its frame and off the screen's edge.
    func scaledAvatar(to diameter: CGFloat) -> some View {
        visualEffect { content, geometry in
            content.scaleEffect(diameter / max(1, geometry.size.width))
        }
        .frame(width: diameter, height: diameter)
    }
}
