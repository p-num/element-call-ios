//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// Where the user's in-call preferences are kept, which the call reads when it starts and writes
/// when the user changes one.
///
/// A port rather than an ``ElementCallOptions`` member: options are the host's, stated once, while
/// these are the user's, changed mid-call and expected back next week (037 R14, R15; 043 R8). A host
/// that supplies nothing gets ``ElementCallUserDefaultsPreferencesStore``; one that wants them in its
/// own settings implements this, which is also how a host controls the membership format (043 R13).
public protocol ElementCallPreferencesStoreProtocol: AnyObject {
    /// Whether received reactions rise as bubbles; on by default (043 R6, R8).
    var showsReactions: Bool { get set }
    /// Whether received reactions play their sound. Remembered while ``showsReactions`` is off, and
    /// ignored then: a reaction with no bubble plays nothing (043 R7). On by default.
    var playsReactionSounds: Bool { get set }
    /// How loud the call's sound effects play, 0 to 1 of the call's level; half by default, as on
    /// Element Call web (037 R22).
    var soundEffectsVolume: Float { get set }
    /// How the next call's membership is published. The only thing that picks it: the host passes no
    /// format of its own (043 R13). Room state by default, which Element Call web speaks (R13a).
    var membershipFormat: MatrixRTCMembershipFormat { get set }
    /// The codec the next call publishes video with; Auto by default (043 R16).
    var videoCodec: MatrixRTCVideoCodec { get set }
}

/// The preferences in `UserDefaults`: kept on this device, surviving a restart, shared with nothing
/// (037 R14).
///
/// The three-way reactions setting that came before the two switches (`…preferences.reactions`) is
/// neither read nor removed: the native call is behind a flag, and carrying it over is a non-goal of
/// 043. Reading it here would be exactly that migration.
public final class ElementCallUserDefaultsPreferencesStore: ElementCallPreferencesStoreProtocol {
    static let showsReactionsKey = "io.element.call.preferences.showReactions"
    static let playsReactionSoundsKey = "io.element.call.preferences.playReactionSounds"
    static let soundEffectsVolumeKey = "io.element.call.preferences.soundEffectsVolume"
    static let membershipFormatKey = "io.element.call.preferences.membershipFormat"
    static let videoCodecKey = "io.element.call.preferences.videoCodec"
    
    private let defaults: UserDefaults
    
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }
    
    public var showsReactions: Bool {
        get { defaults.object(forKey: Self.showsReactionsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showsReactionsKey) }
    }
    
    public var playsReactionSounds: Bool {
        get { defaults.object(forKey: Self.playsReactionSoundsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.playsReactionSoundsKey) }
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
    
    public var membershipFormat: MatrixRTCMembershipFormat {
        get { defaults.string(forKey: Self.membershipFormatKey).flatMap(MatrixRTCMembershipFormat.init(rawValue:)) ?? .roomState }
        set { defaults.set(newValue.rawValue, forKey: Self.membershipFormatKey) }
    }
    
    public var videoCodec: MatrixRTCVideoCodec {
        get { defaults.string(forKey: Self.videoCodecKey).flatMap(MatrixRTCVideoCodec.init(rawValue:)) ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Self.videoCodecKey) }
    }
}
