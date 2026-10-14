//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Testing

nonisolated struct PictureInPictureCandidateTests {
    private let me = "@alice:example.org:ME"
    
    /// The spotlight names its own stream, so this is no longer a question of working out which of a
    /// member's streams was meant: the window continues the picture the stage is showing.
    @Test
    func theSpotlightsOwnStreamIsWhatTheWindowContinues() {
        let tiles = roster(tile("bob", kind: .screenShare), tile("bob", hasVideo: true), tile("carol", hasVideo: true))
        let share = MatrixRTCTileID(memberID: "bob", kind: .screenShare)
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: share) == share)
        let camera = MatrixRTCTileID(memberID: "bob", kind: .person)
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: camera) == camera)
    }
    
    @Test
    func fallsBackToTheHighestRankedVideoWhenTheSpotlightHasNone() {
        let tiles = roster(tile("bob"), tile("carol", hasVideo: true))
        let candidate = MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: MatrixRTCTileID(memberID: "bob"))
        #expect(candidate == MatrixRTCTileID(memberID: "carol", kind: .person))
    }
    
    /// A share can stop while the window is continuing it, and the stage takes a moment to catch up.
    /// The candidate has to notice that the tile it was told about is gone, rather than attaching to
    /// a stream nobody is sending.
    @Test
    func aSpotlightWhoseTileIsGoneFallsBackRatherThanAttachingToNothing() {
        let tiles = roster(tile("bob", hasVideo: true), tile("carol", hasVideo: true))
        let goneShare = MatrixRTCTileID(memberID: "bob", kind: .screenShare)
        let candidate = MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: goneShare)
        #expect(candidate == MatrixRTCTileID(memberID: "bob", kind: .person))
    }
    
    @Test
    func fallsBackToOwnCameraOnlyWhenAvailable() {
        let tiles = roster(tile("bob"))
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: nil) == MatrixRTCTileID(memberID: me, kind: .person))
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: false, spotlight: nil) == nil)
    }
    
    // MARK: - Exact (019 R15)
    
    /// A small call's speaker with their camera off is not swapped for whoever ranks first: the
    /// window shows the placeholder, which names them.
    @Test
    func anExactTileWithoutVideoGivesThePlaceholderNotSomebodyElse() {
        let tiles = roster(tile("bob"), tile("carol", hasVideo: true))
        let bob = MatrixRTCTileID(memberID: "bob")
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: bob, isExact: true) == nil)
        #expect(MatrixRTCMediaSession.pictureInPicturePlaceholderMemberID(tiles: tiles, spotlight: bob) == "bob")
        let carol = MatrixRTCTileID(memberID: "carol")
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: carol, isExact: true) == carol)
    }
    
    /// Exact only while the tile is in the call: one that has left falls back as before.
    @Test
    func anExactTileThatHasLeftFallsBack() {
        let tiles = roster(tile("carol", hasVideo: true))
        let candidate = MatrixRTCMediaSession.pictureInPictureCandidate(tiles: tiles, localMemberID: me, isLocalCameraAvailable: true, spotlight: MatrixRTCTileID(memberID: "bob"), isExact: true)
        #expect(candidate == MatrixRTCTileID(memberID: "carol", kind: .person))
    }
    
    /// Alone, the window shows our camera, or the placeholder with it off.
    @Test
    func ourselvesExactlyIsOurCameraOrNothing() {
        let own = MatrixRTCTileID(memberID: me, kind: .person)
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: .empty, localMemberID: me, isLocalCameraAvailable: true, spotlight: own, isExact: true) == own)
        #expect(MatrixRTCMediaSession.pictureInPictureCandidate(tiles: .empty, localMemberID: me, isLocalCameraAvailable: false, spotlight: own, isExact: true) == nil)
    }
    
    @Test
    func placeholderNamesTheSpotlightWhenItIsSomebodyElse() {
        let tiles = roster(tile("bob"), tile("carol"))
        #expect(MatrixRTCMediaSession.pictureInPicturePlaceholderMemberID(tiles: tiles, spotlight: MatrixRTCTileID(memberID: "carol")) == "carol")
    }
    
    /// Our own tile is never in the order, so a spotlight on us names nobody in it and the window
    /// falls back to the first person we are talking to.
    @Test
    func placeholderSkipsTheSpotlightWhenItIsUs() {
        let tiles = roster(tile("bob"))
        #expect(MatrixRTCMediaSession.pictureInPicturePlaceholderMemberID(tiles: tiles, spotlight: MatrixRTCTileID(memberID: me)) == "bob")
    }
    
    @Test
    func placeholderFallsBackToTheFirstRemoteMemberAndIsNilWhenAlone() {
        let tiles = roster(tile("bob"), tile("carol"))
        #expect(MatrixRTCMediaSession.pictureInPicturePlaceholderMemberID(tiles: tiles, spotlight: nil) == "bob")
        // A spotlight naming nobody in the call must not be shown either.
        #expect(MatrixRTCMediaSession.pictureInPicturePlaceholderMemberID(tiles: tiles, spotlight: MatrixRTCTileID(memberID: "dave")) == "bob")
        #expect(MatrixRTCMediaSession.pictureInPicturePlaceholderMemberID(tiles: .empty, spotlight: nil) == nil)
    }
    
    private func tile(_ memberID: String, kind: MatrixRTCTileKind = .person, hasVideo: Bool? = nil) -> MatrixRTCTile {
        MatrixRTCTile(id: MatrixRTCTileID(memberID: memberID, kind: kind),
                      userID: "@\(memberID):example.org",
                      isLocal: false,
                      isHero: kind == .screenShare,
                      hasVideo: hasVideo ?? (kind == .screenShare),
                      isSpeaking: false)
    }
    
    private func roster(_ tiles: MatrixRTCTile...) -> MatrixRTCTileRoster {
        MatrixRTCTileRoster(tiles)
    }
}
