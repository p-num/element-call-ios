//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

public extension EnvironmentValues {
    /// The host's colours, fonts, icons, avatars and text.
    ///
    /// Threaded through the environment rather than every initialiser because almost every view in
    /// the call needs some of it, and the default keeps previews and snapshots working with no host.
    @Entry var elementCallStyle: ElementCallStyle = .stock
}

/// Where a tile's pictures come from when there is no call to pull them from.
///
/// Nil in a shipping build, which is the only state it is ever in there: a real screen has a
/// ``MatrixRTCMediaSession`` and never consults this. It exists so the example harness can put moving video
/// on the real stage, because everything the renderer does — fitting against filling, zoom, pan, and
/// the shape of the picture through a resize — is invisible in a harness whose tiles are all avatars,
/// and that is exactly the part that is hardest to look at closely in a real call.
public nonisolated struct ElementCallPreviewVideo: Sendable {
    public let attach: @MainActor @Sendable (VideoFrameSlot, String, MatrixRTCStreamKind) -> Void
    public let detach: @MainActor @Sendable (VideoFrameSlot) -> Void
    
    public init(attach: @escaping @MainActor @Sendable (VideoFrameSlot, String, MatrixRTCStreamKind) -> Void,
                detach: @escaping @MainActor @Sendable (VideoFrameSlot) -> Void) {
        self.attach = attach
        self.detach = detach
    }
}

public extension EnvironmentValues {
    @Entry var elementCallPreviewVideo: ElementCallPreviewVideo?
    /// Whether the floating controls use liquid glass where the system has it. On by default and
    /// in every shipping build; the snapshot harness turns it off, because an offscreen render of
    /// glass in a landscape frame comes out blank and a reference of the flat fallback at least
    /// says where the buttons are. Glass itself is checked on a device.
    @Entry var elementCallGlassEnabled = true
    /// How long after the user stops scrolling the chrome a scroll hid comes back (017 R20). The
    /// default in every shipping build; the example harness lengthens it for its UI tests, which
    /// check the chrome is away after a scroll and on a slow CI runner did not get to look within
    /// two seconds, so they saw it already back.
    @Entry var elementCallChromeReturnDelay: Duration = .seconds(2)
}
