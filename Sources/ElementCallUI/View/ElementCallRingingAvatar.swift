//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import SwiftUI

/// The person a direct call is ringing, large and centred on the stage until they answer (030 R15).
///
/// Drawn as a one-to-one call draws the other person with their camera off: the host's `.full`
/// avatar at the large tile's size, centred on the whole screen. So when they answer without video
/// nothing moves, and the change to the call is the avatar handing over to an identical one (R21).
///
/// Not a tile, because nobody has joined yet: it takes no touches, so a tap or a double tap on it is
/// the stage's, which does nothing while ringing (R38).
struct ElementCallRingingAvatar: View {
    @Environment(\.elementCallStyle) private var style
    let callee: ElementCallMemberProfile
    /// The room's name, which in a direct chat is the other person's, until their profile loads.
    let fallbackName: String
    
    private var name: String {
        callee.displayName ?? fallbackName
    }
    
    var body: some View {
        style.avatars.avatar(userID: callee.userID,
                             displayName: name,
                             avatarURL: callee.avatarURL,
                             size: .full)
            .scaledAvatar(to: ElementCallTileView.largeAvatarDiameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(style.strings.callingPerson(name))
    }
}
