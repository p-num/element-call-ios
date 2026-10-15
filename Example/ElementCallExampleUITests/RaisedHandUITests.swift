//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The raise hand button, driven by real touches (spec 009).
///
/// Whether it is offered, what it shows while a change is pending and where a hand is drawn are
/// `RaisedHandTests`, in process. What is here is what only a touch can answer: whether the button
/// in the bar takes the tap over the stage beneath it, in portrait, in landscape and in the
/// full-screen controls (009 R16, R30), and whether that tap stops at the button rather than also
/// reaching the tile behind or the full-screen chrome's own tap.
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
    
    private var handButton: XCUIElement {
        app.buttons["elementCall.raisedHand"]
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
    
    private func waitForLabel(_ label: String, on element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let matches = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
        return XCTWaiter().wait(for: [matches], timeout: timeout) == .completed
    }
    
    /// Raises, then lowers, and checks both our tile and the button agree each time.
    private func raiseAndLower() {
        XCTAssertTrue(waitUntilHittable(handButton), "the hand button is in the bar and can be tapped")
        XCTAssertEqual(handButton.label, "Raise hand")
        
        handButton.tap()
        XCTAssertTrue(waitForLabel("Lower hand", on: handButton), "the tap reached the button")
        XCTAssertTrue(ourHand.waitForExistence(timeout: 2), "and our tile shows the hand")
        
        handButton.tap()
        XCTAssertTrue(waitForLabel("Raise hand", on: handButton), "the same button lowers it (009 R2)")
        XCTAssertFalse(ourHand.exists)
    }
    
    func testTheHandButtonRaisesAndLowersOurHand() {
        launch("group")
        raiseAndLower()
    }
    
    /// Landscape starts with the chrome away and a tap on the stage brings it (014 R10, R14).
    func testTheHandButtonWorksInLandscape() {
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
    /// tile beneath before (AGENTS, "interactive glass"). A tap that went through would have done
    /// nothing visible to the button and might have opened a tile instead.
    func testATapOnTheHandButtonStaysOffTheStage() {
        launch("group")
        XCTAssertTrue(waitUntilHittable(handButton))
        
        handButton.tap()
        
        XCTAssertTrue(waitForLabel("Lower hand", on: handButton))
        XCTAssertTrue(tile("dan").exists, "still the stage, not one tile full screen")
        XCTAssertFalse(exitButton.exists)
    }
    
    /// The full-screen controls are the same bar over a picture that toggles the chrome on a tap. A
    /// tap on the hand button has to be the button's alone: the chrome stays up (009 R30).
    func testTheHandButtonWorksInTheFullScreenControls() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        bob.doubleTap()
        bob.tap()
        XCTAssertTrue(exitButton.waitForExistence(timeout: 3), "the chrome is up")
        XCTAssertTrue(waitUntilHittable(handButton))
        
        handButton.tap()
        
        XCTAssertTrue(waitForLabel("Lower hand", on: handButton), "the tap reached the button")
        XCTAssertTrue(exitButton.exists, "and not the picture behind it, which would have put the chrome away")
    }
}
