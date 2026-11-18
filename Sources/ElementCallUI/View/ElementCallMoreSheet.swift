//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// What the five-control bar has no room for, behind its `…`: the hand, the reaction picker's way
/// in, and screen share when the host enables it (009 R16, R17).
///
/// Sized to its content as the Preferences sheet is, so the call stays in view above it.
struct ElementCallMoreSheet: View {
    @Bindable var context: ElementCallScreenContext
    
    @Environment(\.elementCallStyle) private var style
    @State private var height: CGFloat = 200
    @State private var bottomInset: CGFloat = 0
    
    var body: some View {
        let state = context.viewState
        // Scrolls when it outgrows the tallest sheet the system allows, as three rows at an
        // accessibility text size do on a landscape phone; the detent is clamped to that height.
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    Text(L10n.moreTitle)
                        .font(style.theme.headingMDBold)
                        .foregroundStyle(style.theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 0) {
                        Spacer()
                        Button { context.send(viewAction: .dismissSheet) } label: { style.icons.icon(.close) }
                            .buttonStyle(ElementCallRoundButtonStyle())
                            .accessibilityLabel(L10n.actionClose)
                            .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.control(for: .close))
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 12)
                ForEach(state.extraActions, id: \.self) { action in
                    divider
                    row(for: action)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                if newHeight != height {
                    height = newHeight
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
            if inset != bottomInset {
                bottomInset = inset
            }
        }
        .presentationDetents([.height(height + bottomInset)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(style.theme.bgCanvasDefault)
        // A container, or the identifier would replace every row's own inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.moreSheet)
    }
    
    @ViewBuilder
    private func row(for action: ElementCallBarAction) -> some View {
        let state = context.viewState
        switch action {
        case .raisedHand:
            // The sheet goes, so the banner that now says the hand is up is in view (009 R2).
            row(icon: .raisedHand,
                title: state.isHandRaised ? L10n.lowerHand : L10n.raiseHand,
                identifier: ElementCallAccessibilityIdentifiers.control(for: .raisedHand),
                isEnabled: state.isHandControlEnabled) {
                    context.send(viewAction: .toggleRaisedHand)
                    context.send(viewAction: .dismissSheet)
                }
        case .reactions:
            row(icon: .reaction, title: L10n.emojiReactions, identifier: ElementCallAccessibilityIdentifiers.reactions,
                isEnabled: state.isReactionControlEnabled) {
                    context.send(viewAction: .present(.reactions))
                }
        case .screenShare:
            row(icon: .shareScreen,
                title: state.isScreenSharing ? L10n.screenShareStop : L10n.screenShareStart,
                identifier: ElementCallAccessibilityIdentifiers.screenShare,
                isEnabled: state.isScreenShareControlEnabled) {
                    context.send(viewAction: .toggleScreenShare)
                }
        }
    }
    
    private func row(icon: ElementCallIcon,
                     title: String,
                     identifier: String,
                     isEnabled: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                style.icons.icon(icon)
                    .foregroundStyle(isEnabled ? style.theme.iconSecondary : style.theme.iconQuaternary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(style.theme.bodyLG)
                    .foregroundStyle(isEnabled ? style.theme.textPrimary : style.theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityValue(isEnabled ? "" : L10n.a11yUnavailable)
        .accessibilityIdentifier(identifier)
    }
    
    /// Under the title and between rows, starting where the titles do, as the design draws them.
    private var divider: some View {
        Rectangle()
            .fill(style.theme.borderInteractiveSecondary.opacity(0.4))
            .frame(height: 1)
            .padding(.leading, 40)
    }
}

// MARK: - Previews

struct ElementCallMoreSheet_Previews: PreviewProvider, TestablePreview {
    static func sheet(isHandRaised: Bool = false, isScreenSharingEnabled: Bool = false) -> some View {
        var state = ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group, isScreenSharingEnabled: isScreenSharingEnabled)
        state.isHandRaised = isHandRaised
        return ElementCallMoreSheet(context: .preview(state: state))
            // The whole frame, as the Preferences sheet's previews do.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ElementCallStyle.stock.theme.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        sheet()
            .previewDisplayName("More")
        sheet(isHandRaised: true, isScreenSharingEnabled: true)
            .previewDisplayName("Hand raised, screen share enabled")
    }
}
