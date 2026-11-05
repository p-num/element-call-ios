//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCallHost
import SwiftUI

/// The ongoing call, shrunk to a bar at the top of the app. Tapping it restores the full screen.
///
/// The host places this itself, because only the host knows where the top of its own chrome is. It
/// is offered whenever the system window is not available, which arrives as
/// ``ElementCallControllerAction/pictureInPictureUnavailable``.
///
/// That is no longer about whether anyone has video — an audio call minimizes to the window too,
/// showing the avatar placeholder. What is left is the cases that were never about video: a host
/// that turned the window off, a device that cannot show one, and a screen share, which gives up
/// Picture in Picture for its duration.
public struct ElementCallMinimizedBar: View {
    private let controller: ElementCallController
    private let onTap: () -> Void
    
    @Environment(\.elementCallStyle) private var style
    @State private var roomName: String
    
    public init(controller: ElementCallController, onTap: @escaping () -> Void) {
        self.controller = controller
        self.onTap = onTap
        roomName = controller.room?.displayName ?? L10n.call
    }
    
    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                style.icons.icon(.videoCall, size: .small, relativeTo: .bodySMSemibold)
                Text(roomName)
                    .lineLimit(1)
                // In the timer's place while anything is interrupted: the bar's one text line has
                // room for one of them, and an outage is the more useful (034 R37). Tapping still
                // restores the call rather than opening the list, which lives on the call screen.
                if isInterrupted {
                    style.icons.icon(.info, size: .small, relativeTo: .bodySMSemibold)
                        .accessibilityHidden(true)
                    Text(L10n.interruptions)
                        .lineLimit(1)
                } else if let connectedAt = controller.connectedAt {
                    Text(connectedAt, style: .timer)
                        .monospacedDigit()
                }
                Spacer()
                style.icons.icon(controller.call?.isMicrophoneMuted == true ? .micOff : .micOn,
                                 size: .small,
                                 relativeTo: .bodySMSemibold)
                Text(L10n.actionReturnIos)
            }
            .font(style.theme.bodySMSemibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(style.theme.bgAccentRest, in: Capsule())
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .buttonStyle(.plain)
        // The bar's own label replaces what is drawn in it, so the indicator is said here or not
        // at all.
        .accessibilityLabel(isInterrupted ? L10n.a11yReturnToCallInterruptedIos(L10n.interruptions) : L10n.a11yReturnToCallIos)
        .accessibilityIdentifier(ElementCallAccessibilityIdentifiers.minimizedBar)
        .environment(\.elementCallStyle, controller.style)
        .onReceive(namePublisher) { roomName = $0 }
    }
    
    private var isInterrupted: Bool {
        !controller.interruptions.isEmpty
    }
    
    /// A room opened moments ago may not have its name yet, so the bar follows it rather than
    /// capturing whatever was known when the call started.
    private var namePublisher: AnyPublisher<String, Never> {
        controller.room?.displayNamePublisher ?? Empty().eraseToAnyPublisher()
    }
}
