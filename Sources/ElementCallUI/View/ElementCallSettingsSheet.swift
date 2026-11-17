//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import SwiftUI

/// What every sheet of the settings menu is drawn in: a title with a close button, then titled
/// sections, in a sheet over the lower part of the call (037 R12, R12a; 043 R5).
///
/// One container rather than a copy per sheet, so Preferences, Developer options and the sheets the
/// design has to come size, close and read the same.
///
/// Sized to its content, so the call stays in view above it and a row added later grows the sheet
/// with no number to change: the page reports its height and the sheet's one detent follows. Past
/// the screen's height the detent stops at the top and the sections scroll under the header, which
/// a list of choices reaches on a small phone.
struct ElementCallSettingsSheet<Sections: View>: View {
    @Bindable var context: ElementCallScreenContext
    let title: String
    let sheetIdentifier: String
    let closeIdentifier: String
    @ViewBuilder let sections: Sections
    
    @Environment(\.elementCallStyle) private var style
    @State private var headerHeight: CGFloat = 60
    @State private var contentHeight: CGFloat = 240
    @State private var bottomInset: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    if newHeight != headerHeight {
                        headerHeight = newHeight
                    }
                }
            ScrollView {
                VStack(spacing: 24) {
                    sections
                }
                .padding(.bottom, 16)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                    if newHeight != contentHeight {
                        contentHeight = newHeight
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
            if inset != bottomInset {
                bottomInset = inset
            }
        }
        .presentationDetents([.height(headerHeight + contentHeight + bottomInset)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(style.theme.bgCanvasDefault)
        // A container, or the identifier would replace every control's own inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(sheetIdentifier)
    }
    
    private var header: some View {
        ZStack {
            Text(title)
                .font(style.theme.headingMDBold)
                .foregroundStyle(style.theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                Spacer()
                Button { context.send(viewAction: .dismissSheet) } label: { style.icons.icon(.close) }
                    .buttonStyle(ElementCallRoundButtonStyle())
                    .accessibilityLabel(L10n.actionClose)
                    .accessibilityIdentifier(closeIdentifier)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

/// A group of rows on a card, titled unless it is the sheet's only one and the sheet's title says it.
/// A footer under the card says what the whole card is for, as Element X's settings do, which a list
/// of choices needs since none of its rows can (043 R14, R15b).
struct ElementCallSettingsSection<Rows: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let rows: Rows
    
    @Environment(\.elementCallStyle) private var style
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(style.theme.bodySMSemibold)
                    .foregroundStyle(style.theme.textSecondary)
                    .padding(.horizontal, 16)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                rows
            }
            .padding(.horizontal, 16)
            .background(style.theme.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 12))
            if let footer {
                Text(footer)
                    .font(style.theme.bodySM)
                    .foregroundStyle(style.theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// A row's title, with what it does beneath it in the row, where the choice beside it is short
/// enough to leave the room.
struct ElementCallSettingsRowTitle: View {
    let title: String
    var description: String?
    
    @Environment(\.elementCallStyle) private var style
    /// From the row's `.disabled`: SwiftUI dims the switch, but not text given a colour of its own,
    /// so a greyed row would otherwise read as live beside its dimmed switch (043 R7).
    @Environment(\.isEnabled) private var isEnabled
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(style.theme.bodyLG)
                .foregroundStyle(isEnabled ? style.theme.textPrimary : style.theme.textDisabled)
            if let description {
                Text(description)
                    .font(style.theme.bodySM)
                    .foregroundStyle(isEnabled ? style.theme.textSecondary : style.theme.textDisabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch with its title and what it does.
struct ElementCallSettingsToggle: View {
    let title: String
    let description: String
    let isOn: Bool
    var isEnabled = true
    let identifier: String
    let action: (Bool) -> Void
    
    @Environment(\.elementCallStyle) private var style
    
    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: action)) {
            ElementCallSettingsRowTitle(title: title, description: description)
        }
        .tint(style.theme.bgAccentRest)
        .disabled(!isEnabled)
        .padding(.vertical, 10)
        .accessibilityIdentifier(identifier)
    }
}

/// One choice among a few, each its own row with a checkmark on the chosen one, as the design's
/// Audio controls draws the speaker and Element X its own settings. Every choice is in view, and the
/// section's footer gets the full width, which a menu beside the title left it too little of.
struct ElementCallSettingsChoices<Value: Hashable>: View {
    let selection: Value
    let values: [Value]
    let label: (Value) -> String
    /// Each row's identifier, from its value.
    let identifier: (Value) -> String
    let action: (Value) -> Void
    
    @Environment(\.elementCallStyle) private var style
    
    var body: some View {
        ForEach(Array(values.enumerated()), id: \.element) { index, value in
            if index > 0 {
                ElementCallSettingsDivider()
            }
            Button { action(value) } label: {
                HStack(spacing: 16) {
                    Text(label(value))
                        .font(style.theme.bodyLG)
                        .foregroundStyle(style.theme.textPrimary)
                    Spacer(minLength: 0)
                    if value == selection {
                        // The host's glyph, through the icon port as every other one is: an SF
                        // Symbol here would be the one icon a host that draws its own cannot brand.
                        style.icons.icon(.check, size: .medium, relativeTo: .bodyLGSemibold)
                            .foregroundStyle(style.theme.iconAccentPrimary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(value == selection ? .isSelected : [])
            .accessibilityIdentifier(identifier(value))
        }
    }
}

/// The line between two rows of a section.
struct ElementCallSettingsDivider: View {
    @Environment(\.elementCallStyle) private var style
    
    var body: some View {
        Rectangle()
            .fill(style.theme.borderInteractiveSecondary.opacity(0.4))
            .frame(height: 1)
    }
}
