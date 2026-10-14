//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Foundation
import Testing

/// Who gets a playback sink is a function of the tile roster, pinned here because it used to be a
/// function of the event stream -- and a lagged event stream silenced people.
struct RosterPlaybackTests {
    private let me = "@alice:example.com:ME"
    
    private func ref(_ member: String, kind: MatrixRTCTileKind = .person) -> MatrixRTCTileRef {
        MatrixRTCTileRef(id: MatrixRTCTileID(memberID: member, kind: kind), userID: "@\(member):example.com", isHero: kind == .screenShare)
    }
    
    /// A sharer is two tiles and one voice: their person tile is the candidate, their screen is not.
    @Test
    func everyRemotePersonTileIsACandidateOnce() {
        let order = [ref("frank", kind: .screenShare), ref("frank"), ref("bob")]
        #expect(MatrixRTCMediaSession.playbackCandidates(order, localMemberID: me) == ["frank", "bob"])
    }
    
    /// The order never holds our own tile, but the id guard holds even if it did.
    @Test
    func weAreNeverACandidate() {
        #expect(MatrixRTCMediaSession.playbackCandidates([ref(me)], localMemberID: me).isEmpty)
    }
}
