//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// What the call does with the reactions it receives, as the user chose it (037 R13).
public nonisolated enum ElementCallReactionsPreference: String, Sendable, CaseIterable {
    // In the order the menu offers them, the most first: each step takes something away.
    /// Bubbles and sounds: Element Call web's default too. "On" in the menu.
    case withSound
    /// Bubbles, no sound. "Silent" in the menu.
    case withoutSound
    /// Nothing shown, nothing played.
    case off
    
    var mode: MatrixRTCReactionsMode {
        switch self {
        case .off: .off
        case .withoutSound: .withoutSound
        case .withSound: .withSound
        }
    }
}

/// Where the user's in-call preferences are kept, which the call reads when it starts and writes
/// when the user changes one.
///
/// A port rather than an ``ElementCallOptions`` member: options are the host's, stated once, while
/// these are the user's, changed mid-call and expected back next week (037 R14, R15). A host that
/// supplies nothing gets ``ElementCallUserDefaultsPreferencesStore``; one that wants them in its own
/// settings implements this.
public protocol ElementCallPreferencesStoreProtocol: AnyObject {
    var reactions: ElementCallReactionsPreference { get set }
    /// How loud the call's sound effects play, 0 to 1 of the call's level; half by default, as on
    /// Element Call web (037 R22).
    var soundEffectsVolume: Float { get set }
}

/// The preferences in `UserDefaults`: kept on this device, surviving a restart, shared with nothing
/// (037 R14).
public final class ElementCallUserDefaultsPreferencesStore: ElementCallPreferencesStoreProtocol {
    static let reactionsKey = "io.element.call.preferences.reactions"
    static let soundEffectsVolumeKey = "io.element.call.preferences.soundEffectsVolume"
    
    private let defaults: UserDefaults
    
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    public var reactions: ElementCallReactionsPreference {
        get {
            defaults.string(forKey: Self.reactionsKey).flatMap(ElementCallReactionsPreference.init(rawValue:)) ?? .withSound
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.reactionsKey)
        }
    }
    
    public var soundEffectsVolume: Float {
        get {
            guard let volume = defaults.object(forKey: Self.soundEffectsVolumeKey) as? Float else { return 0.5 }
            return min(max(volume, 0), 1)
        }
        set {
            defaults.set(min(max(newValue, 0), 1), forKey: Self.soundEffectsVolumeKey)
        }
    }
}
