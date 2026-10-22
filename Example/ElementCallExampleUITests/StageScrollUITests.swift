//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The grid's scroll, driven by real touches: what scrolls, what stays put, and which gesture wins
/// where two are listening on the same surface (spec 003 R26, R27, R45, R64, R65).
///
/// In `Example/` for the reason every UI test here is: gesture arbitration is invisible from inside
/// the process. A drag that is declared correctly and never arrives, because the scroller above the
/// tile claimed the touch first, looks identical to a working one to a unit test.
final class StageScrollUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }
    
    /// Portrait, and settled, before the app comes up: the simulator keeps whatever orientation
    /// the previous test left, and an app launched mid-rotation lays out twice, with the tiles a
    /// test had just found gone in between.
    private func launch(_ fixture: String) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-fixture", fixture]
        app.launch()
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, window.frame.width > window.frame.height {
            Thread.sleep(forTimeInterval: 0.2)
        }
    }
    
    private func tile(_ user: String) -> XCUIElement {
        app.otherElements["elementCall.tile.@\(user):example.com:DEVICE"]
    }
    
    private func share(_ user: String) -> XCUIElement {
        app.otherElements["elementCall.tile.@\(user):example.com:DEVICE/screenShare"]
    }
    
    /// The grid scrolls vertically under a spotlight that keeps its place (R26, R27): after a drag
    /// up on the grid, a tile that was on screen has moved up and the spotlight has not moved.
    func testTheGridScrollsAndTheSpotlightStaysPut() {
        launch("share_on_long_grid")
        let spotlight = share("frank")
        XCTAssertTrue(spotlight.waitForExistence(timeout: 5))
        let spotlightBefore = spotlight.frame
        let ours = tile("alice")
        XCTAssertTrue(ours.waitForExistence(timeout: 3))
        XCTAssertTrue(ours.isHittable)
        let oursBefore = ours.frame
        
        ours.swipeUp()
        
        XCTAssertLessThan(ours.frame.minY, oursBefore.minY - 40, "our own tile scrolls with the grid (R28)")
        XCTAssertEqual(spotlight.frame.minY, spotlightBefore.minY, accuracy: 1, "the spotlight is a sticky header (R27)")
        XCTAssertTrue(spotlight.isHittable)
    }
    
    /// The same on a grid longer than the composed band, and checked *while* the grid is still
    /// decelerating: rows entering and leaving the band open an animation on the stack, and the
    /// spotlight used to ride it — lagging the finger and springing back to the top afterwards,
    /// which a check after everything has settled cannot see. Listen mode here: twenty-three remote
    /// members and Carol speaking, so the spotlight is her camera tile.
    func testTheSpotlightStaysPutWhileALongGridScrolls() {
        launch("listen_mode")
        let spotlight = tile("carol")
        XCTAssertTrue(spotlight.waitForExistence(timeout: 5))
        let before = spotlight.frame
        
        tile("alice").swipeUp()
        var seen = [CGFloat]()
        for _ in 0..<6 {
            seen.append(spotlight.frame.minY)
            Thread.sleep(forTimeInterval: 0.15)
        }
        
        XCTAssertTrue(seen.allSatisfy { abs($0 - before.minY) <= 1 }, "the spotlight moved during the scroll: \(seen)")
        XCTAssertEqual(spotlight.frame.minY, before.minY, accuracy: 1)
    }
    
    /// A vertical drag that starts on the spotlight does not scroll the grid (R64).
    func testADragOnTheSpotlightDoesNotScrollTheGrid() {
        launch("share_on_long_grid")
        let spotlight = share("frank")
        XCTAssertTrue(spotlight.waitForExistence(timeout: 5))
        let ours = tile("alice")
        let oursBefore = ours.frame
        
        spotlight.swipeUp()
        
        XCTAssertEqual(ours.frame.minY, oursBefore.minY, accuracy: 1, "the grid did not move")
    }
    
    /// A horizontal swipe on the spotlight switches the shown hero, clamped at both ends (R22, R23).
    func testAHorizontalSwipeOnTheSpotlightSwitchesTheShownHero() {
        launch("two_shares")
        let frank = share("frank")
        let grace = share("grace")
        XCTAssertTrue(frank.waitForExistence(timeout: 5))
        XCTAssertTrue(frank.isHittable, "the first hero is shown")
        XCTAssertFalse(grace.exists, "the other is not drawn at all (R24)")
        XCTAssertEqual(app.descendants(matching: .any)["elementCall.heroIndicator"].label, "1 of 2")
        
        frank.swipeLeft()
        XCTAssertTrue(grace.waitForExistence(timeout: 3))
        XCTAssertTrue(grace.isHittable, "the second hero is shown")
        XCTAssertFalse(frank.exists)
        
        grace.swipeLeft()
        XCTAssertTrue(grace.isHittable, "the stack does not wrap")
        
        grace.swipeRight()
        XCTAssertTrue(frank.waitForExistence(timeout: 3))
        XCTAssertTrue(frank.isHittable, "and back")
        XCTAssertEqual(app.descendants(matching: .any)["elementCall.heroIndicator"].label, "1 of 2")
    }
    
    /// In landscape the stack is switched by the arrows on the spotlight's edges (R22), disabled at
    /// the end they point past (R23). Real touches, because the arrows are siblings above the
    /// spotlight in a scroll view, which is two chances for a tap to be claimed by something else.
    func testTheArrowsSwitchTheShownHeroInLandscape() {
        launch("two_shares")
        XCUIDevice.shared.orientation = .landscapeLeft
        // Back before the next test launches, and settled: a launch mid-rotation lays out for
        // the wrong shape and the test after this one found no tiles at all.
        defer { XCUIDevice.shared.orientation = .portrait }
        let frank = share("frank")
        let grace = share("grace")
        XCTAssertTrue(frank.waitForExistence(timeout: 5))
        let previous = app.buttons["elementCall.heroPrevious"]
        let next = app.buttons["elementCall.heroNext"]
        XCTAssertTrue(next.waitForExistence(timeout: 3), "the arrows exist in landscape")
        XCTAssertFalse(previous.isEnabled, "nothing before the first hero")
        
        next.tap()
        XCTAssertTrue(grace.waitForExistence(timeout: 3), "next shows the second hero")
        XCTAssertFalse(next.isEnabled, "nothing after the last hero")
        
        previous.tap()
        XCTAssertTrue(frank.waitForExistence(timeout: 3), "previous shows the first again")
    }
    
    /// A double tap with no movement enters fullscreen even immediately after a scroll (R65).
    func testADoubleTapRightAfterAScrollGoesFullScreen() throws {
        launch("listen_mode")
        let ours = tile("alice")
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        ours.swipeUp()
        // Wholly below the spotlight and wholly on screen, not merely hittable: XCUITest calls a
        // tile scrolled under the sticky spotlight hittable, and the double tap then lands on the
        // spotlight and takes Carol full screen. Which tile sits there depends on how far the
        // swipe went, which the chrome hiding on scroll changed.
        let spotlight = tile("carol").frame
        let window = app.windows.firstMatch.frame
        let visible = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "elementCall.tile."))
            .allElementsBoundByAccessibilityElement.filter(\.isHittable)
        let clear = visible.filter { $0.frame.minY >= spotlight.maxY && window.contains($0.frame) }
        let chosen = try XCTUnwrap(clear.first, "a tile clear of the spotlight")
        let other = try XCTUnwrap(visible.first { $0.identifier != chosen.identifier })
        chosen.doubleTap()
        let gone = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: other)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 3), .completed, "everything but the chosen tile left the stage")
    }
    
    /// A drag that starts on the control bar does not scroll the grid (R45).
    func testADragOnTheControlBarDoesNotScrollTheGrid() {
        launch("listen_mode")
        let ours = tile("alice")
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        let oursBefore = ours.frame
        let hangUp = app.buttons["elementCall.hangUp"]
        XCTAssertTrue(hangUp.isHittable)
        
        hangUp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: hangUp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6)))
        
        XCTAssertEqual(ours.frame.minY, oursBefore.minY, accuracy: 1, "the grid did not move")
    }
}
