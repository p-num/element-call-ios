//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation

/// Accessibility identifiers for the call UI.
///
/// **These are public API.** An external interop test rig drives real builds of the host app
/// through them, so a rename is a breaking change for something outside this repository. Add
/// freely, but do not rename or remove without checking who depends on it.
///
/// Every identifier is prefixed so it cannot collide with a host's own.
public nonisolated enum ElementCallAccessibilityIdentifiers {
    private static let prefix = "elementCall"
    
    // MARK: Controls
    
    public static let hangUp = "\(prefix).hangUp"
    public static let microphone = "\(prefix).microphone"
    public static let camera = "\(prefix).camera"
    public static let audioOutput = "\(prefix).audioOutput"
    public static let screenShare = "\(prefix).screenShare"
    public static let minimize = "\(prefix).minimize"
    /// Leaves the full-screen tile. Spelled out rather than derived from its icon: it borrows the
    /// collapse glyph, and `control(for:)` maps that to `minimize`, which would leave two different
    /// buttons answering to one identifier.
    public static let exitFullscreen = "\(prefix).exitFullscreen"
    public static let more = "\(prefix).more"
    /// The hero stack's "1 of 3" pill on the spotlight. Set by hand on the view, like the top bar's
    /// buttons: it does not go through `control(for:)`. The dots under the spotlight have none on
    /// purpose: they are hidden from accessibility, so an identifier there would be a constant that
    /// reaches no element.
    public static let heroIndicator = "\(prefix).heroIndicator"
    /// The arrows on the landscape spotlight's edges, which step the stack there instead of the
    /// portrait dots. Set by hand, like the pill.
    public static let heroPrevious = "\(prefix).heroPrevious"
    public static let heroNext = "\(prefix).heroNext"
    
    // MARK: Structure
    
    public static let stage = "\(prefix).stage"
    public static let minimizedBar = "\(prefix).minimizedBar"
    public static let roomName = "\(prefix).roomName"
    public static let callState = "\(prefix).callState"
    
    /// A tile, identified by the member on it **and the stream it draws**.
    ///
    /// This is the break. A member publishing a camera and a screen share is two tiles now, so the
    /// member alone no longer names one. A camera tile keeps the exact string it has always had —
    /// that is what the external rig pins, and it is every case the rig has ever asked about — and a
    /// share carries its stream after a slash. So nothing that worked stops working; there is simply
    /// more on screen than there was, which a rig counting tiles to count people will notice.
    public static func tile(_ id: MatrixRTCTileID) -> String {
        switch id.kind {
        case .person: "\(prefix).tile.\(id.memberID)"
        default: "\(prefix).tile.\(id.memberID)/\(id.kind)"
        }
    }
    
    /// A member's camera tile, by member ID. Kept because it is what an external rig calls, and
    /// because "Bob's tile" has always meant his camera.
    public static func tile(memberID: String) -> String {
        tile(MatrixRTCTileID(memberID: memberID, kind: .person))
    }
    
    /// The control that shows a given icon. Derived rather than hand-written at each call site so a
    /// new control cannot quietly ship without one.
    static func control(for icon: ElementCallIcon) -> String {
        switch icon {
        case .endCall: hangUp
        case .micOn, .micOff: microphone
        case .videoCall, .videoCallOff: camera
        case .volumeOn, .volumeOff, .headphones, .bluetooth: audioOutput
        case .shareScreen: screenShare
        case .collapse: minimize
        case .overflow: more
        case .switchCamera: "\(prefix).switchCamera"
        case .raisedHand: "\(prefix).raisedHand"
        case .userProfile: "\(prefix).userProfile"
        }
    }
}
