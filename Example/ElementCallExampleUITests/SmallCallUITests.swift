//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// Our own floating tile, alone or one to one (spec 019), driven by real touches.
///
/// Where it sits, how big, and which corner a release picks are `ElementCallSmallCallLayoutTests`,
/// in process. What is here is what only a touch can answer: whether the drag reaches the tile past
/// the stage's own taps, whether a tap on the flip button is still the button's while a drag around
/// it is the tile's, and whether the tile's taps stop at the tile.
final class SmallCallUITests: XCTestCase {
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
    
    private func launch(_ fixture: String) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-fixture", fixture]
        app.launch()
        XCTAssertTrue(ours.waitForExistence(timeout: 10))
    }
    
    private func tile(_ user: String) -> XCUIElement {
        app.otherElements["elementCall.tile.@\(user):example.com:DEVICE"]
    }
    
    /// Alice is us in every fixture.
    private var ours: XCUIElement {
        tile("alice")
    }
    
    private var flip: XCUIElement {
        app.buttons["Switch camera"].firstMatch
    }
    
    private var window: XCUIElement {
        app.windows.firstMatch
    }
    
    /// Which quadrant of the screen our tile's centre is in, as `top left` and so on.
    private func corner() -> String {
        let frame = ours.frame
        let screen = window.frame
        return (frame.midY < screen.midY ? "top" : "bottom") + " " + (frame.midX < screen.midX ? "left" : "right")
    }
    
    /// True within the time a spring takes; CI is slow, so generously.
    private func eventually(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }
    
    /// From a point on our tile to a point on the screen, held at the end so it is a drop and not
    /// a flick.
    private func drag(from start: XCUICoordinate, toScreen x: CGFloat, _ y: CGFloat) {
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
    }
    
    private var ourCentre: XCUICoordinate {
        ours.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
    
    // MARK: - Dragging (R2, R21)
    
    func testDroppingOurTileInAQuadrantMovesItToThatCorner() {
        launch("one_to_one")
        XCTAssertEqual(corner(), "bottom right", "it starts bottom right (R18)")
        
        drag(from: ourCentre, toScreen: 0.3, 0.3)
        XCTAssertTrue(eventually { self.corner() == "top left" }, "dropped in the top left quadrant, it went to \(corner())")
        
        drag(from: ourCentre, toScreen: 0.7, 0.7)
        XCTAssertTrue(eventually { self.corner() == "bottom right" }, "and back, it went to \(corner())")
    }
    
    /// R21: however far the finger goes, the tile stays on the stage.
    func testOurTileCannotBeDraggedOffTheStage() {
        launch("one_to_one")
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0)).withOffset(CGVector(dx: -200, dy: -200))
        ourCentre.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(eventually { self.corner() == "top left" })
        XCTAssertTrue(window.frame.contains(ours.frame), "the whole tile is on screen: \(ours.frame)")
    }
    
    /// R21 with inertia: a short flick upwards carries it to the top corner, where the same distance
    /// held still would have dropped it back at the bottom.
    func testAFlickCarriesOurTileToTheCornerItWasThrownTowards() {
        launch("one_to_one")
        let up = ourCentre.withOffset(CGVector(dx: 0, dy: -120))
        ourCentre.press(forDuration: 0.1, thenDragTo: up, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(eventually { self.corner() == "bottom right" }, "a slow, short drag stays put")
        
        ourCentre.press(forDuration: 0.05, thenDragTo: up, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(eventually { self.corner() == "top right" }, "a flick went to \(corner())")
    }
    
    // MARK: - The flip button (R22)
    
    func testTappingTheFlipButtonSwitchesCameraAndLeavesTheTileWhereItIs() {
        launch("one_to_one")
        XCTAssertTrue(flip.waitForExistence(timeout: 2))
        let before = ours.frame
        XCTAssertEqual(flip.value as? String, "Front camera")
        
        flip.tap()
        
        XCTAssertTrue(eventually { self.flip.value as? String == "Back camera" }, "the tap reached the button")
        XCTAssertEqual(ours.frame, before, "and moved nothing")
    }
    
    /// The one this layout could get wrong in either direction: the drag is around the whole tile,
    /// button included, so it must win once the finger moves, and must not let the button fire too.
    func testADragThatStartsOnTheFlipButtonMovesTheTileAndKeepsTheCamera() {
        launch("one_to_one")
        XCTAssertTrue(flip.waitForExistence(timeout: 2))
        
        drag(from: flip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), toScreen: 0.3, 0.3)
        
        XCTAssertTrue(eventually { self.corner() == "top left" }, "the tile moved, to \(corner())")
        XCTAssertEqual(flip.value as? String, "Front camera", "and the camera did not switch")
    }
    
    // MARK: - Taps (R14, R19, R23)
    
    /// R23: a tap on our tile does nothing, the chrome included, once the screen's wait for a
    /// second tap is over.
    func testATapOnOurTileLeavesTheChromeAlone() {
        launch("one_to_one")
        let hangUp = app.buttons["elementCall.hangUp"]
        XCTAssertTrue(hangUp.isHittable)
        
        ours.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        Thread.sleep(forTimeInterval: 1)
        
        XCTAssertTrue(hangUp.isHittable, "the control bar is still up")
    }
    
    /// R14: full screen is for the other people, not for us.
    func testDoubleTappingOurTileDoesNotGoFullScreenButTheirsDoes() {
        launch("one_to_one")
        ours.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).doubleTap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(tile("bob").exists, "still the one-to-one arrangement")
        XCTAssertFalse(app.buttons["elementCall.exitFullscreen"].exists)
        
        tile("bob").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).doubleTap()
        XCTAssertTrue(ours.waitForNonExistence(timeout: 5), "Bob full screen, our tile gone with the rest")
    }
    
    /// R19: our tile keeps clear of the control bar, and follows it down when it hides.
    func testOurTileFollowsTheControlBar() {
        launch("one_to_one")
        let raised = ours.frame.maxY
        
        tile("bob").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(eventually { self.ours.frame.maxY > raised + 40 }, "it moved down with the bar: \(ours.frame.maxY) from \(raised)")
        
        tile("bob").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(eventually { abs(self.ours.frame.maxY - raised) < 1 }, "and back up with it")
    }
    
    /// R30 as amended: in a one-to-one call the top bar goes with the control bar in portrait too,
    /// for the whole picture; with more people it stays, as 017 R30 has it.
    func testTheTopBarHidesWithTheControlBarOnlyOneToOne() {
        launch("one_to_one")
        let minimize = app.buttons["elementCall.minimize"]
        let isUp = { minimize.exists && self.window.frame.contains(minimize.frame) }
        XCTAssertTrue(isUp())
        
        tile("bob").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(eventually { !isUp() }, "the top bar went with the control bar")
        tile("bob").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(eventually { isUp() }, "and came back with it")
        
        app.terminate()
        launch("small_three")
        tile("bob").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(eventually { !self.app.buttons["elementCall.hangUp"].isHittable }, "the control bar went")
        XCTAssertTrue(isUp(), "and the top bar stayed")
    }
    
    // MARK: - Arrangement through a rotation (R2, R16, R20)
    
    /// R20: the corner survives a rotation, our tile floating in both orientations one to one.
    func testOurTileKeepsItsCornerThroughARotation() {
        launch("one_to_one")
        drag(from: ourCentre, toScreen: 0.3, 0.3)
        XCTAssertTrue(eventually { self.corner() == "top left" })
        
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(eventually { self.window.frame.width > self.window.frame.height })
        XCTAssertTrue(eventually { self.corner() == "top left" }, "still top left in landscape: \(corner())")
        
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(eventually { self.window.frame.width < self.window.frame.height })
        XCTAssertTrue(eventually { self.corner() == "top left" }, "and back in portrait: \(corner())")
    }
    
    /// R2, R5: from three tiles our tile is inline, the same size as the others, in both
    /// orientations, and first.
    func testFromThreeTilesOurTileIsInline() {
        launch("small_three")
        XCTAssertTrue(eventually { abs(self.ours.frame.width - self.tile("bob").frame.width) < 1 },
                      "inline in portrait: \(ours.frame.size) and \(tile("bob").frame.size)")
        XCTAssertLessThan(ours.frame.minY, tile("bob").frame.minY, "and first")
        
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(eventually { self.window.frame.width > self.window.frame.height })
        XCTAssertTrue(eventually { abs(self.ours.frame.width - self.tile("bob").frame.width) < 1 }, "and in landscape")
    }
    
    // MARK: - Nothing scrolls (R30)
    
    func testAVerticalSwipeMovesNothing() {
        launch("small_four")
        let bob = tile("bob")
        let before = bob.frame
        
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        
        XCTAssertEqual(bob.frame, before)
    }
}
