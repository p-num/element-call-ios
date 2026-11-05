//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// The user's in-call preferences, in a sheet over the lower part of the call (spec 037, R12–R17).
///
/// One page of grouped sections: Reactions, Developer options when the host has developer mode on,
/// and About. It had a pushed page for the developer options, but with one row behind it the push
/// was more motion than content, so every section is on the one page until there is enough to
/// warrant another.
///
/// Sized to its content, so the call stays in view above it and a row added later grows the sheet
/// with no number to change: the page reports its height and the sheet's one detent follows.
struct ElementCallPreferencesSheet: View {
    @Bindable var context: ElementCallScreenContext
    
    @Environment(\.elementCallStyle) private var style
    @State private var height: CGFloat = 300
    @State private var bottomInset: CGFloat = 0
    private let version: String
    private let coreVersion: String
    
    init(context: ElementCallScreenContext, version: String = ElementCallVersion.current, coreVersion: String = ElementCallVersion.core) {
        self.context = context
        self.version = version
        self.coreVersion = coreVersion
    }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 24) {
                reactions
                soundEffects
                if context.viewState.isDeveloperModeEnabled {
                    developerOptions
                }
                about
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
        .frame(maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
            if inset != bottomInset {
                bottomInset = inset
            }
        }
        .presentationDetents([.height(height + bottomInset)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(style.theme.bgCanvasDefault)
        // A container, or the identifier would replace every control's own inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.preferencesSheet)
    }
    
    private var header: some View {
        ZStack {
            Text(L10n.preferencesTitle)
                .font(style.theme.headingMDBold)
                .foregroundStyle(style.theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Spacer()
                Button { context.send(viewAction: .dismissPreferences) } label: { style.icons.icon(.close) }
                    .buttonStyle(ElementCallRoundButtonStyle())
                    .accessibilityLabel(L10n.actionClose)
                    .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.preferencesClose)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
    
    // MARK: - Sections
    
    /// One setting with three choices rather than web's two switches, so sound without the
    /// animation is not on offer (R13).
    private var reactions: some View {
        section(L10n.preferencesReactionsTitle) {
            HStack(spacing: 16) {
                rowTitle(L10n.preferencesReactionsShow, description: L10n.preferencesReactionsDescription)
                Spacer(minLength: 0)
                Picker(L10n.preferencesReactionsShow,
                       selection: Binding(get: { context.viewState.reactionsPreference },
                                          set: { context.send(viewAction: .setReactionsPreference($0)) })) {
                    ForEach(ElementCallReactionsPreference.allCases, id: \.self) { preference in
                        Text(Self.title(of: preference)).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .tint(style.theme.textSecondary)
                .fixedSize()
                .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.preferencesReactions)
            }
            .padding(.vertical, 10)
        }
    }
    
    /// Every effect's level, the ringback's excepted (R22, R23). Letting go plays one sound at it, so
    /// the choice can be heard without waiting for somebody to join or react (R24).
    private var soundEffects: some View {
        section(L10n.preferencesSoundEffects) {
            HStack(spacing: 12) {
                style.icons.icon(.volumeOn, size: .small)
                    .foregroundStyle(style.theme.iconSecondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { Double(context.viewState.soundEffectsVolume) },
                                      set: { context.send(viewAction: .setSoundEffectsVolume(Float($0))) }),
                       in: 0...1) { isEditing in
                    if !isEditing {
                        context.send(viewAction: .playSoundEffectsVolumeSample)
                    }
                }
                .tint(style.theme.textPrimary)
                .accessibilityLabel(L10n.preferencesSoundEffectsVolume)
                .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.preferencesSoundEffectsVolume)
            }
            .padding(.vertical, 12)
        }
    }
    
    /// Offered only with the host's developer mode (R16).
    private var developerOptions: some View {
        section(L10n.preferencesDeveloperOptions) {
            Toggle(isOn: Binding(get: { context.viewState.isTileStatsVisible },
                                 set: { _ in context.send(viewAction: .toggleTileStats) })) {
                rowTitle(L10n.preferencesTileStats, description: L10n.preferencesTileStatsDescription)
            }
            .tint(style.theme.bgAccentRest)
            .padding(.vertical, 10)
            .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.preferencesTileStats)
        }
    }
    
    /// Shown to everyone, as the menu used to, so a bug report can quote them (R17).
    private var about: some View {
        section(L10n.preferencesAbout) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.preferencesVersion(version))
                    .padding(.vertical, 12)
                divider
                Text(L10n.preferencesCoreVersion(coreVersion))
                    .padding(.vertical, 12)
            }
            .font(style.theme.bodyLG)
            .foregroundStyle(style.theme.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.preferencesVersion)
        }
    }
    
    static func title(of preference: ElementCallReactionsPreference) -> String {
        switch preference {
        case .off: L10n.preferencesReactionsOff
        case .withoutSound: L10n.preferencesReactionsSilent
        case .withSound: L10n.preferencesReactionsOn
        }
    }
    
    // MARK: - Building blocks
    
    /// A titled group of rows on a card.
    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(style.theme.bodySMSemibold)
                .foregroundStyle(style.theme.textSecondary)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                rows()
            }
            .padding(.horizontal, 16)
            .background(style.theme.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 12))
        }
    }
    
    /// A row's title, with what it does beneath it in the row, where the choice beside it is short
    /// enough to leave the room.
    private func rowTitle(_ title: String, description: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(style.theme.bodyLG)
                .foregroundStyle(style.theme.textPrimary)
            if let description {
                Text(description)
                    .font(style.theme.bodySM)
                    .foregroundStyle(style.theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private var divider: some View {
        Rectangle()
            .fill(style.theme.borderInteractiveSecondary.opacity(0.4))
            .frame(height: 1)
    }
}

// MARK: - Previews

struct ElementCallPreferencesSheet_Previews: PreviewProvider, TestablePreview {
    static func sheet(isDeveloperModeEnabled: Bool) -> some View {
        var state = ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group)
        state.isDeveloperModeEnabled = isDeveloperModeEnabled
        state.reactionsPreference = .withoutSound
        // Release versions change independently of the preview's layout.
        return ElementCallPreferencesSheet(context: .preview(state: state), version: "0.1.0-rc.14", coreVersion: "0.5.0-rc.9")
            // The whole frame, so the image is the sheet on the call's canvas rather than a dark
            // band between two white ones.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ElementCallStyle.stock.theme.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        sheet(isDeveloperModeEnabled: true)
            .previewDisplayName("Developer mode")
        sheet(isDeveloperModeEnabled: false)
            .previewDisplayName("Without developer mode")
    }
}
