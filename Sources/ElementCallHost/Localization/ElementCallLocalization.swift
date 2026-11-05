//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import Synchronization

/// Where the generated `L10n` looks its strings up. They come from the element-call Localazy
/// project's `mobile.json`, shared with Element Call Android; see CONTRIBUTING.md.
///
/// In the host's language, not the device's (feature-hq 036 R12). `Bundle.module` left to itself
/// resolves against the device's languages, and this package has translations its host may not: an
/// app shown in English on a French phone would get a French call screen. So the package's own
/// localizations are matched against those the host's bundle resolved to, which is also how a host
/// with an in-app language setting is followed.
package nonisolated enum ElementCallLocalization {
    /// Languages to look up in, in order, in place of the host's. For tests: the test runner's own
    /// bundle has only English, so without this nothing but English could ever be read.
    package static let languageOverride = Mutex<[String]?>(nil)
    
    private static let hostLanguages = Bundle.preferredLocalizations(from: Bundle.module.localizations,
                                                                     forPreferences: Bundle.main.preferredLocalizations)
    
    /// One per language, rather than a lookup that finds the `.lproj` again on every draw.
    private static let languageBundles = Mutex<[String: Bundle]>([:])
    
    /// The string for `key`, in the first language that has it and otherwise in English, which
    /// always does: a key that reaches the screen is a bug, never a fallback.
    package static func string(_ table: String, _ key: String, _ arguments: CVarArg...) -> String {
        let languages = languageOverride.withLock { $0 } ?? hostLanguages
        for language in languages + [developmentLanguage] {
            if let string = string(table, key, arguments, in: language) {
                return string
            }
        }
        return key
    }
    
    private static var developmentLanguage: String {
        Bundle.module.developmentLocalization ?? "en"
    }
    
    private static func string(_ table: String, _ key: String, _ arguments: [CVarArg], in language: String) -> String? {
        guard let bundle = bundle(for: language) else {
            return nil
        }
        let format = bundle.localizedString(forKey: key, value: nil, table: table)
        guard format != key else {
            return nil
        }
        // Formatted only when there is something to substitute, so a plain string's `%` stays
        // itself rather than being read as the start of a specifier.
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: language), arguments: arguments)
    }
    
    private static func bundle(for language: String) -> Bundle? {
        languageBundles.withLock { bundles in
            if let bundle = bundles[language] {
                return bundle
            }
            let bundle = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
            bundles[language] = bundle
            return bundle
        }
    }
}
