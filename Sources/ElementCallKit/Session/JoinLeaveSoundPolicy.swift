//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// Whether an announced join or leave makes a sound.
///
/// Which changes are announced at all is the core's: nothing for the roster we arrive to, nothing
/// while our own membership is missing, nothing after the call ended. What is left here is what the
/// spec leaves to the platforms, so both can test it the same way: the participant cap, and the
/// 500 ms throttle per kind.
nonisolated struct JoinLeaveSoundPolicy {
    /// Web's `THROTTLE_SOUND_EFFECT_MS`. Measured from the last sound of the same kind *starting*, so a
    /// burst plays once rather than being queued, and a join never holds back a leave.
    static let throttle: Duration = .milliseconds(500)
    
    /// Above this many participants after the change, nothing plays.
    var participantCap: Int
    
    private var lastPlayed: [CallSoundEffect: Duration] = [:]
    private var isSilenced = false
    
    init(participantCap: Int) {
        self.participantCap = participantCap
    }
    
    /// `participantCount` is the core's count after the whole change, ourselves included; `now` is
    /// on the call's clock.
    mutating func shouldPlay(_ sound: CallSoundEffect, participantCount: Int, at now: Duration) -> Bool {
        guard !isSilenced, participantCount <= participantCap else { return false }
        if let last = lastPlayed[sound], now - last < Self.throttle {
            return false
        }
        lastPlayed[sound] = now
        return true
    }
    
    /// For good: the call has ended for us, and teardown must not sound like everyone leaving.
    mutating func silence() {
        isSilenced = true
    }
}
