//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
import Foundation
import Testing

/// The strings downloaded from Localazy reach the call screen, with their placeholders filled, and a
/// language the package has no translation for falls back to English rather than to a key.
@Suite("Localization")
struct LocalizationTests {
    @Test
    func stringsAreReadFromThePackage() {
        #expect(L10n.you == "You")
        #expect(ElementCallFailure.joinTimedOut.text == "Your server didn\u{2019}t respond in time.")
    }
    
    /// Localazy's `%1$s` arrives as `%1$@`; a placeholder left unconverted would draw as garbage.
    @Test
    func placeholdersAreFilled() {
        #expect(L10n.a11yCalling("Alice") == "Calling Alice")
        #expect(L10n.heroPosition(2, 3) == "2 of 3")
        #expect(L10n.a11yHandRaisedPosition(4) == "Hand raised, number 4 in the queue")
    }
    
    @Test
    func aLanguageWithoutTranslationsFallsBackToEnglish() {
        ElementCallLocalization.languageOverride.withLock { $0 = ["xx"] }
        defer { ElementCallLocalization.languageOverride.withLock { $0 = nil } }
        
        #expect(L10n.callEnded == "Call ended")
    }
    
    /// A key Localazy does not have is shown as itself, which is loud enough to be caught in review
    /// rather than quietly reading as some other string.
    @Test
    func anUnknownKeyIsShownAsItself() {
        #expect(ElementCallLocalization.string("Localizable", "element_call_no_such_key") == "element_call_no_such_key")
    }
}
