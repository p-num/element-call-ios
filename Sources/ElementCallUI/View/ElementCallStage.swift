//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// The tiles of the call, each drawn once at the rect `ElementCallStageLayout` gives it. Because a
/// tile is the same view wherever the layout puts it, every change of arrangement animates as a
/// move: the speaker's card grows into the spotlight while the old one shrinks into the grid, a
/// third person joining pulls two rows into a grid, and a rotation is the same kind of move, which
/// is why the two orientations are one set of rects and not two view hierarchies.
///
/// **One `ZStack`, real scrolling.** Every composed tile sits in one `ZStack` inside a vertical
/// `ScrollView`, positioned in content coordinates; the offset is read back into the layout, which
/// places the spotlight at it so the spotlight counter-scrolls and reads as a sticky header while
/// staying in the same stack as the tiles it is promoted from. A `LazyVGrid` with pinned views
/// would give laziness for free, but a tile changing container — grid to header to fullscreen —
/// changes identity, remounts its video view and blinks to the avatar, which is the failure the
/// whole design exists to avoid. Laziness is the layout's: it composes only the rows within a
/// viewport of the screen.
struct ElementCallStage: View {
    @Environment(\.elementCallStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let tiles: [ElementCallTile]
    let spotlightID: MatrixRTCTileID?
    /// The tile filling the screen, if any. Not a mode of the stage so much as one more arrangement
    /// of it: the tile keeps its identity, so it grows out of its cell rather than being replaced.
    var fullscreenID: MatrixRTCTileID?
    /// Who the Picture in Picture source view is anchored on in a small call (019 R15). Kept by the
    /// view model, not here: the stage unmounts while minimized, and it has to outlive that.
    var speakerID: MatrixRTCTileID?
    /// Room the chrome takes at the top and the bottom, which only our floating tile keeps clear of
    /// (019 R19). Not part of ``Arrangement``: it changes inside the chrome's own animation, so the
    /// tile moves with the bar rather than on the stage's slower spring behind it.
    var floatingInsets = ElementCallSmallCallLayout.FloatingInsets.zero
    /// The screen has extended the stage under the side safe areas, for a picture that runs edge to
    /// edge (019 R4). Only then are the side insets the stage's to keep clear of.
    var extendsUnderSideSafeAreas = false
    /// Where our floating tile sits; the context's, so it outlives this view (019 R20).
    var ownCorner: ElementCallOwnTileCorner = .bottomRight
    var canSwitchCamera = true
    var isFrontCamera = true
    /// A harness asking for an offset; honoured once per request, clamped like a user's scroll.
    var scrollRequest: ElementCallScrollRequest?
    let memberCount: Int
    let pictureInPictureSourceView: UIView
    let callProvider: () -> MatrixRTCMediaSession?
    /// How far down from the top the chrome drawn over the stage reaches; zero when nothing is kept
    /// clear there. A content margin rather than a smaller frame: see ``body``.
    var topClearance: CGFloat = 0
    /// How far above the safe area the floating controls reach; zero while they are hidden.
    let controlsClearance: CGFloat
    /// Double tap. Ahead of `onAction` for the same reason as on the tile: that one is the trailing
    /// closure at every call site, and a new closure after it would quietly take its place.
    var onToggleFullscreen: (MatrixRTCTileID) -> Void = { _ in }
    /// Single tap, anywhere on the stage; the screen knows which chrome it toggles.
    var onToggleChrome: () -> Void = { }
    /// The user's own scrolling, never the app's, and never the bounce past either end (017 R23).
    var onUserScroll: (_ towardEnd: Bool) -> Void = { _ in }
    /// The user's scrolling has fully stopped, fling included (R20).
    var onScrollIdle: () -> Void = { }
    /// A swipe or a VoiceOver adjustment on the spotlight asks for another hero (R22, R25).
    var onShowHero: (MatrixRTCTileID) -> Void = { _ in }
    /// Our floating tile was dropped nearest this corner (019 R21). Called inside the animation
    /// that takes the tile there, so the screen's write lands in the same transaction.
    var onMoveOwnTile: (ElementCallOwnTileCorner) -> Void = { _ in }
    let onAction: (ElementCallScreenViewAction) -> Void
    
    /// The visible top, in content coordinates. Fed back into the layout, which is what makes the
    /// spotlight sticky and the composed band follow the screen.
    @State private var scrollOffset: CGFloat = 0
    /// The scroller's top inset, which the chrome's margin is part of. The pinned tiles carry it as
    /// a separate, animated offset; see ``pinned(_:at:)``.
    @State private var scrollInsetTop: CGFloat = 0
    /// How far the grid is held back from where an inset change just put it; animated back to
    /// zero so the grid slides with the chrome. See ``slideGridForInsetChange(from:to:)``.
    @State private var gridSlide: CGFloat = 0
    /// Set when the clearance changes, and spent on the inset change it causes.
    @State private var isClearanceChangePending = false
    /// What the scroller adds to the top inset beyond our margin — the safe area it extends under.
    /// Taken whenever it reports, so a pinned view can slide on the margin as soon as it changes,
    /// a frame before the report does, and still land where the report puts it.
    /// Nil until the scroller first reports, which a snapshot never waits for.
    @State private var scrollInsetBase: CGFloat?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    /// The tiles that were live on the last pass, for the layout's edge hysteresis.
    @State private var liveTileIDs: Set<MatrixRTCTileID> = []
    /// The offset to come back to. Full screen changes the stage's frame (the top bar goes, the
    /// picture runs under the status bar), and a scroller whose viewport grows clamps its offset
    /// without asking; leaving would land somewhere else (R63).
    @State private var offsetBeforeFullscreen: CGFloat?
    /// The first grid tile on screen, and the stage size it was seen at. After a rotation the tile
    /// that was first visible is still visible (R66): the offset is re-set to put it at the top of
    /// the grid area under the new arrangement.
    @State private var anchor: (tileID: MatrixRTCTileID, area: CGSize)?
    /// The call's tiles as of the last pass. A tile inserted that is not among them has just
    /// joined, and is the only kind that grows in: see ``arrival``.
    @State private var knownTileIDs: Set<MatrixRTCTileID> = []
    /// The tile full screen, and then on its way back, until that move lands. On the way back the
    /// layout gives it a grid tile's z position straight away, and it shrank under the spotlight
    /// and the neighbours it was returning to.
    @State private var raisedTileID: MatrixRTCTileID?
    @State private var scrollPhase: ScrollPhase = .idle
    /// Where the last reported scroll direction was measured from, in the scroller's raw offset.
    @State private var scrollDirectionOrigin: CGFloat?
    @State private var lastReportedTowardEnd: Bool?
    /// Which way the finger sent the fling it let go of; nil while the finger is down.
    @State private var flingTowardEnd: Bool?
    /// Between the user starting to scroll and the scroller next coming to rest.
    @State private var isUserScrolling = false
    /// The content height the origin was measured against.
    @State private var scrollDirectionContentHeight: CGFloat?
    /// How far our floating tile is under the finger from its corner. Plain state rather than
    /// `@GestureState`, which resets outside the release's animation and would put the tile back in
    /// its old corner for a frame before it springs to the new one.
    @State private var ownTileDrag: CGSize = .zero
    /// Our own picture's upright shape, which the floating tile takes (019 R10, R29). From the
    /// renderer, which knows within a frame, rather than the call's video info, which is polled
    /// about once a second and would leave the tile the wrong shape after every rotation.
    @State private var ownVideoAspect: CGFloat?
    
    /// How a tile that has just joined appears, and how any tile goes. Never how a row scrolling
    /// into the band appears: a fling reaches it while it would still be transparent (R38, R49).
    private static let arrival: AnyTransition = .scale(scale: 0.85).combined(with: .opacity)
    
    private static let animation: Animation = .spring(duration: 0.45, bounce: 0.15)
    
    private var animation: Animation? {
        // With reduce motion on, tiles change place without sliding (R41). That also stops the
        // fit blend on a promotion, which is the intended outcome.
        reduceMotion ? nil : Self.animation
    }
    
    var body: some View {
        // The reader stays inside the safe area, and reports the insets of every edge it sits
        // against, whether or not it extends under them. The scroller extends under the bottom
        // one so a full-bleed picture can run under the home indicator, so that inset is real to
        // the layout. The side ones are not: the reader's own edge is already at the sensor
        // housing, and adding them again put a second housing's width of nothing on each side of
        // the stage in landscape.
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            // The area under the top margin: content coordinates start there, so the layout's
            // viewport is what is not covered by the chrome kept clear above it.
            let metrics = ElementCallStageLayout.Metrics(area: CGSize(width: geometry.size.width, height: geometry.size.height + insets.bottom - topClearance),
                                                         bottomInset: insets.bottom,
                                                         leadingInset: extendsUnderSideSafeAreas ? insets.leading : 0,
                                                         trailingInset: extendsUnderSideSafeAreas ? insets.trailing : 0,
                                                         controlsClearance: controlsClearance,
                                                         // From the reader rather than the scroller's
                                                         // report, which a snapshot never waits for.
                                                         topBleed: topClearance + insets.top)
            let stage = ElementCallStageLayout.compute(.init(tiles: tiles,
                                                             spotlightID: spotlightID,
                                                             fullscreenID: fullscreenID,
                                                             scrollOffset: scrollOffset,
                                                             liveTileIDs: liveTileIDs,
                                                             metrics: metrics,
                                                             speakerID: speakerID,
                                                             ownCorner: ownCorner,
                                                             ownVideoAspect: ownVideoAspect,
                                                             floatingInsets: floatingInsets))
            let floating = stage.placements.first { $0.appearance == .floating }
            let floatingBounds = ElementCallSmallCallLayout.floatingBounds(metrics: metrics, insets: floatingInsets)
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    // The gaps between tiles and below the last row (017 R14). Behind the tiles
                    // rather than on the content root above them: from there, iOS 18 delivered a
                    // tap on a tile to this as well, once the tile's double tap had failed, and
                    // the chrome hid and came straight back. A sibling only gets what no tile took.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { onToggleChrome() }
                        .zIndex(-1)
                    fullscreenScrim(in: stage)
                    ForEach(stage.placements) { placement in
                        tileView(for: placement, in: stage)
                    }
                    if let heroStack = stage.heroStack, let spotlight = stage.placements.first(where: \.isSpotlight) {
                        if metrics.isLandscape {
                            // Arrows on the landscape spotlight's edges, where it has width to
                            // spare; dots under the portrait one, where it has none. Plain
                            // siblings: the spotlight's pan belongs to the content root and
                            // declines touches that start on them (see the gesture).
                            ForEach([-1, 1], id: \.self) { step in
                                let frame = Self.arrowFrame(step: step, spotlight: spotlight.frame)
                                heroArrow(step: step, isEnabled: step < 0 ? heroStack.shown > 0 : heroStack.shown < heroStack.count - 1, in: stage)
                                    .position(x: frame.midX, y: frame.midY - stage.viewport.minY)
                                    .offset(y: stage.viewport.minY)
                                    // Pinned like the spotlight: never animated with the offset.
                                    .animation(nil, value: stage.viewport.minY)
                                    .zIndex(ElementCallStageLayout.spotlightZIndex + 0.5)
                            }
                        } else {
                            // Pinned with the spotlight they hang from, or they would jump while it
                            // slid with the chrome.
                            heroDots(heroStack)
                                .position(x: spotlight.frame.midX, y: spotlight.frame.maxY + ElementCallStageLayout.Metrics.heroDotsClearance / 2 - stage.viewport.minY)
                                .modifier(Pinned(pin: stage.viewport.minY, scroll: scrollParts, insetBase: scrollInsetBase, topClearance: topClearance, animation: chromeAnimation))
                                .zIndex(ElementCallStageLayout.spotlightZIndex + 0.5)
                        }
                    }
                }
                .frame(width: metrics.area.width, height: stage.contentHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                // Once, on the content root: a drag that starts on the spotlight never scrolls the
                // grid (R64) and a sideways one switches heroes (R22). See the gesture for why it
                // is UIKit's and why it is here rather than on the tile.
                .gesture(ElementCallSpotlightPanGesture(spotlightFrame: stage.placements.first(where: \.isSpotlight)?.frame,
                                                        excluded: stage.heroStack != nil && metrics.isLandscape
                                                            ? stage.placements.first(where: \.isSpotlight).map { [Self.arrowFrame(step: -1, spotlight: $0.frame), Self.arrowFrame(step: 1, spotlight: $0.frame)] } ?? []
                                                            : []) { step in showHero(step, in: stage) })
                .gesture(ownTileDragGesture(floating: floating, bounds: floatingBounds, width: metrics.area.width))
                .transaction(value: fullscreenID) { transaction in
                    // Inside the stack's spring, so this is the move the completion waits for. With
                    // no animation at all it runs straight after the pass, as it must.
                    guard fullscreenID == nil, raisedTileID != nil else { return }
                    transaction.addAnimationCompletion { raisedTileID = nil }
                }
                .animation(animation, value: Arrangement(tiles: tiles,
                                                         spotlightID: spotlightID,
                                                         fullscreenID: fullscreenID,
                                                         ownCorner: ownCorner,
                                                         ownVideoAspect: ownVideoAspect,
                                                         metrics: metrics))
            }
            // No snapping, no dots (R26); nothing moves the offset while a tile fills the screen, or
            // in a small call, where a scroller whose content is one screen would still bounce
            // (019 R30).
            .scrollIndicators(.hidden)
            .scrollDisabled(fullscreenID != nil || stage.isStatic)
            .scrollPosition($scrollPosition)
            // The top bar's room as a margin and not a shorter frame. UIKit leaves the offset alone
            // when an inset changes, so the chrome going mid-drag moves nothing under the finger
            // (R6), mid-scroll it simply uncovers rows, and at the top the content slides up into
            // the space (R5). Compensating a layout clearance with `scrollTo` was tried first and
            // does not work: an active pan overrides the write.
            .contentMargins(.top, topClearance, for: .scrollContent)
            // The bottom clearance is the layout's, so the scroller must not add its own inset
            // for the home indicator on top of it.
            .ignoresSafeArea(.container, edges: .bottom)
            .onScrollGeometryChange(for: CGPoint.self) { CGPoint(x: $0.contentInsets.top, y: $0.contentOffset.y) } action: { old, sample in
                scrollOffset = sample.y + sample.x
                scrollInsetTop = sample.x
                scrollInsetBase = sample.x - topClearance
                // Only an inset change we caused. The scroller's first report is a zero geometry
                // and the next one the real inset, safe area and all; slid across, the grid came
                // down into place from under the top bar the first time the stage appeared.
                if isClearanceChangePending, sample.x != old.x {
                    isClearanceChangePending = false
                    slideGridForInsetChange(from: old, to: sample)
                }
            }
            .onChange(of: topClearance) {
                isClearanceChangePending = true
            }
            .onScrollPhaseChange { old, new in
                scrollPhase = new
                if new == .interacting, old != .interacting {
                    scrollDirectionOrigin = nil
                    flingTowardEnd = nil
                    isUserScrolling = true
                }
                if new == .decelerating, old == .interacting {
                    flingTowardEnd = lastReportedTowardEnd
                }
                // On the first idle after the user's scrolling, whatever came between: a fling that
                // hides the chrome at the end shortens the grid, the stage settles it to the new end
                // with a scroll of its own, and the phase goes through `.animating` on the way.
                // Waiting for idle straight after a user phase, the return never started.
                if new == .idle, isUserScrolling {
                    isUserScrolling = false
                    onScrollIdle()
                }
            }
            .onScrollGeometryChange(for: UserScrollSample.self) { UserScrollSample($0) } action: { _, sample in
                reportUserScroll(sample, in: stage)
            }
            .onChange(of: Visibility(stage), initial: true) { _, visibility in
                // A side effect, so it belongs here rather than in the body: releasing is a message
                // to the SFU, and the body runs whenever anything at all about the call changes.
                callProvider()?.setVideoVisibility(paused: visibility.paused, released: visibility.released)
            }
            .onChange(of: stage.detailWindow, initial: true) { _, window in
                // The layout is what knows what is on screen, so it drives the core's detail
                // window too (R52, R55); the call declines an equal one.
                callProvider()?.setDetailWindow(window)
            }
            .onChange(of: Set(stage.placements.filter { $0.visibility == .live }.map(\.id)), initial: true) { _, live in
                liveTileIDs = live
            }
            // After the pass, so a tile is still unknown on the pass that inserts it.
            .onChange(of: tiles, initial: true) { _, tiles in
                knownTileIDs = Set(tiles.lazy.map(\.id))
            }
            .onChange(of: stage.maxScrollOffset) { _, maxOffset in
                // A departure that shortens the grid past the offset: the scroller would clamp
                // without animating and the grid would jump. Settling to the new end inside the
                // same animation as the placements is what keeps it from ever showing an empty
                // area below the last row (R42).
                guard fullscreenID == nil, scrollOffset > maxOffset else { return }
                withAnimation(animation) {
                    scrollPosition.scrollTo(y: maxOffset)
                }
            }
            .onChange(of: controlsClearance) { old, new in
                // The bar coming back while the grid is at its end would land on the last row; the
                // end moves down with it instead (R7). Only ever at rest: during a drag, what brings
                // the bar back is scrolling toward the start, which leaves the end anyway.
                guard new > old, fullscreenID == nil, scrollOffset >= stage.maxScrollOffset - (new - old) - 1 else { return }
                withAnimation(animation) {
                    scrollPosition.scrollTo(y: stage.maxScrollOffset)
                }
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request, fullscreenID == nil else { return }
                withAnimation(animation) {
                    scrollPosition.scrollTo(y: min(max(0, request.offset), stage.maxScrollOffset))
                }
            }
            .onChange(of: fullscreenID != nil) { _, isFullscreen in
                guard isFullscreen else { return }
                offsetBeforeFullscreen = scrollOffset
                raisedTileID = fullscreenID
            }
            .onChange(of: stage, initial: true) { _, stage in
                // Leaving fullscreen: the stage grows back under the top bar over several passes,
                // and a position set in any one of them can be clamped against the wrong content
                // (a one-shot restore landed a row off, once in three runs). So the offset is
                // asked for on every pass until the scroller reports it, and only then is the
                // anchor logic allowed back in.
                if fullscreenID == nil, let offset = offsetBeforeFullscreen {
                    let target = min(offset, stage.maxScrollOffset)
                    if abs(scrollOffset - target) <= 1 {
                        offsetBeforeFullscreen = nil
                    } else {
                        scrollPosition.scrollTo(y: target)
                    }
                    return
                }
                reanchor(in: stage, gridTop: gridTop(in: stage))
            }
        }
    }
    
    /// Black between the stage and a tile growing to full screen. Without it, the last part of the
    /// move left a stripe of the stage along the edges the tile had not reached yet, which read as
    /// a half-finished screen rather than a tile growing. Always mounted and transparent, so there
    /// is nothing to insert: it turns opaque well ahead of the tile on the way in, and fades over
    /// the shrink on the way out, so the grid comes back as the tile returns to it.
    ///
    /// Taller than the viewport by a screen each way: the scroller draws under the status bar and
    /// the home indicator, and full screen does not scroll.
    private func fullscreenScrim(in stage: ElementCallStageLayout) -> some View {
        let isFullscreen = fullscreenID != nil
        return Color.black
            .frame(width: stage.viewport.width, height: stage.viewport.height * 3)
            .position(x: stage.viewport.midX, y: stage.viewport.midY)
            .animation(nil, value: stage.viewport)
            .opacity(isFullscreen ? 1 : 0)
            .animation(reduceMotion ? nil : isFullscreen ? .easeOut(duration: 0.15) : .easeIn(duration: 0.35), value: isFullscreen)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .zIndex(ElementCallStageLayout.fullscreenScrimZIndex)
    }
    
    /// UIKit applies an inset change in one step: near the top it moves the content to keep it
    /// inside the new range, and mid-scroll it moves nothing. The chrome slides, so at the top the
    /// grid jumped to where the top bar was still sliding to. The jump is undone with an offset in
    /// the same update, and the offset is then animated away on the chrome's slide. Mid-scroll the
    /// jump is zero and so is the offset. With reduce motion on the content changes place without
    /// sliding (017 R25), which is what the jump already does.
    ///
    /// Never around full screen. Going in or out changes the margin in the same update as the
    /// tile's grow, and the unanimated write here took the grow's animation with it: the tile
    /// snapped to full size instead of growing out of its cell.
    private func slideGridForInsetChange(from old: CGPoint, to new: CGPoint) {
        guard let chromeAnimation, new.x != old.x, fullscreenID == nil, raisedTileID == nil else { return }
        let jump = new.y - old.y
        guard abs(jump) > 0.5 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { gridSlide += jump }
        // A separate update: in the same one, SwiftUI would coalesce the two writes and there
        // would be nothing to animate from.
        DispatchQueue.main.async {
            withAnimation(chromeAnimation) { gridSlide = 0 }
        }
    }
    
    /// The chrome's slide, for the part of a pinned position that comes from the top margin; none
    /// with reduce motion on, where the content changes place without sliding (017 R25).
    private var chromeAnimation: Animation? {
        reduceMotion ? nil : ElementCallChromeVisibility.slide
    }
    
    /// Places a pinned view — the spotlight, a full-screen tile, the dots under the spotlight — at
    /// the offset, in two parts that animate differently. The part that is the scroller's raw
    /// offset follows the finger and never animates. The part that is the top inset is the
    /// chrome's margin, and slides with the chrome: as one unanimated pin, the spotlight jumped to
    /// where the top bar was still sliding towards.
    ///
    /// The raw part is keyed on what the *scroller* did, never on this view's own pin. A tile going
    /// full screen from a scrolled grid changes its pin from 0 to the offset in the same
    /// transaction as its frame; keyed on the pin, that move lost its animation and the tile
    /// snapped to full size instead of growing.
    ///
    /// The inset part slides on the stage's own `topClearance`, not on the inset the scroller
    /// reports back: the report lands a frame after the chrome starts to move, and a spotlight
    /// sliding one frame behind the top bar's band left a gap between them as it went. The report
    /// also counts the safe area the scroller extends under, which the clearance does not; that
    /// part is carried as `insetBase`, or the spotlight settled under the status bar.
    private struct Pinned: ViewModifier {
        /// This view's pin: the offset if it is pinned, else zero.
        let pin: CGFloat
        let scroll: ScrollParts
        /// Nil until the scroller has reported: until then there is no inset to split off, and the
        /// pin is placed whole, where it was placed before any of this.
        let insetBase: CGFloat?
        let topClearance: CGFloat
        let animation: Animation?
        
        func body(content: Content) -> some View {
            let isPinned = pin != 0
            let base = isPinned ? insetBase : nil
            return content
                .offset(y: isPinned ? (base == nil ? pin : pin - scroll.insetTop) : 0)
                .animation(nil, value: scroll.raw)
                // Explicit, and keyed here: the stack's arrangement animation is keyed on metrics
                // the clearance is part of, and would otherwise slide this on the stage's slower
                // spring while the band slid on the chrome's.
                .offset(y: base.map { $0 + topClearance } ?? 0)
                .animation(animation, value: topClearance)
        }
    }
    
    /// The two parts of the offset, as the scroller reports them.
    private struct ScrollParts: Equatable {
        let raw: CGFloat
        let insetTop: CGFloat
    }
    
    private var scrollParts: ScrollParts {
        ScrollParts(raw: scrollOffset - scrollInsetTop, insetTop: scrollInsetTop)
    }
    
    /// The scroller's raw offset, which an inset change leaves alone, unlike ``scrollOffset``: read
    /// through the margin, the chrome hiding would itself look like a scroll toward the start and
    /// bring the chrome straight back.
    private struct UserScrollSample: Equatable {
        let offset: CGFloat
        /// Inside the scrollable range; outside it is the bounce, which is neither direction (R23).
        let isInBounds: Bool
        let contentHeight: CGFloat
        
        init(_ geometry: ScrollGeometry) {
            offset = geometry.contentOffset.y
            contentHeight = geometry.contentSize.height
            let top = -geometry.contentInsets.top
            let bottom = max(top, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
            isInBounds = offset >= top && offset <= bottom
        }
    }
    
    /// Far enough to be a scroll: a finger resting on the glass drifts by a point or two, and
    /// reporting that would flick the chrome back and forth.
    private static let scrollDirectionThreshold: CGFloat = 8
    
    /// The least the grid must be able to scroll, as a share of the screen, before scrolling toward
    /// its end hides the chrome (017 R18). With less, there is nothing the chrome is keeping from
    /// view, and a hide on what is mostly the bounce at the end reads as a glitch. A tap still hides
    /// it.
    static let scrollHideMinimumFraction: CGFloat = 0.5
    
    private func reportUserScroll(_ sample: UserScrollSample, in stage: ElementCallStageLayout) {
        // Only the finger and its fling. `.animating` is the app's own scrolling (R23).
        guard scrollPhase == .interacting || scrollPhase == .decelerating else { return }
        // A direction is measured between two points of one scroll over one content, never across
        // anything else that moves the offset. The bounce past an end is one. The other is the
        // content changing height under the scroller: the chrome hiding drops the controls'
        // clearance, the end comes up, and the scroller pulls a fling at the end back inside it,
        // which read as a scroll toward the start and brought the chrome straight back.
        guard sample.isInBounds, sample.contentHeight == scrollDirectionContentHeight,
              let origin = scrollDirectionOrigin else {
            scrollDirectionOrigin = sample.isInBounds ? sample.offset : nil
            scrollDirectionContentHeight = sample.isInBounds ? sample.contentHeight : nil
            return
        }
        let delta = sample.offset - origin
        guard abs(delta) >= Self.scrollDirectionThreshold else { return }
        scrollDirectionOrigin = sample.offset
        let towardEnd = delta > 0
        // A fling never turns round by itself, so a move against it is the bounce at an end. The
        // range is no help there: the scroller's geometry puts the end some 25 pt past where the
        // bounce settles, and the last of the bounce back read as a scroll toward the start.
        guard scrollPhase != .decelerating || flingTowardEnd == nil || towardEnd == flingTowardEnd else { return }
        lastReportedTowardEnd = towardEnd
        // Measured on the layout, which knows how far the grid really goes; toward the start always
        // reports, so chrome a long grid hid still comes back on a short one.
        guard !towardEnd || stage.maxScrollOffset >= stage.viewport.height * Self.scrollHideMinimumFraction else { return }
        onUserScroll(towardEnd)
    }
    
    /// What the stack animates on: the inputs that change the arrangement, never the offset. Keyed
    /// on the layout, every row a scroll moved into or out of the band was animated as well, which
    /// at two hundred kept a dozen tiles in flight through a fling, a viewport off screen.
    private struct Arrangement: Equatable {
        let tiles: [ElementCallTile]
        let spotlightID: MatrixRTCTileID?
        let fullscreenID: MatrixRTCTileID?
        /// Our floating tile's corner and shape, so a move from VoiceOver and a change of shape
        /// spring as a drag's release does (019 R25, R29).
        let ownCorner: ElementCallOwnTileCorner
        let ownVideoAspect: CGFloat?
        let metrics: ElementCallStageLayout.Metrics
    }
    
    /// What the stage is not showing, in the two ways the call tells apart: composed but off screen
    /// (paused, the view stays mounted so its last picture is there when it scrolls in, R49) and
    /// not composed at all (released).
    private struct Visibility: Equatable {
        let paused: Set<MatrixRTCTileID>
        let released: Set<MatrixRTCTileID>
        
        init(_ stage: ElementCallStageLayout) {
            paused = Set(stage.placements.lazy.filter { $0.visibility == .paused }.map(\.id))
            released = stage.hiddenTileIDs
        }
    }
    
    private func tileView(for placement: ElementCallTilePlacement, in stage: ElementCallStageLayout) -> some View {
        // A pinned tile (the spotlight, a fullscreen tile) is placed relative to the offset. That
        // part of its position follows the finger and must never animate, while the rest of it —
        // where the arrangement puts it — springs like every other tile's. They are two modifiers
        // for that reason: with one `position`, an arrangement change during a scroll carried the
        // sticky part on the spring, and it lagged the finger and sprang back to the top.
        let pin = placement.isSpotlight || placement.appearance == .fullscreen ? stage.viewport.minY : 0
        // Our own tile in a small call answers neither tap: it does not go full screen (019 R14),
        // and a tap on it does not toggle the chrome (R23). Its gestures stay attached, so the tap is
        // still the tile's rather than falling through to the stage behind it.
        let isOwnSmallCallTile = placement.tile.isLocal && stage.isStatic
        return ElementCallTileView(tile: placement.tile,
                                   callProvider: callProvider,
                                   isSpotlight: placement.isSpotlight,
                                   appearance: placement.appearance,
                                   memberCount: memberCount,
                                   heroStack: placement.isSpotlight ? stage.heroStack : nil,
                                   // A small call's full-bleed tile has no name either: its corner is
                                   // under the control bar and the home indicator (019 R4). Nor has
                                   // our floating tile, which is too small to carry it and is
                                   // obviously us; our mute state is on the control bar.
                                   isNameHidden: placement.isSpotlight && stage.viewport.width > stage.viewport.height
                                       || placement.appearance == .fullBleed
                                       || placement.appearance == .floating,
                                   // Never for a composed tile: a paused one keeps its video view, and
                                   // with it the last frame, so scrolling it in shows a picture rather
                                   // than an avatar (R49). The call is what stops its stream meanwhile.
                                   isVideoSuspended: false,
                                   contentFit: placement.contentFit,
                                   allowsFullscreen: !isOwnSmallCallTile,
                                   canSwitchCamera: canSwitchCamera,
                                   isFrontCamera: isFrontCamera,
                                   floatingCorner: placement.appearance == .floating ? ownCorner : nil,
                                   // The same animation as a drag's release, so a move asked for by
                                   // VoiceOver is the same move (019 R25).
                                   onMoveToCorner: { corner in withAnimation(animation) { onMoveOwnTile(corner) } },
                                   onContentAspectChange: { aspect in
                                       guard placement.tile.isLocal, aspect != ownVideoAspect else { return }
                                       ownVideoAspect = aspect
                                   },
                                   onToggleFullscreen: { onToggleFullscreen(placement.id) },
                                   onToggleChrome: isOwnSmallCallTile ? { } : onToggleChrome,
                                   onAction: onAction)
            .equatable()
            .background {
                if placement.id == stage.pictureInPictureTileID {
                    PictureInPictureSourceView(sourceView: pictureInPictureSourceView)
                }
            }
            .frame(width: placement.frame.width, height: placement.frame.height)
            // Screen readers traverse the spotlight first, then the grid in rank order (R69), and
            // step through the stack with an adjustable action rather than a swipe (R25).
            .accessibilitySortPriority(sortPriority(of: placement, in: stage))
            .accessibilityAdjustableAction { direction in
                guard placement.isSpotlight else { return }
                showHero(direction == .increment ? 1 : -1, in: stage)
            }
            .position(x: drawnFrame(placement, width: stage.viewport.width).midX, y: placement.frame.midY - pin)
            .modifier(Pinned(pin: pin, scroll: scrollParts, insetBase: scrollInsetBase, topClearance: topClearance, animation: chromeAnimation))
            // After the pin's unanimated part, so the slide back is not caught by it. Pinned views
            // slide with the inset already.
            .offset(y: pin == 0 ? gridSlide : 0)
            .offset(placement.appearance == .floating ? leadingRelative(ownTileDrag) : .zero)
            .zIndex(placement.id == raisedTileID ? ElementCallStageLayout.fullscreenZIndex : placement.zIndex)
            .transition(.asymmetric(insertion: knownTileIDs.contains(placement.id) ? .identity : Self.arrival, removal: Self.arrival))
    }
    
    /// Our floating tile follows the finger, held inside the stage (019 R21), and on release springs
    /// to the corner it was heading for: a flick carries it, a slow release does not. A cancelled
    /// drag springs back.
    ///
    /// The arithmetic is physical throughout, as the corners are; only what is drawn, and the rect a
    /// touch is accepted in, are converted to the stage's leading-relative positions.
    private func ownTileDragGesture(floating placement: ElementCallTilePlacement?, bounds: CGRect, width: CGFloat) -> ElementCallOwnTileDragGesture {
        let floating = placement?.frame
        let drag = leadingRelative(ownTileDrag)
        return ElementCallOwnTileDragGesture(tileFrame: placement.map { drawnFrame($0, width: width).offsetBy(dx: drag.width, dy: drag.height) },
                                             onChange: { travel in
                                                 guard let floating else { return }
                                                 ownTileDrag = ElementCallSmallCallLayout.clampedDrag(travel, from: floating, in: bounds)
                                             },
                                             onEnd: { velocity in
                                                 guard let floating else { return }
                                                 let dropped = floating.offsetBy(dx: ownTileDrag.width, dy: ownTileDrag.height)
                                                 let corner = ElementCallSmallCallLayout.releaseCorner(center: CGPoint(x: dropped.midX, y: dropped.midY),
                                                                                                       velocity: velocity,
                                                                                                       in: bounds)
                                                 withAnimation(animation) {
                                                     ownTileDrag = .zero
                                                     onMoveOwnTile(corner)
                                                 }
                                             },
                                             onCancel: {
                                                 withAnimation(animation) { ownTileDrag = .zero }
                                             })
    }
    
    /// Where a placement is drawn. Positions on the stage run from the leading edge, so a
    /// right-to-left locale mirrors them. That is right for the grid, which reads from the leading
    /// edge, and wrong for our floating tile, whose corners are physical (019 R18): its frame is
    /// mirrored back so it lands where the arithmetic put it.
    private func drawnFrame(_ placement: ElementCallTilePlacement, width: CGFloat) -> CGRect {
        guard placement.appearance == .floating, layoutDirection == .rightToLeft else { return placement.frame }
        return CGRect(x: width - placement.frame.maxX, y: placement.frame.minY, width: placement.frame.width, height: placement.frame.height)
    }
    
    /// A physical travel, such as a finger's, in the stage's leading-relative positions.
    private func leadingRelative(_ travel: CGSize) -> CGSize {
        layoutDirection == .rightToLeft ? CGSize(width: -travel.width, height: travel.height) : travel
    }
    
    /// Higher reads first. A small call states its order outright (019 R27): the overlap and our
    /// floating tile put tiles in no geometric order a screen reader could follow.
    private func sortPriority(of placement: ElementCallTilePlacement, in stage: ElementCallStageLayout) -> Double {
        if let index = stage.readingOrder.firstIndex(of: placement.id) {
            return Double(stage.readingOrder.count - index)
        }
        return placement.isSpotlight ? 1 : 0
    }
    
    /// The next or previous hero in the stack, clamped: the stack does not wrap (R23).
    private func showHero(_ step: Int, in stage: ElementCallStageLayout) {
        let heroes = ElementCallSpotlight.heroes(in: tiles)
        guard let heroStack = stage.heroStack else { return }
        let target = min(heroes.count - 1, max(0, heroStack.shown + step))
        guard target != heroStack.shown, heroes.indices.contains(target) else { return }
        onShowHero(heroes[target])
    }
    
    /// Where an arrow sits on the spotlight, in content coordinates: 36 pt in from the edge it
    /// points past, 44 pt square. Named so the gesture can exclude exactly what is drawn.
    static func arrowFrame(step: Int, spotlight: CGRect) -> CGRect {
        CGRect(x: (step < 0 ? spotlight.minX + 36 : spotlight.maxX - 36) - 22, y: spotlight.midY - 22, width: 44, height: 44)
    }
    
    /// One of the landscape spotlight's arrows (R22). Disabled at the end it points past, which is
    /// how the stack says it does not wrap (R23). A system glyph rather than one of the host's
    /// icons: the icon port has no chevrons, and a chevron is not something a host re-brands.
    private func heroArrow(step: Int, isEnabled: Bool, in stage: ElementCallStageLayout) -> some View {
        Button {
            showHero(step, in: stage)
        } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                // Interactive, and it has to be: see `ElementCallGlass`.
                .elementCallGlass(in: Circle(), fallback: Color.black.opacity(0.5), isInteractive: true)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .accessibilityLabel(step < 0 ? "Previous shared screen" : "Next shared screen")
        .accessibilityIdentifier(step < 0 ? ElementCallAccessibilityIdentifiers.heroPrevious : ElementCallAccessibilityIdentifiers.heroNext)
    }
    
    /// Which hero is shown, as a row of dots (R19). A readout: the pill on the spotlight names the
    /// position for VoiceOver and the adjustable action moves it.
    private func heroDots(_ heroStack: ElementCallStageLayout.HeroStack) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<heroStack.count, id: \.self) { index in
                Capsule()
                    .fill(index == heroStack.shown ? style.theme.iconPrimary : style.theme.iconQuaternary)
                    .frame(width: index == heroStack.shown ? 16 : 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
    
    /// Where the grid's first row starts: under the spotlight, or at the top.
    private func gridTop(in stage: ElementCallStageLayout) -> CGFloat {
        stage.placements.filter { !$0.isSpotlight && $0.appearance != .fullscreen }.map(\.frame.minY).min() ?? 0
    }
    
    /// Keeps the first visible grid tile in view across a change of stage size (R66), then notes
    /// which tile that now is. The anchor is only *used* when the size it was taken at differs
    /// from the current one, so an ordinary scroll or rank change just refreshes it.
    private func reanchor(in stage: ElementCallStageLayout, gridTop: CGFloat) {
        guard fullscreenID == nil else { return }
        let area = stage.viewport.size
        // A change of width only: the chrome coming and going changes the height alone, and must
        // leave the offset where the user put it (017 R6). A rotation always changes the width.
        if let anchor, anchor.area.width != area.width,
           let placement = stage.placements.first(where: { $0.id == anchor.tileID && !$0.isSpotlight }) {
            let target = min(stage.maxScrollOffset, max(0, placement.frame.minY - gridTop))
            if abs(target - scrollOffset) > 1 {
                scrollPosition.scrollTo(y: target)
            }
        }
        let firstVisible = stage.placements
            .filter { !$0.isSpotlight && $0.frame.maxY > stage.viewport.minY + gridTop }
            .min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        if let firstVisible {
            anchor = (firstVisible.id, area)
        }
    }
}

// MARK: - Previews

struct ElementCallStage_Previews: PreviewProvider, TestablePreview {
    typealias Fixtures = ElementCallPreviewFixtures
    
    /// Derived rather than passed, so a preview cannot show a spotlight the app would not choose.
    /// This is the view state's own rule, and it reads the array as the ranking it now is.
    static func stage(tiles: [ElementCallTile],
                      fullscreen: MatrixRTCTileID? = nil,
                      ownCorner: ElementCallOwnTileCorner = .bottomRight) -> some View {
        let state = Fixtures.connected(tiles: tiles)
        return ElementCallStage(tiles: tiles,
                                spotlightID: state.spotlightID,
                                fullscreenID: fullscreen,
                                speakerID: state.smallCallSpeakerID,
                                ownCorner: ownCorner,
                                memberCount: tiles.count,
                                pictureInPictureSourceView: UIView(),
                                callProvider: Fixtures.noCall,
                                controlsClearance: ElementCallView.controlsClearance) { _ in }
            .background(ElementCallStyle.stock.theme.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        stage(tiles: Fixtures.group)
            .previewDisplayName("Grid without a spotlight")
        stage(tiles: Fixtures.listenModeGroup)
            .previewDisplayName("Listen mode")
        stage(tiles: [Fixtures.alice])
            .previewDisplayName("Alone")
        stage(tiles: [Fixtures.alice, Fixtures.bob])
            .previewDisplayName("Two people")
        stage(tiles: [Fixtures.alice, Fixtures.bob, Fixtures.carol])
            .previewDisplayName("Three people")
        // Carol is speaking: she is ringed, and nobody moves (019 R9).
        stage(tiles: [Fixtures.alice, Fixtures.bob, Fixtures.carol, Fixtures.tile("Dan")])
            .previewDisplayName("Four people")
        stage(tiles: [Fixtures.alice, Fixtures.bob, Fixtures.carol, Fixtures.tile("Dan"), Fixtures.tile("Erin")])
            .previewDisplayName("Five people")
        // Our camera on: the floating tile takes the picture's shape, portrait before the first
        // frame (019 R10, R17), and carries the flip button (R22).
        stage(tiles: [ElementCallPreviewFixtures.tile("Alice", isLocal: true, hasVideo: true), Fixtures.bob])
            .previewDisplayName("Two people, our camera on")
        // The one other person talking is not ringed: there is no one else it could be (019 R9).
        stage(tiles: [Fixtures.alice, Fixtures.tile("Bob", isSpeaking: true)])
            .previewDisplayName("Two people, the other speaking")
        stage(tiles: [Fixtures.alice, Fixtures.bob], ownCorner: .topLeft)
            .previewDisplayName("Two people, our tile top left")
        // Corners are physical: a right-to-left locale leaves our tile bottom right (019 R18).
        stage(tiles: [Fixtures.alice, Fixtures.bob])
            .environment(\.layoutDirection, .rightToLeft)
            .previewDisplayName("Two people, right to left")
        stage(tiles: Fixtures.group, fullscreen: Fixtures.bob.id)
            .previewDisplayName("Full screen")
        // A member on two tiles: the one case in which every member-keyed assumption that survived
        // the migration would be wrong, and the only preview that shows a share in a grid cell.
        stage(tiles: Fixtures.sharingGroup)
            .previewDisplayName("A member on two tiles")
        stage(tiles: Fixtures.twoSharesGroup)
            .previewDisplayName("Two heroes")
    }
}
