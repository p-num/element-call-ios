//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Testing

/// The gated affordances are gated in two places that have to agree: the view omits them, and the
/// controller refuses them. This pins the controller half. The view half of the developer toggle is
/// inside a `Menu`, whose contents a snapshot cannot see, so that part is held by the compiler and
/// by reading the diff; the screen share button is in the control bar, which the previews do cover.
struct DeveloperModeTests {
    @Test
    func developerModeOffRefusesTheStatsOverlay() {
        let controller = ElementCallController.fake(connection: .connected, options: ElementCallOptions())
        
        #expect(!controller.options.isDeveloperModeEnabled)
        controller.toggleTileStats()
        #expect(!controller.isTileStatsVisible)
    }
    
    @Test
    func developerModeOnAllowsIt() {
        let controller = ElementCallController.fake(connection: .connected)
        
        controller.toggleTileStats()
        #expect(controller.isTileStatsVisible)
        controller.toggleTileStats()
        #expect(!controller.isTileStatsVisible)
    }
    
    /// Defaults matter more than usual here: a host now states only what it wants to change, so a
    /// member defaulting the wrong way is a behaviour change nobody writes down.
    @Test
    func defaultsAreTheConservativeAnswer() {
        let options = ElementCallOptions()
        
        #expect(options.isPictureInPictureEnabled)
        #expect(options.membershipFormat == .roomState)
        #expect(!options.isDeveloperModeEnabled)
        #expect(!options.isScreenSharingEnabled)
        #expect(!options.isAutomaticPictureInPictureForAudioCallsEnabled)
    }
    
    /// Screen sharing is a separate axis from developer mode on purpose, so a host can ship one
    /// without the other. If these two ever collapse into one flag, this is what says they had not.
    @Test
    func screenSharingAndDeveloperModeAreIndependent() {
        let sharingOnly = ElementCallOptions(isScreenSharingEnabled: true)
        #expect(sharingOnly.isScreenSharingEnabled)
        #expect(!sharingOnly.isDeveloperModeEnabled)
        
        let developerOnly = ElementCallOptions(isDeveloperModeEnabled: true)
        #expect(developerOnly.isDeveloperModeEnabled)
        #expect(!developerOnly.isScreenSharingEnabled)
    }
    
    /// The fake host supports everything, so a preview renders the fullest chrome. A preview that
    /// silently lost a control because a new gate defaulted off is exactly the regression this
    /// catches, and it is invisible in a snapshot until someone looks at the image.
    @Test
    func theFakeHostEnablesEverything() {
        let controller = ElementCallController.fake(connection: .joining)
        
        #expect(controller.options.isDeveloperModeEnabled)
        #expect(controller.options.isScreenSharingEnabled)
    }
    
    /// The version is what a bug report quotes, so an empty or placeholder-looking string is worth
    /// catching here rather than in a screenshot.
    @Test
    func theVersionIsStamped() {
        #expect(!ElementCallVersion.current.isEmpty)
        #expect(ElementCallVersion.current.first?.isNumber == true)
        #expect(ElementCallVersion.core.first?.isNumber == true)
    }
}
