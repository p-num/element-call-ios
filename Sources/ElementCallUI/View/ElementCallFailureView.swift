//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import SwiftUI

/// What a failed call shows until the user closes it (034 R27): an icon, a title, why, and the way
/// out, the whole screen and nothing else, as Element Call web does. The stage and the controls
/// are gone because the call is: a control bar under a failure offered mute and camera on a call
/// that no longer existed.
///
/// Closing is the hang-up the controller holds the end for, so the host dismisses as it always has.
/// A failure with a way to fix it adds that as the primary action above Close, which drops to a
/// plain text button: Open settings for a refused microphone (042 R7), Use Room state for an MSC
/// join that failed (043 R18a).
struct ElementCallFailureView: View {
    /// The fix a failure offers, above Close.
    struct PrimaryAction {
        let title: String
        let identifier: String
        let perform: () -> Void
    }
    
    @Environment(\.elementCallStyle) private var style
    let failure: ElementCallFailure
    var primaryAction: PrimaryAction?
    let onClose: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            style.icons.icon(.error, size: .medium, relativeTo: nil)
                .foregroundStyle(style.theme.iconPrimary)
                .frame(width: 64, height: 64)
                .background(style.theme.bgSubtleSecondary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(failure.title)
                    .font(style.theme.headingMDBold)
                    .foregroundStyle(style.theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(failure.text)
                    .font(style.theme.bodyLG)
                    .foregroundStyle(style.theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let primaryAction {
                primaryButton(primaryAction.title, action: primaryAction.perform)
                    .accessibilityIdentifier(primaryAction.identifier)
                Button(action: onClose) {
                    Text(L10n.actionClose)
                        .font(style.theme.bodyLGSemibold)
                        .foregroundStyle(style.theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.failureClose)
            } else {
                primaryButton(L10n.actionClose, action: onClose)
                    .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.failureClose)
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.theme.bgCanvasDefault.ignoresSafeArea())
    }
    
    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(style.theme.bodyLGSemibold)
                .foregroundStyle(style.theme.iconOnSolidPrimary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(style.theme.bgActionPrimaryRest, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

struct ElementCallFailureView_Previews: PreviewProvider, TestablePreview {
    static func screen(_ failure: ElementCallFailure) -> some View {
        ElementCallFailureView(failure: failure,
                               primaryAction: ElementCallView.primaryAction(for: failure) { _ in },
                               onClose: { })
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        screen(.connectionLost(.budget))
            .previewDisplayName("Connection lost")
        screen(.joinRefused)
            .previewDisplayName("Join refused")
        screen(.other("Homeserver offers no LiveKit transport"))
            .previewDisplayName("Other")
        screen(.microphoneRefused)
            .previewDisplayName("Microphone refused")
        // The membership format may be the cause, and the screen offers the way back (043 R18, R18a).
        screen(.mscJoinFailed("Join refused: M_UNRECOGNIZED"))
            .previewDisplayName("MSC join failed")
    }
}
