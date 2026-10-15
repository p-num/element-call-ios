//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// Whether a hand the core announced as raised makes a sound (spec 009, R34).
///
/// Which hands are announced at all is the core's: only one seen going up while we are in the call,
/// never the hands up when we arrive, a member arriving with one, or a hand moving to its owner's
/// refreshed membership. What is left here is R33: no sound where no hand is shown. Hands close
/// together are not throttled here but merged by the renderer, whose hand voice ignores a trigger
/// while it is still playing.
nonisolated enum RaisedHandSoundPolicy {
    /// False in a one-to-one call: one other person and no share of theirs, the UI's
    /// `ElementCallSmallCallLayout.isFullBleed` read off the core's order, since the Kit cannot see
    /// the UI's tiles. The two must agree, or a hand nobody can see is heard.
    static func shouldPlay(order: [MatrixRTCTileRef], localMemberID: String) -> Bool {
        let remote = order.filter { $0.id.memberID != localMemberID }
        return !(remote.count == 1 && remote[0].id.kind == .person)
    }
}
