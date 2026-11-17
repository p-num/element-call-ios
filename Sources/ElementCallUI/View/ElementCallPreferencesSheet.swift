//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// The user's in-call preferences: Reactions, Sound effects and About (037, 043 R9). What only a
/// developer needs is in ``ElementCallDeveloperOptionsSheet``, its own entry in the settings menu.
struct ElementCallPreferencesSheet: View {
    @Bindable var context: ElementCallScreenContext
    /// Injected so the previews can pin them: the real values move with every release and core bump.
    var version = ElementCallVersion.current
    var coreVersion = ElementCallVersion.core
    
    @Environment(\.elementCallStyle) private var style
    
    var body: some View {
        ElementCallSettingsSheet(context: context,
                                 title: L10n.preferencesTitle,
                                 sheetIdentifier: ElementCallAccessibilityIdentifiers.preferencesSheet,
                                 closeIdentifier: ElementCallAccessibilityIdentifiers.preferencesClose) {
            reactions
            soundEffects
            about
        }
    }
    
    // MARK: - Sections
    
    /// Two switches, as on web (043 R6). The sound one is greyed while reactions are hidden, keeping
    /// the position the user left it in, so turning reactions back on brings their sound back as it
    /// was (R7). Bound to what the user chose, never to what plays: bound to that, it would read off
    /// while greyed and write off when reactions came back.
    private var reactions: some View {
        ElementCallSettingsSection(title: L10n.preferencesReactionsTitle) {
            ElementCallSettingsToggle(title: L10n.preferencesReactionsShow,
                                      description: L10n.preferencesReactionsShowDescription,
                                      isOn: context.viewState.showsReactions,
                                      identifier: ElementCallAccessibilityIdentifiers.preferencesShowReactions) {
                context.send(viewAction: .setShowsReactions($0))
            }
            ElementCallSettingsDivider()
            ElementCallSettingsToggle(title: L10n.preferencesReactionsSounds,
                                      description: L10n.preferencesReactionsSoundsDescription,
                                      isOn: context.viewState.playsReactionSounds,
                                      isEnabled: context.viewState.showsReactions,
                                      identifier: ElementCallAccessibilityIdentifiers.preferencesPlayReactionSounds) {
                context.send(viewAction: .setPlaysReactionSounds($0))
            }
        }
    }
    
    /// Every effect's level, the ringback's excepted (037 R22, R23). Letting go plays one sound at it,
    /// so the choice can be heard without waiting for somebody to join or react (R24).
    private var soundEffects: some View {
        ElementCallSettingsSection(title: L10n.preferencesSoundEffects) {
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
    
    /// Shown to everyone, so a bug report can quote them (037 R17).
    private var about: some View {
        ElementCallSettingsSection(title: L10n.preferencesAbout) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.preferencesVersion(version))
                    .padding(.vertical, 12)
                ElementCallSettingsDivider()
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
}

// MARK: - Previews

struct ElementCallPreferencesSheet_Previews: PreviewProvider, TestablePreview {
    static func sheet(showsReactions: Bool) -> some View {
        var state = ElementCallPreviewFixtures.connected(tiles: ElementCallPreviewFixtures.group)
        state.showsReactions = showsReactions
        return ElementCallPreferencesSheet(context: .preview(state: state), version: "1.2.3", coreVersion: "4.5.6")
            // The whole frame, so the image is the sheet on the call's canvas rather than a dark
            // band between two white ones.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ElementCallStyle.stock.theme.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        sheet(showsReactions: true)
            .previewDisplayName("Reactions on")
        // The sound switch greyed, still on: the position the user left it in (043 R7).
        sheet(showsReactions: false)
            .previewDisplayName("Reactions hidden")
    }
}
