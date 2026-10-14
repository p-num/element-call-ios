//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallUI
import Testing

/// The harness applies the control bar's taps to the view state itself, and our own tile has to
/// follow them the way the live composition makes it: the camera tap used to light the button and
/// leave our tile on its avatar, while Android's sample drew the picture.
@MainActor
struct HarnessLocalMediaTests {
    private typealias Fixtures = ElementCallPreviewFixtures
    
    private func ownTile(_ context: ElementCallScreenContext) -> ElementCallTile? {
        context.viewState.tiles.first { $0.isLocal }
    }
    
    @Test
    func theCameraButtonTurnsOurTilesVideoOnAndOff() {
        let context = ElementCallScreenContext.harness(state: Fixtures.connected(tiles: Fixtures.group))
        #expect(ownTile(context)?.hasVideo == false)
        
        context.send(viewAction: .toggleCamera)
        #expect(context.viewState.isCameraEnabled)
        #expect(ownTile(context)?.hasVideo == true)
        
        context.send(viewAction: .toggleCamera)
        #expect(ownTile(context)?.hasVideo == false)
    }
    
    @Test
    func theMicrophoneButtonMutesOurTile() {
        let context = ElementCallScreenContext.harness(state: Fixtures.connected(tiles: Fixtures.group))
        
        context.send(viewAction: .toggleMicrophone)
        #expect(ownTile(context)?.isMicrophoneMuted == true)
        
        context.send(viewAction: .toggleMicrophone)
        #expect(ownTile(context)?.isMicrophoneMuted == false)
    }
    
    /// Only ours: everyone else's badges are their own business.
    @Test
    func otherTilesAreLeftAlone() {
        let context = ElementCallScreenContext.harness(state: Fixtures.connected(tiles: Fixtures.group))
        let before = context.viewState.tiles.filter { !$0.isLocal }
        
        context.send(viewAction: .toggleCamera)
        context.send(viewAction: .toggleMicrophone)
        
        #expect(context.viewState.tiles.filter { !$0.isLocal } == before)
    }
}
