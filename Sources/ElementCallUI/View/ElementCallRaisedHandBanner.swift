//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import SwiftUI

/// Above the control bar while our hand is up: that it is, and the way to lower it in one tap.
///
/// The bar keeps to five controls, so the hand is raised from the `…` sheet. Without this, a raised
/// hand would be visible only on our own tile, which may be small or scrolled away, and lowering
/// it would take two taps into a sheet (009 R2).
struct ElementCallRaisedHandBanner: View {
    @Bindable var context: ElementCallScreenContext
    
    @Environment(\.elementCallStyle) private var style
    
    var body: some View {
        HStack(spacing: 8) {
            style.icons.icon(.raisedHand)
                .foregroundStyle(style.theme.iconPrimary)
                .accessibilityHidden(true)
            Text(L10n.handRaisedBanner)
                .font(style.theme.bodySM)
                .foregroundStyle(style.theme.textPrimary)
            Button {
                context.send(viewAction: .toggleRaisedHand)
            } label: {
                Text(L10n.actionCancel)
                    .font(style.theme.bodySMSemibold)
                    .foregroundStyle(style.theme.iconOnSolidPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(style.theme.bgActionPrimaryRest, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!context.viewState.isHandControlEnabled)
            .accessibilityLabel(L10n.a11yLowerHand)
            .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.lowerHand)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        // The hand's own colours, fading out under the text, as the design's glow does.
        .background {
            style.theme.raisedHandBorder(in: CGSize(width: 120, height: 40)).first
                .map { Rectangle().fill($0).opacity(0.5) }
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .center))
        }
        .clipShape(Capsule())
        .elementCallGlass(in: Capsule(), fallback: style.theme.bgCanvasDefaultLevel.opacity(0.9), isInteractive: true)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Previews

struct ElementCallRaisedHandBanner_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        var state = ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group)
        state.isHandRaised = true
        return ElementCallRaisedHandBanner(context: .preview(state: state))
            .padding()
            .background(ElementCallStyle.stock.theme.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Hand raised")
    }
}
