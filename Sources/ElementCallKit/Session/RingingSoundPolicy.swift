//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// What a direct call sounds like while it rings and as it ends, read off the core's status
/// (spec 030, R23 and R25).
nonisolated enum RingingSoundPolicy {
    /// From the moment the ring is out until anything else happens. Not while it is still being
    /// sent: nobody's phone is ringing yet.
    static func playsRingback(_ status: MatrixRTCCallStatus) -> Bool {
        if case .calling(_, .ringing, _) = status {
            true
        } else {
            false
        }
    }
    
    /// Only the two ends the other side caused by not answering. A hang-up, or the other person
    /// leaving after the pickup, has no sound of its own here.
    static func endSound(_ status: MatrixRTCCallStatus) -> CallSoundEffect? {
        switch status {
        case .ended(.declined): .declined
        case .ended(.unanswered): .timeout
        default: nil
        }
    }
}
