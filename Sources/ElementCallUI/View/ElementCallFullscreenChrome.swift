//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import SwiftUI

/// What a single tap raises over a full-screen tile: the way back out, whose picture this is, and
/// the usual floating controls.
///
/// Drawn here rather than by the tile because keeping the name pill clear of the control bar means
/// knowing which edge that bar is on and how far it reaches, which is the screen's business and not
/// a tile's. Drawn here rather than inline in ``ElementCallView`` because as its own view it can be
/// previewed, and so snapshotted, without standing up a whole call around it.
struct ElementCallFullscreenChrome: View {
    @Environment(\.elementCallStyle) private var style
    let tile: ElementCallTile
    @Bindable var context: ElementCallScreenContext
    let isLandscape: Bool
    let onExit: () -> Void
    let onAction: (ElementCallScreenViewAction) -> Void
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topRow
                    .padding(.horizontal, 16)
                Spacer()
            }
            ElementCallFloatingControls(context: context)
        }
    }
    
    private var topRow: some View {
        HStack(spacing: 8) {
            Button(action: onExit) {
                style.icons.icon(.collapse)
            }
            .buttonStyle(ElementCallRoundButtonStyle())
            .accessibilityLabel("Exit full screen")
            .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.exitFullscreen)
            
            // The room name and the call timer are on the top bar, which full screen has hidden, so
            // the one thing still worth saying is whose picture this is and whether they can be heard.
            HStack(spacing: 4) {
                style.icons.icon(tile.isMicrophoneMuted ? .micOff : .micOn, size: .xSmall, relativeTo: .bodySM)
                // Named as well as labelled, and for the same reason the tile's own pill is: a
                // share is a tile of its own now, beside its owner's camera, so "(Screen share)"
                // alone no longer says whose screen you are looking at.
                Text(tile.isScreenShare ? "\(tile.displayName) (Screen share)" : tile.displayName)
                    .lineLimit(1)
            }
            .font(style.theme.bodySMSemibold)
            .foregroundStyle(style.theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.5), in: Capsule())
            .accessibilityElement(children: .combine)
            
            Spacer()
            
            // The flip button lives on the picture it acts on, so full screen takes it with it:
            // otherwise flipping the camera would mean leaving the view of yourself first.
            if tile.isLocal, tile.hasVideo {
                Button { onAction(.switchCamera) } label: {
                    style.icons.icon(.switchCamera, size: .small, relativeTo: .bodySM)
                        .padding(6)
                        .background(Color.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel("Switch camera")
            }
        }
    }
}

/// A full-screen tile's raised hand, drawn by the screen for the reason the chrome is, and below
/// the chrome's top row so the two never overlap and the badge does not move when a tap raises it.
struct ElementCallFullscreenHandBadge: View {
    let position: Int
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ElementCallRaisedHandBadge(position: position)
                Spacer()
            }
            .padding(.horizontal, 16)
            // The exit button's 44 pt and the row's spacing.
            .padding(.top, 44 + 8)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}

/// The control bar where it floats: along the bottom, over the stage, in both orientations. The
/// design draws it there in landscape too, over the spotlight, rather than as a rail up the
/// trailing edge, which is what this used to do.
///
/// One type rather than the same `VStack` written out in both the ordinary screen and the
/// full-screen chrome, so the two cannot drift and the stage's clearance stays one number.
struct ElementCallFloatingControls: View {
    @Bindable var context: ElementCallScreenContext
    
    /// How far up from the safe area it sits; the stage keeps the grid's end clear of it.
    static let edgePadding: CGFloat = 12
    static let clearance: CGFloat = ElementCallControlsView.thickness + edgePadding
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ElementCallControlsView(context: context, axis: .horizontal)
                .padding(.bottom, Self.edgePadding)
        }
    }
}

// MARK: - Previews

struct ElementCallFullscreenChrome_Previews: PreviewProvider, TestablePreview {
    typealias Fixtures = ElementCallPreviewFixtures
    
    static func chrome(_ tile: ElementCallTile, isLandscape: Bool = false) -> some View {
        ElementCallFullscreenChrome(tile: tile,
                                    context: .preview(state: Fixtures.connected(tiles: Fixtures.group)),
                                    isLandscape: isLandscape,
                                    onExit: { },
                                    onAction: { _ in })
            .background(ElementCallStyle.stock.theme.bgSubtleSecondary)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        chrome(Fixtures.bob)
            .previewDisplayName("Muted remote")
        ZStack {
            chrome(Fixtures.tile("Erin", handPosition: 2))
            ElementCallFullscreenHandBadge(position: 2)
        }
        .environment(\.colorScheme, .dark)
        .previewDisplayName("Hand raised")
        chrome(Fixtures.tile("Alice", isLocal: true, hasVideo: true))
            .previewDisplayName("Our own camera")
        chrome(Fixtures.share("Frank"))
            .previewDisplayName("Screen share")
    }
}
