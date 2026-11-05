//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// The full-screen call: top bar, the stage with the tiles and the floating control bar. The stage
/// arranges the tiles as spotlight and strip, or in a DM with just the two of us, the other person
/// full-bleed with our thumbnail over them. Layout follows the iOS call design; the paging strip is
/// Android's answer to big calls (tiles keep their size, pages grow).
struct ElementCallView: View {
    @Environment(\.elementCallStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.elementCallChromeReturnDelay) private var chromeReturnDelay
    @Bindable var context: ElementCallScreenContext
    /// Measured while drawn and kept while not, so the clearance it reserves can change in the same
    /// transaction as the chrome rather than a layout pass later. Started at what they measure at
    /// the default text size, so the first pass — all a snapshot ever renders — is already right:
    /// started at zero, the banner's row of tiles began underneath it.
    @State private var topBarHeight: CGFloat = 44
    @State private var bannerHeight: CGFloat = 28
    /// Set when a scroll-hide starts counting down to its return; any change cancels the count.
    @State private var scrollIdleToken: Int?
    /// A single tap waiting out ``chromeTapDelay`` before it toggles anything. A second tap within
    /// that is the other half of a double tap, and cancels it.
    @State private var isChromeTapPending = false
    /// The ringing avatar is what the screen is about, so a screen reader starts there (030 R22).
    @AccessibilityFocusState private var isRingingAvatarFocused: Bool
    let pictureInPictureSourceView: UIView
    /// Read at render time: the call exists only once media is connected.
    let callProvider: () -> MatrixRTCMediaSession?
    
