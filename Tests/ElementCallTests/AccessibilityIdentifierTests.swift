//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
@testable import ElementCallUI
import Testing

/// The identifiers are consumed by an interop test rig outside this repository, which means they are
/// API and a rename breaks someone else's build.
///
/// The exact strings are asserted on purpose. A rename should fail here and make whoever did it
/// decide deliberately to break the rig, rather than finding out when the rig goes red.
@Suite("Accessibility identifiers")
nonisolated struct AccessibilityIdentifierTests {
    @Test("The published identifiers keep their exact spelling")
    func spelling() {
        #expect(ElementCallAccessibilityIdentifiers.hangUp == "elementCall.hangUp")
        #expect(ElementCallAccessibilityIdentifiers.microphone == "elementCall.microphone")
        #expect(ElementCallAccessibilityIdentifiers.camera == "elementCall.camera")
        #expect(ElementCallAccessibilityIdentifiers.audioOutput == "elementCall.audioOutput")
        #expect(ElementCallAccessibilityIdentifiers.screenShare == "elementCall.screenShare")
        #expect(ElementCallAccessibilityIdentifiers.minimize == "elementCall.minimize")
        #expect(ElementCallAccessibilityIdentifiers.exitFullscreen == "elementCall.exitFullscreen")
        #expect(ElementCallAccessibilityIdentifiers.more == "elementCall.more")
        #expect(ElementCallAccessibilityIdentifiers.heroIndicator == "elementCall.heroIndicator")
        #expect(ElementCallAccessibilityIdentifiers.heroPrevious == "elementCall.heroPrevious")
        #expect(ElementCallAccessibilityIdentifiers.heroNext == "elementCall.heroNext")
        #expect(ElementCallAccessibilityIdentifiers.stage == "elementCall.stage")
        #expect(ElementCallAccessibilityIdentifiers.minimizedBar == "elementCall.minimizedBar")
        #expect(ElementCallAccessibilityIdentifiers.roomName == "elementCall.roomName")
        #expect(ElementCallAccessibilityIdentifiers.callState == "elementCall.callState")
    }
    
    /// The camera spelling is the one an external rig pins, and it has not moved. A share is a
    /// second tile with the same member on it, so it needs a spelling of its own — and the two must
    /// differ, or anything collecting identifiers into a set counts one person's two tiles as one.
    @Test("A tile is addressable by the member on it and the stream it draws")
    func tile() {
        #expect(ElementCallAccessibilityIdentifiers.tile(memberID: "@bob:example.com:DEVICE")
            == "elementCall.tile.@bob:example.com:DEVICE")
        #expect(ElementCallAccessibilityIdentifiers.tile(MatrixRTCTileID(memberID: "@bob:example.com:DEVICE", kind: .person))
            == "elementCall.tile.@bob:example.com:DEVICE")
        #expect(ElementCallAccessibilityIdentifiers.tile(MatrixRTCTileID(memberID: "@bob:example.com:DEVICE", kind: .screenShare))
            == "elementCall.tile.@bob:example.com:DEVICE/screenShare")
    }
    
    /// Every control derives its identifier from its icon, so this is what stops a new control from
    /// shipping without one.
    @Test("Every icon resolves to a prefixed, non-empty identifier")
    func everyIconIsAddressable() {
        for icon in ElementCallIcon.allCases {
            let identifier = ElementCallAccessibilityIdentifiers.control(for: icon)
            #expect(identifier.hasPrefix("elementCall."), "\(icon) is not prefixed")
            #expect(identifier.count > "elementCall.".count, "\(icon) has an empty identifier")
        }
    }
    
    /// Two icons may share an identifier when they are two states of one control, mute against
    /// unmute for instance, but a control must never share with an unrelated one.
    @Test("Controls that are not paired states have distinct identifiers")
    func distinctness() {
        let paired: [Set<ElementCallIcon>] = [[.micOn, .micOff],
                                              [.videoCall, .videoCallOff],
                                              [.volumeOn, .volumeOff, .headphones, .bluetooth]]
        var seen = [String: ElementCallIcon]()
        for icon in ElementCallIcon.allCases {
            let identifier = ElementCallAccessibilityIdentifiers.control(for: icon)
            if let other = seen[identifier] {
                let isPair = paired.contains { $0.contains(icon) && $0.contains(other) }
                #expect(isPair, "\(icon) and \(other) share \(identifier) but are not paired states")
            }
            seen[identifier] = icon
        }
    }
}
