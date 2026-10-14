//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Testing

/// What spec 009 R34 leaves to the platforms once the core has announced a new hand: silence where
/// R33 shows none. Which hands are announced is the core's and tested there.
nonisolated struct RaisedHandSoundPolicyTests {
    private func person(_ name: String) -> MatrixRTCTileRef {
        MatrixRTCTileRef(id: MatrixRTCTileID(memberID: name, kind: .person), userID: "@\(name):example.com")
    }
    
    private func share(_ name: String) -> MatrixRTCTileRef {
        MatrixRTCTileRef(id: MatrixRTCTileID(memberID: name, kind: .screenShare), userID: "@\(name):example.com")
    }
    
    private func plays(_ order: [MatrixRTCTileRef]) -> Bool {
        RaisedHandSoundPolicy.shouldPlay(order: order, localMemberID: "me")
    }
    
    @Test
    func aOneToOneCallIsSilent() {
        #expect(!plays([person("me"), person("bob")]))
        // Our own share is not a tile on the stage, so it is still one-to-one there.
        #expect(!plays([person("me"), share("me"), person("bob")]))
    }
    
    @Test
    func threePeoplePlay() {
        #expect(plays([person("me"), person("bob"), person("carol")]))
    }
    
    /// Their share puts the call in the grid, where the hand is shown on their camera tile.
    @Test
    func twoPeopleWithTheirShareOnTheStagePlay() {
        #expect(plays([person("me"), person("bob"), share("bob")]))
    }
}
