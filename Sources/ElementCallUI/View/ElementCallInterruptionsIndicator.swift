//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import SwiftUI

/// The service interruptions indicator, and the list it opens (034 R35, R36).
///
/// One indicator however many causes, rather than a banner per cause, and never colour alone. It
/// is not chrome: it stays while the chrome is hidden, because an outage is exactly when a user
/// looks up to see why the call went quiet.
struct ElementCallInterruptionsIndicator: View {
    @Environment(\.elementCallStyle) private var style
    let interruptions: [ElementCallInterruption]
    @State private var isListPresented = false
    
    var body: some View {
        Button { isListPresented = true } label: {
            // An info glyph, the label, and an arrow for the list it opens, on liquid glass over the
            // stage, as the design draws it. Interactive glass, because plain glass over the stage
            // takes no taps (see AGENTS.md).
            HStack(spacing: 8) {
                style.icons.icon(.info, size: .small, relativeTo: .bodySMSemibold)
                    .accessibilityHidden(true)
                Text(L10n.interruptions)
                    .font(style.theme.bodySMSemibold)
                    .lineLimit(1)
                style.icons.icon(.chevronRight, size: .small, relativeTo: .bodySMSemibold)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(style.theme.textPrimary)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            // Tinted dark: clear glass over a bright picture left the label unreadable.
            .elementCallGlass(in: Capsule(), fallback: style.theme.bgCanvasDefaultLevel.opacity(0.9), tint: .black.opacity(0.4), isInteractive: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.interruptions)
        // A popover even on a phone, where a sheet would cover the call the list is about.
        .popover(isPresented: $isListPresented) {
            ElementCallInterruptionsList(interruptions: interruptions)
                .presentationCompactAdaptation(.popover)
        }
        // The list follows the causes in place, and goes on its own only with the last of them
        // (R36). The indicator itself goes then too, but a popover can outlive its anchor.
        .onChange(of: interruptions.isEmpty) { _, isEmpty in
            if isEmpty {
                isListPresented = false
            }
        }
    }
}

/// The entries, one per kind of trouble, in the order the core's causes are grouped (R13, R23,
/// R29). Read when focused; never announced by themselves (R40).
struct ElementCallInterruptionsList: View {
    @Environment(\.elementCallStyle) private var style
    let interruptions: [ElementCallInterruption]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(interruptions, id: \.self) { interruption in
                Text(interruption.text)
                    .font(style.theme.bodySM)
                    .foregroundStyle(style.theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(style.theme.bgCanvasDefaultLevel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.interruptionsList)
    }
}

extension ElementCallInterruption {
    /// An entry's text. The lapse changes what the server entry says rather than adding an entry
    /// of its own (R13).
    var text: String {
        switch self {
        case .ownServer(let isMembershipLapsed):
            isMembershipLapsed ? L10n.interruptionOwnServerLapsed : L10n.interruptionOwnServer
        case .ownMedia:
            L10n.interruptionOwnMedia
        case .othersMedia:
            L10n.interruptionOthersMedia
        }
    }
}

// MARK: - Previews

struct ElementCallInterruptionsIndicator_Previews: PreviewProvider, TestablePreview {
    static func list(_ interruptions: [ElementCallInterruption]) -> some View {
        ElementCallInterruptionsList(interruptions: interruptions)
            .environment(\.colorScheme, .dark)
    }
    
    static var previews: some View {
        ElementCallInterruptionsIndicator(interruptions: [.ownMedia])
            .padding()
            .background(ElementCallStyle.stock.theme.bgCanvasDefault)
            .environment(\.colorScheme, .dark)
            .previewDisplayName("Indicator")
        list([.othersMedia])
            .previewDisplayName("One entry")
        list([.ownServer(isMembershipLapsed: false), .othersMedia])
            .previewDisplayName("Server and others")
        list([.ownServer(isMembershipLapsed: true), .ownMedia, .othersMedia])
            .previewDisplayName("Every entry, lapsed")
    }
}