    var body: some View {
        // Orientation is read as the shape of the space we were given, not from the device or the
        // size class: a half-screen iPad app in portrait wants the portrait arrangement whatever
        // the hardware is doing, and an iPad in landscape is landscape even though its vertical
        // size class says regular. The stage decides the same way, so the two cannot disagree.
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            ZStack {
                // Minimized (bar or Picture in Picture): nothing mounted, so the tiles' streams close
                // and only the window's own slot keeps decoding.
                if context.viewState.isMaximized {
                    style.theme.bgCanvasDefault.ignoresSafeArea()
                    
                    // The whole container, whatever the chrome is doing: the chrome is drawn over
                    // the stage (017 R2) and the stage keeps clear of it by a content margin, not by
                    // giving up its frame. A frame that changes height makes the scroller clamp its
                    // offset unasked, and a margin is the one change UIKit applies without moving
                    // the content under a finger (R6).
                    content(isLandscape: isLandscape)
                        // A fitted picture is centred on what it is given, so full screen gives
                        // it the screen: centred on the notch-shaped remainder instead, the
                        // letterbox above and below would not match. A small call's full-bleed
                        // picture likewise (019 R4); its top and bottom the stage reaches
                        // already, so only the sides are given up here.
                        .ignoresSafeArea(.container, edges: fullscreenTile != nil ? .all : isFullBleed ? .horizontal : [])
                    
                    // Every overlay gets an explicit z position. A view leaving a `ZStack` without
                    // one is drawn behind its siblings for the length of its removal, so the
                    // chrome went in with a slide and out with none.
                    if fullscreenTile == nil {
                        topChrome(isLandscape: isLandscape, safeArea: geometry.safeAreaInsets, isOverPicture: isFullBleed)
                            .zIndex(1)
                    }
                    
                    if let fullscreenTile {
                        // Outside the chrome, which starts hidden: a hand is the person's state, not
                        // a control, so it shows whether or not the chrome does (009 R30).
                        if let position = fullscreenTile.handPosition, !fullscreenTile.isScreenShare {
                            ElementCallFullscreenHandBadge(position: position)
                                .zIndex(2)
                        }
                        if context.isFullscreenChromeVisible {
                            ElementCallFullscreenChrome(tile: fullscreenTile,
                                                        context: context,
                                                        isLandscape: isLandscape,
                                                        onExit: { setFullscreen(nil) },
                                                        onAction: { context.send(viewAction: $0) })
                                .transition(.opacity)
                                .zIndex(2)
                        }
                    } else {
                        ElementCallFloatingControls(context: context)
                            .chromeSlide(isVisible: isStageChromeVisible,
                                         by: Self.controlsClearance + geometry.safeAreaInsets.bottom,
                                         reduceMotion: reduceMotion)
                            .zIndex(2)
                    }
                } else {
                    Color.clear
                        .onAppear(perform: declareMinimizedDetailWindow)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: context.isFullscreenChromeVisible)
            .animation(.easeInOut(duration: 0.25), value: context.viewState.isScreenSharing)
            .animation(.easeInOut(duration: 0.3), value: isStageShown)
            .animation(.easeInOut(duration: 0.3), value: context.viewState.isRinging)
            .frame(width: geometry.size.width, height: geometry.size.height)
            // In landscape the status bar goes with the chrome; in portrait it stays (R8, R9).
            .statusBarHidden(fullscreenTile != nil ? !context.isFullscreenChromeVisible : isTopBarHideable(isLandscape: isLandscape) && !isStageChromeVisible)
            .onChange(of: isLandscape) { _, isLandscape in
                applyStageChrome(.rotated(isLandscape: isLandscape))
            }
            .onChange(of: context.viewState.isRinging, initial: true) { wasRinging, isRinging in
                if isRinging {
                    applyStageChrome(.ringingStarted)
                } else if wasRinging {
                    applyStageChrome(.pickedUp(isLandscape: isLandscape))
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .alert(context.alertInfo?.title ?? "",
               isPresented: Binding(get: { context.alertInfo != nil },
                                    set: {
                                        if !$0 {
                                            context.alertInfo = nil
                                        }
                                    }),
               presenting: context.alertInfo) { _ in
            Button("OK") { context.alertInfo = nil }
        } message: { alert in
            Text(alert.message)
        }
        .onChange(of: context.viewState.isMaximized) { _, isMaximized in
            // Minimizing ends full screen rather than suspending it. The window continues whatever
            // the ordinary arrangement gives it, and coming back is the stage: one state fewer to
            // reason about, and no way to return to a screen whose chrome you had left hidden.
            guard !isMaximized else {
                applyStageChrome(.restored)
                return
            }
            setFullscreen(nil)
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, isRunning in
            applyStageChrome(.screenReader(isRunning: isRunning))
        }
        .task(id: isChromeTapPending) {
            guard isChromeTapPending else { return }
            try? await Task.sleep(for: Self.chromeTapDelay)
            guard !Task.isCancelled else { return }
            isChromeTapPending = false
            toggleChrome()
        }
        .task(id: scrollIdleToken) {
            // The return of chrome a scroll hid (R20). Cancelled by the token changing, which any
            // further scroll or tap does; the rule itself is the value's, so a late arrival after
            // a tap-hide changes nothing (R21).
            guard scrollIdleToken != nil else { return }
            try? await Task.sleep(for: chromeReturnDelay)
            guard !Task.isCancelled else { return }
            applyStageChrome(.scrollIdleElapsed)
        }
        .onChange(of: context.viewState.tiles) { _, tiles in
            // The tile you were watching can go. The arrangement falls back on its own, but the
            // screen would go on believing it was full screen: top bar hidden, chrome hidden, and
            // nothing left on screen that brings either back. Two ways now rather than one — their
            // member leaves, or they stop sharing and the share tile goes with them.
            guard let tileID = context.fullscreenTileID,
                  !tiles.contains(where: { $0.id == tileID }) else { return }
            setFullscreen(nil, byDeparture: true)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
    
    /// The stage is gone while minimized, so nothing declares the window. A small head range plus
    /// whatever the window continues (R52, partial: see the core-rs feedback on a call-wide "any
    /// remote video" flag); the stage declares its own again the moment it is back.
    private func declareMinimizedDetailWindow() {
        guard let call = callProvider() else { return }
        let pictureInPicture = context.viewState.pictureInPictureTile
        let also = [pictureInPicture.id, call.pictureInPictureCandidate(spotlight: pictureInPicture.id, isExact: pictureInPicture.isExact)].compactMap { $0 }
        call.setDetailWindow(.init(ranks: 0..<Self.minimizedDetailWindowLength, also: Set(also)))
    }
    
    /// The tile full screen right now, if it is still in the call.
    private var fullscreenTile: ElementCallTile? {
        guard let tileID = context.fullscreenTileID else { return nil }
        return context.viewState.tiles.first { $0.id == tileID }
    }
    
    /// Entering always starts with the chrome down, so the first thing a full-screen tile shows is
    /// the picture; leaving puts it back down for next time.
    ///
    /// The stage's chrome is told on the way out, and told how: a departure shows it whatever the
    /// orientation (R28), where leaving by hand returns it to the orientation's start (R27).
    private func setFullscreen(_ tileID: MatrixRTCTileID?, byDeparture: Bool = false) {
        let wasFullscreen = context.fullscreenTileID != nil
        withAnimation(.easeInOut(duration: 0.25)) {
            context.fullscreenTileID = tileID
            context.isFullscreenChromeVisible = false
        }
        if wasFullscreen, tileID == nil {
            applyStageChrome(.fullscreenEnded(byDeparture: byDeparture))
        }
    }
    
    // MARK: - Stage chrome
    
    /// The top bar and the control bar, shown and hidden as one (017 R1). Until the stage is up
    /// there is nothing to look at, and hang up has to stay in reach (R13).
    private var isStageChromeVisible: Bool {
        !isStageShown || context.stageChrome.isVisible
    }
    
    /// One picture behind all the chrome: a one-to-one small call (019 R4).
    private var isFullBleed: Bool {
        fullscreenTile == nil && ElementCallSmallCallLayout.isFullBleed(context.viewState.tiles)
    }
    
    /// What our floating tile keeps clear of while the chrome is up (019 R19). Nothing at the top in
    /// portrait: the content already starts under the top bar, which never leaves there.
    private func floatingInsets(isLandscape: Bool) -> ElementCallSmallCallLayout.FloatingInsets {
        let isVisible = isStageChromeVisible
        let topBarRoom = topBarHeight + Self.topChromeSpacing
        // Content starts under the portrait top bar, so in a one-to-one call the tile reaches up
        // into the room it leaves.
        let top: CGFloat = if isLandscape {
            isVisible ? topBarRoom : 0
        } else {
            isFullBleed && !isVisible ? -topBarRoom : 0
        }
        return .init(top: top, bottom: isVisible ? Self.controlsClearance : 0)
    }
    
    /// Whether the top bar goes with the control bar: in landscape (017 R1), and in a one-to-one
    /// call, whose picture is the whole screen (019 R30). Elsewhere in portrait it stays (017 R30).
    private func isTopBarHideable(isLandscape: Bool) -> Bool {
        isLandscape || isFullBleed
    }
    
    /// Whether the stage is what the screen shows, rather than the spinner of a call not yet joined.
    private var isStageShown: Bool {
        let state = context.viewState
        return state.connection == .connected || !state.tiles.isEmpty
    }
    
    /// Assigned only on a change: the context is observed, and the scroll reports a direction many
    /// times a second while the answer stays the same.
    private func applyStageChrome(_ event: ElementCallChromeVisibility.Event) {
        var chrome = context.stageChrome
        chrome.apply(event)
        switch event {
        case .userScrolled, .tap:
            scrollIdleToken = nil
        default:
            break
        }
        guard chrome != context.stageChrome else { return }
        withAnimation(chromeAnimation) {
            context.stageChrome = chrome
        }
    }
    
    /// A single tap toggles after a short wait of our own rather than the system's double-tap
    /// timeout: the system's made the chrome feel as if the tap had not worked, and toggling at once
    /// flashed the bar on every double tap (017 R16). A second tap inside the wait is the other half
    /// of a double tap, so it cancels the toggle and the double tap is all that happens.
    private func chromeTapped() {
        isChromeTapPending.toggle()
    }
    
    private func toggleChrome() {
        if fullscreenTile != nil {
            withAnimation(.easeInOut(duration: 0.2)) {
                context.isFullscreenChromeVisible.toggle()
            }
        } else {
            applyStageChrome(.tap)
        }
    }
    
    /// Shorter than the system's double-tap interval. A double tap slower than this still goes full
    /// screen, but the first tap's toggle will have started.
    static let chromeTapDelay: Duration = .milliseconds(200)
    
    /// The user stopped scrolling. Counts down to the return only when it was a scroll that hid it.
    private func stageScrollDidStop() {
        guard context.stageChrome.isAwaitingReturn else { return }
        scrollIdleToken = (scrollIdleToken ?? 0) + 1
    }
    
    /// Slides, or fades with reduce motion on (R25).
    private var chromeAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : ElementCallChromeVisibility.slide
    }
    
    /// Room above the stage's content for whatever is drawn over its top. Landscape draws over the
    /// picture and keeps nothing clear (R4). Portrait keeps the top bar and the banner clear, and
    /// the top bar never leaves in portrait (R30), so this changes only with the banner. Full
    /// screen runs under everything.
    static func topClearance(isLandscape: Bool, isFullscreen: Bool, topBarHeight: CGFloat, bannerHeight: CGFloat?) -> CGFloat {
        guard !isLandscape, !isFullscreen else { return 0 }
        var clearance = topBarHeight + topChromeSpacing
        if let bannerHeight {
            clearance += bannerHeight + topChromeSpacing
        }
        return clearance
    }
    
    /// The top bar and the banner, over the stage. The banner is not chrome and stays (R3).
    ///
    /// Portrait puts the canvas behind them, up through the status bar: the grid scrolls under the
    /// top bar, and without it a passing row would show through the room name. The top bar never
    /// leaves in portrait (R30); in landscape it goes with the control bar, over the picture, so a
    /// scrim there instead of a band. A one-to-one call's picture is treated like landscape in
    /// portrait too: it runs behind the top bar (019 R4), so a scrim rather than a band, and the top
    /// bar goes with the control bar, for the whole picture (019 R30).
    private func topChrome(isLandscape: Bool, safeArea: EdgeInsets, isOverPicture: Bool) -> some View {
        let isVisible = !isTopBarHideable(isLandscape: isLandscape) || isStageChromeVisible
        let isSharing = context.viewState.isScreenSharing
        return ZStack(alignment: .top) {
            if isLandscape {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: topBarHeight + 2 * Self.topChromeSpacing)
                    .ignoresSafeArea(edges: .top)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(false)
            } else if isOverPicture {
                // The same scrim, from the screen's top edge as the band below is: in portrait the
                // status bar is over the picture too.
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: safeArea.top + topBarHeight + 2 * Self.topChromeSpacing)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(false)
            } else {
                // Sized explicitly from the screen's top edge rather than stretched there by
                // `ignoresSafeArea`: the scroller runs under the status bar too, and a band of zero
                // height is not stretched at all, so with the chrome away the spotlight showed
                // through under the island.
                style.theme.bgCanvasDefault
                    .frame(height: safeArea.top + Self.topClearance(isLandscape: false,
                                                                    isFullscreen: false,
                                                                    topBarHeight: topBarHeight,
                                                                    bannerHeight: isSharing ? bannerHeight : nil))
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)
            }
            VStack(spacing: Self.topChromeSpacing) {
                topBar
                    .padding(.horizontal, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarHeight = $0 }
                    .chromeSlide(isVisible: isVisible, by: -(topBarHeight + safeArea.top + Self.topChromeSpacing), reduceMotion: reduceMotion)
                if isSharing {
                    screenShareBanner
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bannerHeight = $0 }
                        // Up into the top bar's place while it is away.
                        .offset(y: isVisible ? 0 : -(topBarHeight + Self.topChromeSpacing))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    // MARK: - Top bar
    
    private var topBar: some View {
        HStack(spacing: 8) {
            Button { context.send(viewAction: .minimize) } label: {
                style.icons.icon(.collapse)
            }
            .buttonStyle(ElementCallRoundButtonStyle())
            .accessibilityLabel(style.strings.back)
            // The same omission as the one fixed for `.more` below, and for the same reason: the
            // top bar does not go through `ElementCallControlsView.controlButton`, which is the
            // only caller of `control(for:)`, so a constant that exists and is pinned by name in
            // the identifier tests still reached no view and nothing could tap this button.
            .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.minimize)
            
            Spacer()
            
            VStack(spacing: 2) {
                Text(context.viewState.roomName)
                    .font(style.theme.bodyLGSemibold)
                    .foregroundStyle(style.theme.textPrimary)
                    .lineLimit(1)
                statusLine
            }
            
            Spacer()
            
            // The diagnostics menu, and only that. Screen sharing used to be duplicated here from
            // the control bar, which is where a user actually reaches for it; the audio test tone
            // that used to sit alongside the stats overlay is gone entirely.
            //
            // The version row is why the menu is never empty, which matters because everything else
            // in it is gated. Unlocalised, like the toggle: neither is a product string.
            Menu {
                // Absent rather than inert when developer mode is off. The toggle was always shown
                // and the controller silently refused the tap, which looked like a broken toggle.
                //
                // A nested Menu is a submenu, which keeps the diagnostics one level down and leaves
                // the top level to things a user might actually want. The Toggle inside renders as
                // a checked menu item, so the checkmark is the state: there is no need to say
                // "show/hide" in the label, and a plain Button would lose that.
                if context.viewState.isDeveloperModeEnabled {
                    Menu("Developer Options") {
                        Toggle("Tile stats", isOn: Binding(get: { context.viewState.isTileStatsVisible }, set: { _ in context.send(viewAction: .toggleTileStats) }))
                    }
                    Divider()
                }
                // A disabled button rather than a Section header or a bare Text: an empty Section
                // is dropped by SwiftUI, and a Menu does not render loose Text. Disabled gives a
                // dimmed, unselectable row, which is what this is.
                //
                // One row with a second Text rather than two rows: a menu ignores `.font`, and the
                // second Text is drawn as the system's smaller subtitle, which is the only way to
                // make the core line smaller.
                Button { } label: {
                    Text("version: \(ElementCallVersion.current)")
                    Text("matrix-rust-rtc \(ElementCallVersion.core)")
                }
                .disabled(true)
                // The menu draws the subtitle but leaves it out of the row's label, so VoiceOver,
                // and the UI test, would only ever hear the first line.
                .accessibilityLabel("version: \(ElementCallVersion.current), matrix-rust-rtc \(ElementCallVersion.core)")
            } label: {
                style.icons.icon(.overflow)
            }
            .buttonStyle(ElementCallRoundButtonStyle())
            // Applied here rather than through `control(for:)`, which only the control bar calls.
            // The constant existed and was pinned by name in the identifier tests, but reached no
            // view, so nothing could find this button — including the UI test that reads the menu.
            .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.more)
        }
    }
    
    /// Sharing has no picture of its own on this side, so the screen says so and offers the way out.
    private var screenShareBanner: some View {
        HStack(spacing: 8) {
            style.icons.icon(.shareScreen, size: .xSmall, relativeTo: .bodySMSemibold)
            Text("You\u{2019}re sharing your screen")
                .font(style.theme.bodySMSemibold)
                .lineLimit(1)
            Button(style.strings.stop) {
                context.send(viewAction: .toggleScreenShare)
            }
            .font(style.theme.bodySMSemibold)
            .foregroundStyle(style.theme.iconAccentPrimary)
            .buttonStyle(.plain)
        }
        .foregroundStyle(style.theme.textPrimary)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(style.theme.bgAccentRest, in: Capsule())
        .accessibilityElement(children: .combine)
    }
    
    @ViewBuilder
    private var statusLine: some View {
        switch context.viewState.connection {
        case .idle, .joining:
            Text("Joining…").font(style.theme.bodySM).foregroundStyle(style.theme.textSecondary)
        case .connectingMedia:
            Text("Connecting…").font(style.theme.bodySM).foregroundStyle(style.theme.textSecondary)
        case .calling:
            HStack(spacing: 4) {
                style.icons.icon(context.viewState.isAudioCall ? .voiceCall : .videoCall, size: .xSmall, relativeTo: .bodySM)
                    .accessibilityHidden(true)
                Text(style.strings.calling)
            }
            .font(style.theme.bodySM)
            .foregroundStyle(style.theme.textSecondary)
        case .connected:
            if let connectedAt = context.viewState.connectedAt {
                Text(connectedAt, style: .timer)
                    .font(style.theme.bodySM)
                    .foregroundStyle(durationColour)
                    .monospacedDigit()
            }
        case .ended:
            Text("Call ended").font(style.theme.bodySM).foregroundStyle(style.theme.textSecondary)
        case .failed(let message):
            Text(message).font(style.theme.bodySM).foregroundStyle(style.theme.textCriticalPrimary).lineLimit(2)
        }
    }
    
    /// A direct call's duration sits over the other person's picture or the scrim on it, where the
    /// secondary grey all but disappears; elsewhere the band behind the top bar is the canvas.
    private var durationColour: Color {
        if context.viewState.isMediaDegraded {
            style.theme.textCriticalPrimary
        } else if context.viewState.isDirect {
            style.theme.textPrimary
        } else {
            style.theme.textSecondary
        }
    }
    
    // MARK: - Content
    
    /// How far the floating controls reach in from the edge they are on. The placement itself lives
    /// on ``ElementCallFloatingControls``, which the full-screen chrome shares.
    static let controlsClearance = ElementCallFloatingControls.clearance
    /// The ranks kept in detail while minimized: enough for the bar and the window's fallbacks.
    static let minimizedDetailWindowLength = 8
    /// Between the top bar and the banner, and between them and the stage's content.
    static let topChromeSpacing: CGFloat = 12
    
    @ViewBuilder
    private func content(isLandscape: Bool) -> some View {
        let state = context.viewState
        // The spinner means "no call yet". That used to be the same thing as "no tiles" and is not
        // any more: the model's ranked list is *empty* when you are the only person in the call, and
        // your own tile — which is never in it — is the whole stage. Keying the spinner on emptiness
        // answers exactly that case with a spinner there is no way out of. The own tile is spliced
        // in unconditionally so the list is not actually empty here, but the invariant should not be
        // the only thing standing between a user alone in a call and a permanent loading screen.
        //
        // Nor does a ringing call wait on screen: the callee's avatar is the stage, with our own
        // tile over it once our media is up (030 R15, R16).
        if let callee = state.callee {
            ElementCallRingingAvatar(callee: callee, fallbackName: state.roomName)
                .accessibilityFocused($isRingingAvatarFocused)
                .onAppear { isRingingAvatarFocused = true }
                .transition(.opacity)
        }
        if state.connection != .connected, state.tiles.isEmpty {
            if !state.isRinging {
                ProgressView()
                    .tint(style.theme.iconPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        } else {
            ElementCallStage(tiles: state.tiles,
                             spotlightID: state.spotlightID,
                             fullscreenID: fullscreenTile?.id,
                             speakerID: state.smallCallSpeakerID,
                             floatingInsets: floatingInsets(isLandscape: isLandscape),
                             extendsUnderSideSafeAreas: isFullBleed,
                             ownCorner: context.ownTileCorner,
                             isDirect: state.isDirect,
                             canSwitchCamera: state.canSwitchCamera,
                             isFrontCamera: state.isFrontCamera,
                             scrollRequest: context.scrollRequest,
                             memberCount: state.memberCount,
                             pictureInPictureSourceView: pictureInPictureSourceView,
                             callProvider: callProvider,
                             topClearance: Self.topClearance(isLandscape: isLandscape,
                                                             isFullscreen: fullscreenTile != nil,
                                                             topBarHeight: topBarHeight,
                                                             bannerHeight: state.isScreenSharing ? bannerHeight : nil),
                             // Whether the bar is up or not: the grid's end always clears where it
                             // sits, so the bar going changes nothing under it (R31).
                             controlsClearance: Self.controlsClearance,
                             onToggleFullscreen: { tileID in
                                 // The same tile again is the way back out, which is what makes one
                                 // gesture do both halves of it.
                                 isChromeTapPending = false
                                 setFullscreen(context.fullscreenTileID == tileID ? nil : tileID)
                             },
                             // One tap, two chromes: full screen's keeps 000's rules, and the
                             // stage's follows 017's. The stage does not need to know which.
                             onToggleChrome: chromeTapped,
                             onUserScroll: { applyStageChrome(.userScrolled(towardEnd: $0)) },
                             onScrollIdle: stageScrollDidStop,
                             // A way of looking, so it lives on the context beside the fullscreen
                             // tile; the view model resolves it by identity on the next refresh.
                             onShowHero: { context.shownHeroID = $0 },
                             onMoveOwnTile: { context.ownTileCorner = $0 }) { action in
                context.send(viewAction: action)
            }
            .onAppear { applyStageChrome(.stageAppeared(isLandscape: isLandscape)) }
            // The call arriving: the tiles fade in over the spinner rather than replacing it in one
            // frame. How the screen itself arrives is the host's presentation, not this view's.
            .transition(.opacity)
        }
    }
}

// MARK: - Previews

struct ElementCallView_Previews: PreviewProvider, TestablePreview {
    static let joiningViewModel = ElementCallScreenPreviewFactory.makeViewModel(connection: .joining)
    static let failedViewModel = ElementCallScreenPreviewFactory.makeViewModel(connection: .failed("Homeserver offers no LiveKit transport"))
    
    static func screen(_ state: ElementCallScreenViewState) -> some View {
        ElementCallView(context: .preview(state: state),
                        pictureInPictureSourceView: UIView(),
                        callProvider: ElementCallPreviewFixtures.noCall)
    }
    
    /// Full screen is written onto the context rather than reached by tapping, which is the same
    /// seam the rest of these previews use: there is no call here to tap anything on.
    static func fullscreen(isChromeVisible: Bool) -> some View {
        let context = ElementCallScreenContext.preview(state: ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group))
        context.fullscreenTileID = ElementCallPreviewFixtures.carol.id
        context.isFullscreenChromeVisible = isChromeVisible
        return ElementCallView(context: context,
                               pictureInPictureSourceView: UIView(),
                               callProvider: ElementCallPreviewFixtures.noCall)
    }
    
    /// Pinned, so the portrait and landscape renders of one preview show one state rather than
    /// each orientation's start.
    static func chrome(isVisible: Bool, tiles: [ElementCallTile] = ElementCallPreviewFixtures.group) -> some View {
        let context = ElementCallScreenContext.preview(state: ElementCallPreviewFixtures.connected(tiles: tiles))
        context.stageChrome = .pinned(isVisible: isVisible)
        return ElementCallView(context: context,
                               pictureInPictureSourceView: UIView(),
                               callProvider: ElementCallPreviewFixtures.noCall)
    }
    
    static var previews: some View {
        ElementCallView(context: joiningViewModel.context, pictureInPictureSourceView: UIView()) { nil }
            .previewDisplayName("Joining")
        ElementCallView(context: failedViewModel.context, pictureInPictureSourceView: UIView()) { nil }
            .previewDisplayName("Failed")
        screen(ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group))
            .previewDisplayName("Connected group")
        // Alone in the call: the model's ranked list is empty and our own tile is all there is.
        // This used to render as a spinner you could not get out of.
        screen(ElementCallPreviewFixtures.connected(tiles: [ElementCallPreviewFixtures.alice]))
            .previewDisplayName("Alone in the call")
        screen(ElementCallPreviewFixtures.connected(tiles: [ElementCallPreviewFixtures.alice,
                                                            ElementCallPreviewFixtures.bob],
                                                    isDirect: true))
            .previewDisplayName("Two people")
        // Bob speaking with his camera off: the sound waves round his avatar.
        screen(ElementCallPreviewFixtures.connected(tiles: [ElementCallPreviewFixtures.alice,
                                                            ElementCallPreviewFixtures.tile("Bob", isSpeaking: true)],
                                                    isDirect: true))
            .previewDisplayName("Two people, speaking")
        // A direct call ringing (030): the callee's avatar, our tile over it, the chrome held up.
        screen(ElementCallPreviewFixtures.ringing())
            .previewDisplayName("Ringing")
        screen(ElementCallPreviewFixtures.ringing(isMediaUp: false))
            .previewDisplayName("Ringing, our media connecting")
        screen(ElementCallPreviewFixtures.ringing(isAudioCall: true))
            .previewDisplayName("Ringing a voice call")
        screen(ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.listenModeGroup))
            .previewDisplayName("Listen mode")
        screen(ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.twoSharesGroup))
            .previewDisplayName("Two heroes")
        screen(ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group,
                                                    isMicrophoneMuted: true,
                                                    isScreenSharing: true))
            .previewDisplayName("Muted and sharing")
        fullscreen(isChromeVisible: false)
            .previewDisplayName("Full screen")
        fullscreen(isChromeVisible: true)
            .previewDisplayName("Full screen with chrome")
        chrome(isVisible: true)
            .previewDisplayName("Chrome shown")
        chrome(isVisible: false)
            .previewDisplayName("Chrome hidden")
        // A small call (019): the picture behind both bars and our tile following the bar (R4, R19).
        chrome(isVisible: true, tiles: [ElementCallPreviewFixtures.alice, ElementCallPreviewFixtures.bob])
            .previewDisplayName("Two people, chrome shown")
        chrome(isVisible: false, tiles: [ElementCallPreviewFixtures.alice, ElementCallPreviewFixtures.bob])
            .previewDisplayName("Two people, chrome hidden")
        chrome(isVisible: true, tiles: Array(ElementCallPreviewFixtures.group.prefix(4)))
            .previewDisplayName("Four people, chrome shown")
        chrome(isVisible: false, tiles: Array(ElementCallPreviewFixtures.group.prefix(4)))
            .previewDisplayName("Four people, chrome hidden")
    }
}

private extension View {
    /// How the stage's chrome goes away: it stays mounted and slides off the edge it is on, or
    /// fades with reduce motion on (017 R25), and while away it takes no touches and is not there for
    /// a screen reader. Mounted rather than inserted and removed, because a removal transition did
    /// not carry the bar's contents: the glass buttons and the title stayed put and vanished on the
    /// last frame while only the background moved.
    func chromeSlide(isVisible: Bool, by distance: CGFloat, reduceMotion: Bool) -> some View {
        offset(y: isVisible || reduceMotion ? 0 : distance)
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
