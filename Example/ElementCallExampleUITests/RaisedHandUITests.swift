//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The raise hand control, driven by real touches (spec 009).
///
/// Whether it is offered, what it shows and where a hand is drawn are `RaisedHandTests`, in
/// process. What is here is what only a touch can answer: whether the bar's `…` and the More
/// sheet's hand row take their taps over the stage beneath, in portrait, in landscape and in the
/// full-screen controls (009 R16, R30), and whether those taps stop there rather than also
/// reaching the tile behind or the full-screen chrome's own tap. In `group` the hand shares the
/// sheet with reactions, so it is never a button of its own in the bar.
final class RaisedHandUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }
    
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }
    
    private func launch(_ fixture: String, orientation: UIDeviceOrientation = .portrait) {
        XCUIDevice.shared.orientation = orientation
        app.launchArguments = ["-fixture", fixture]
        app.launch()
        XCTAssertTrue(tile("alice").waitForExistence(timeout: 10))
    }
    
    private func tile(_ user: String) -> XCUIElement {
        app.otherElements["elementCall.tile.@\(user):example.com:DEVICE"]
    }
    
    private var moreButton: XCUIElement {
        app.buttons["elementCall.controlsMore"]
    }
    
    /// The More sheet's row, which exists only while the sheet is up.
    private var handRow: XCUIElement {
        app.buttons["elementCall.raisedHand"]
    }
    
    /// The banner's Cancel, which is in the bar for as long as our hand is up (009 R2).
    private var bannerCancel: XCUIElement {
        app.buttons["elementCall.lowerHand"]
    }
    
    /// The badge on our own tile, found by what VoiceOver hears, which is also the proof that it
    /// reached a view at all. Nobody else in `group` has a hand up, so ours is first in the queue.
    private var ourHand: XCUIElement {
        tile("alice").descendants(matching: .any)["Hand raised, number 1 in the queue"]
    }
    
    private var exitButton: XCUIElement {
        app.buttons["elementCall.exitFullscreen"]
    }
    
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }
    
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
    
    /// `…`, then the hand row, which says what it will do and closes the sheet once tapped.
    private func tapHandRow(expecting label: String) {
        XCTAssertTrue(waitUntilHittable(moreButton), "the `…` is in the bar and can be tapped")
        moreButton.tap()
        XCTAssertTrue(waitUntilHittable(handRow), "the tap opened the More sheet")
        XCTAssertEqual(handRow.label, label)
        handRow.tap()
        XCTAssertTrue(waitUntilGone(handRow), "the row closes the sheet")
    }
    
    private func raise() {
        tapHandRow(expecting: "Raise hand")
        XCTAssertTrue(waitUntilHittable(bannerCancel), "the tap reached the row and the banner says so")
    }
    
    /// Raises, then lowers through the same row, and checks our tile agrees each time.
    private func raiseAndLower() {
        raise()
        XCTAssertTrue(ourHand.waitForExistence(timeout: 2), "and our tile shows the hand")
        
        tapHandRow(expecting: "Lower hand")
        XCTAssertTrue(waitUntilGone(bannerCancel), "the same row lowers it (009 R2)")
        XCTAssertFalse(ourHand.exists)
    }
    
    func testTheHandRowRaisesAndLowersOurHand() {
        launch("group")
        raiseAndLower()
    }
    
    /// Landscape starts with the chrome away and a tap on the stage brings it (014 R10, R14).
    func testTheHandRowWorksInLandscape() {
        launch("group", orientation: .landscapeLeft)
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, window.frame.width <= window.frame.height {
            Thread.sleep(forTimeInterval: 0.2)
        }
        // The arrangement moves after the window does.
        Thread.sleep(forTimeInterval: 0.8)
        
        tile("bob").tap()
        // Past the double-tap window, or the button's tap would be the second half of one.
        Thread.sleep(forTimeInterval: 0.5)
        raiseAndLower()
    }
    
    /// The bar floats over the grid, and a button over the stage's content has lost its taps to the
    /// tile beneath before (AGENTS, "interactive glass"), as has a sheet's row to what is under the
    /// sheet. A tap that went through would have opened a tile instead.
    func testTheTapsThatRaiseTheHandStayOffTheStage() {
        launch("group")
        
        raise()
        
        XCTAssertTrue(tile("dan").exists, "still the stage, not one tile full screen")
        XCTAssertFalse(exitButton.exists)
    }
    
    /// The full-screen controls are the same bar over a picture that toggles the chrome on a tap.
    /// Each tap — `…`, the row, the banner's Cancel — has to be its own: the chrome stays up
    /// (009 R30). Bob's picture hides our tile, so the banner is what says the hand is up.
    func testTheHandWorksInTheFullScreenControls() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        bob.doubleTap()
        bob.tap()
        XCTAssertTrue(exitButton.waitForExistence(timeout: 3), "the chrome is up")
        
        raise()
        XCTAssertTrue(exitButton.exists, "and not the picture behind it, which would have put the chrome away")
        
        bannerCancel.tap()
        XCTAssertTrue(waitUntilGone(bannerCancel), "the banner's Cancel lowers the hand")
        XCTAssertTrue(exitButton.exists, "and that tap was the banner's alone")
    }
}
