//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Foundation
import Testing

/// Which streams a stats sample asks the core about. The set is what bounds the cost of the poll
/// in a big call, so it is pinned here rather than left to whatever the stage happens to draw.
struct ReceiveStatsPollingTests {
    private let me = "@alice:example.com:ME"
    
    private func tile(_ member: String, kind: MatrixRTCTileKind = .person) -> MatrixRTCTile {
        MatrixRTCTile(id: MatrixRTCTileID(memberID: member, kind: kind),
                      userID: "@\(member):example.com",
                      isLocal: false,
                      isHero: kind == .screenShare,
                      hasVideo: true,
                      isSpeaking: false)
    }
    
    /// A sharer is two tiles and one voice: their camera, their screen, and their microphone once.
    @Test
    func aSharersTwoTilesAskForTheCameraTheScreenAndOneMicrophone() {
        let roster = MatrixRTCTileRoster([tile("frank", kind: .screenShare), tile("frank")])
        let streams = MatrixRTCMediaSession.streamsToPoll(tiles: roster, released: [], localMemberID: me)
        #expect(streams == [MatrixRTCStreamRef(memberID: "frank", kind: .screenShare),
                            MatrixRTCStreamRef(memberID: "frank", kind: .camera),
                            MatrixRTCStreamRef(memberID: "frank", kind: .microphone)])
    }
    
    /// A released tile is one nobody is drawing, so nothing about it -- not even its owner's audio,
    /// unless another of their tiles is still on the stage -- is worth a round trip.
    @Test
    func aReleasedTileIsNotPolled() {
        let roster = MatrixRTCTileRoster([tile("bob"), tile("carol")])
        let streams = MatrixRTCMediaSession.streamsToPoll(tiles: roster, released: [tile("carol").id], localMemberID: me)
        #expect(streams == [MatrixRTCStreamRef(memberID: "bob", kind: .camera),
                            MatrixRTCStreamRef(memberID: "bob", kind: .microphone)])
    }
    
    /// Our own streams have nothing to receive.
    @Test
    func ourOwnTilesAreNeverPolled() {
        let roster = MatrixRTCTileRoster([tile(me)])
        #expect(MatrixRTCMediaSession.streamsToPoll(tiles: roster, released: [], localMemberID: me).isEmpty)
    }
}
