//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// What a fling through a call of two hundred costs, as the system counts it: hitch time over
/// scroll time, from the scroll signposts UIKit already emits.
///
/// Here rather than in the package because it needs a real fling, and only on a device because a
/// simulator's frame timing is the Mac's: the numbers would mean nothing and CI would pay for them.
/// Run it against a **Release** build. A debug build measures the unoptimised Swift, which is not
/// what anybody scrolls, and that is how Android first measured seven times the jank its release
/// build has. It asserts nothing; Xcode keeps a baseline per device if one is set.
final class ScrollPerformanceUITests: XCTestCase {
    func testFlingingAGridOfTwoHundred() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Scroll hitches are only measured on a device.")
        #else
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-fixture", "two_hundred"]
        app.launch()
        // Starting on a grid tile, not the scroller's centre: a drag that starts on the spotlight is
        // the spotlight's, and never scrolls the grid (R64).
        let start = app.otherElements["elementCall.tile.@member1:example.com:DEVICE"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let grid = app.scrollViews.firstMatch
        
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            grid.swipeUp(velocity: .fast)
            stopMeasuring()
            // Back to the top, unmeasured, so every iteration flings through the same rows.
            grid.swipeDown(velocity: .fast)
        }
        #endif
    }
}
