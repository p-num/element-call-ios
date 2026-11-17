//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// The reaction picker: a card of the catalogue floating over a darkened call, with its title and
/// its way out above it (009 R11–R21).
///
/// Drawn by the call screen rather than presented as a sheet. The design has no sheet here: the
/// call shows through a scrim above a card inset from the screen's edges, which a system sheet's
/// own surface and corners would cover. The scrim is `ElementCallReactionPickerScrim`, inserted
/// beside this so it can fade while the card rises. The card is a solid fill, not glass: iOS 26
/// draws glass above later siblings whatever their order, and the bar's showed through a glass
/// card as it rose.
struct ElementCallReactionPicker: View {
    @Bindable var context: ElementCallScreenContext
    
    @Environment(\.elementCallStyle) private var style
    
    /// Six to a row, as the design draws them, in the catalogue's order (R11).
    private static let rows: [[MatrixRTCReactionKind]] = stride(from: 0, to: MatrixRTCReactionKind.catalogue.count, by: 6).map {
        Array(MatrixRTCReactionKind.catalogue[$0..<min($0 + 6, MatrixRTCReactionKind.catalogue.count)])
    }
    
    /// The design's sizes: six 48 pt circles 8 pt apart, in 16 pt of card, which a phone 393 pt
    /// wide or more holds whole. A narrower one shrinks the circles and keeps the gaps.
    private static let emojiSize: CGFloat = 48
    private static let spacing: CGFloat = 8
    
    /// About a phone's width, so a landscape phone or an iPad gets the card a portrait phone does
    /// rather than one stretched into a strip.
    private static let maxWidth: CGFloat = 440
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 0) {
                Text(L10n.reactionsTitle)
                    .font(style.theme.headingMDBold)
                    .foregroundStyle(style.theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(action: dismiss) { style.icons.icon(.close) }
                    .buttonStyle(ElementCallRoundButtonStyle())
                    .accessibilityLabel(L10n.actionClose)
                    .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.control(for: .close))
            }
            .padding(.leading, 8)
            
            // Not a lazy grid: its cells are made after the picker is inserted, outside the
            // transition, and sat in place while the card rose around them.
            VStack(spacing: Self.spacing) {
                ForEach(Self.rows, id: \.first) { row in
                    HStack(spacing: Self.spacing) {
                        ForEach(row) { reactionButton($0) }
                        // The last row keeps the others' column widths. Square, or a bare clear
                        // colour takes every point of height offered and the card fills the screen.
                        ForEach(row.count..<6, id: \.self) { _ in
                            Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: Self.emojiSize)
                        }
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(16)
            // Centred in a card as wide as the header, where a wider screen has room to spare.
            .frame(maxWidth: .infinity)
            .background(style.theme.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 32))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        }
        .frame(maxWidth: Self.maxWidth)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, dismiss)
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.reactionSheet)
    }
    
    /// Each reaction its own button, so a screen reader offers each as an action of its own rather
    /// than a grid it can only explore by touch (R21).
    private func reactionButton(_ kind: MatrixRTCReactionKind) -> some View {
        Button {
            context.send(viewAction: .sendReaction(kind))
        } label: {
            Circle()
                .fill(style.theme.bgCanvasDefault)
                // Lit from above, as the design's rims are.
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.06)],
                                                              startPoint: .top, endPoint: .bottom),
                                               lineWidth: 1))
                .aspectRatio(1, contentMode: .fit)
                .overlay(Text(kind.emoji).font(.title3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: Self.emojiSize)
        .accessibilityLabel(L10n.a11ySendReactionEmoji(kind.emoji))
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.reaction(kind))
    }
    
    private func dismiss() {
        context.send(viewAction: .dismissSheet)
    }
}

/// The darkened call behind the reaction picker. It takes every touch outside the card, so nothing
/// beneath reacts while the picker is open (R18), and a tap on it closes the picker (R20).
struct ElementCallReactionPickerScrim: View {
    let context: ElementCallScreenContext
    
    var body: some View {
        LinearGradient(colors: [.black.opacity(0.3), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { context.send(viewAction: .dismissSheet) }
            .accessibilityHidden(true)
    }
}

// MARK: - Previews

struct ElementCallReactionPicker_Previews: PreviewProvider, TestablePreview {
    static var previews: some View {
        let context = ElementCallScreenContext.preview(state: ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group))
        ZStack {
            ElementCallStyle.stock.theme.bgCanvasDefault.ignoresSafeArea()
            ElementCallReactionPickerScrim(context: context)
            ElementCallReactionPicker(context: context)
        }
        .environment(\.colorScheme, .dark)
        .previewDisplayName("Reactions")
    }
}
