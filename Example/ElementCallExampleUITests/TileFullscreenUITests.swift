//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The gestures on a call tile, driven by real touches.
///
/// This is the one thing the package's own test target cannot do. `ElementCallStageLayoutTests`
/// proves the arrangement is right and the snapshots prove it is drawn right, but neither can tell a
/// double tap that reaches the tile from one that a gesture higher up claimed first, and that is the
/// failure this feature is prone to: the strip's paging drag and the tile's pan are attached to the
/// same view tree, and there is a `Button` inside the tile.
///
/// XCTest rather than swift-testing, because UI testing never moved: XCUIApplication drives a
/// separate process, which is exactly what swift-testing's in-process model cannot do.
final class TileFullscreenUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }
    
    private func launch(_ fixture: String) {
        app.launchArguments = ["-fixture", fixture]
        app.launch()
    }
    
    private func tile(_ user: String) -> XCUIElement {
        app.otherElements["elementCall.tile.@\(user):example.com:DEVICE"]
    }
    
    /// A member's *screen*, which is a second tile beside their camera rather than a state of it.
    private func share(_ user: String) -> XCUIElement {
        app.otherElements["elementCall.tile.@\(user):example.com:DEVICE/screenShare"]
    }
    
    /// A tile on another page of the strip is still in the hierarchy, just parked a screen's width
    /// away, so `exists` says nothing about which page is in view and a tap on one cannot land.
    /// Hittable is the question worth asking of anything on the strip.
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }
    
    /// Which tiles are actually on screen. Asked rather than worked out: how many fit on a page is
    /// the layout's business and it changes with the device, so a test that names the members it
    /// expects on page two is a test that breaks for reasons that have nothing to do with it.
    private func tilesOnScreen() -> Set<String> {
        let tiles = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "elementCall.tile."))
        return Set(tiles.allElementsBoundByAccessibilityElement.filter(\.isHittable).map(\.identifier))
    }
    
    /// Scrolls the grid by a swipe on one of its tiles and waits for it to settle: a swipe is a
    /// flick, and the grid goes on decelerating after the finger has gone. Settled is judged on
    /// whichever tile is nearest the middle of the screen at each look, not on the swiped one,
    /// which leaves the hierarchy altogether once it is a viewport away.
    private func scrollGrid(on element: XCUIElement) {
        element.swipeUp()
        let deadline = Date().addingTimeInterval(6)
        var last: (String, CGRect)?
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
            guard let middle = tileNearestTheMiddle() else { continue }
            let now = (middle.identifier, middle.frame)
            if let last, last.0 == now.0, last.1 == now.1 {
                return
            }
            last = now
        }
    }
    
    /// The tile whose centre is nearest the screen's, among the tiles nothing else overlaps: a grid
    /// row passing under the sticky spotlight is still hittable at its edge, and a double tap at
    /// its centre lands on the spotlight instead. The recording showed exactly that.
    private func tileNearestTheMiddle() -> XCUIElement? {
        let middle = app.frame.midY
        let frames = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "elementCall.tile."))
            .allElementsBoundByAccessibilityElement.filter(\.isHittable).map { ($0.identifier, $0.frame) }
        let clear = frames.filter { tile in !frames.contains { $0.0 != tile.0 && $0.1.intersects(tile.1) } }
        guard let nearest = clear.min(by: { abs($0.1.midY - middle) < abs($1.1.midY - middle) }) else { return nil }
        return app.otherElements[nearest.0]
    }
    
    private var exitButton: XCUIElement {
        app.buttons["elementCall.exitFullscreen"]
    }
    
    private var hangUpButton: XCUIElement {
        app.buttons["elementCall.hangUp"]
    }
    
    // MARK: - Going full screen and back
    
    func testDoubleTappingATileFillsTheScreenWithIt() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        XCTAssertTrue(tile("dan").exists, "the others are on the stage to begin with")
        
        bob.doubleTap()
        
        XCTAssertTrue(bob.waitForExistence(timeout: 2))
        XCTAssertFalse(tile("dan").exists, "full screen is one tile, not one tile on top of the rest")
    }
    
    func testDoubleTappingAgainComesBackToTheStage() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        
        bob.doubleTap()
        XCTAssertFalse(tile("dan").exists)
        
        bob.doubleTap()
        XCTAssertTrue(tile("dan").waitForExistence(timeout: 2), "the stage came back")
        XCTAssertFalse(exitButton.exists)
    }
    
    /// Full screen changes the stage's frame (the top bar goes, the picture runs under the status
    /// bar) and a scroller whose viewport grows clamps its offset without asking. Coming back has
    /// to land where you were, not at the top (spec 003 R63).
    func testTheGridKeepsItsOffsetAcrossFullScreen() throws {
        launch("listen_mode")
        let ours = tile("alice")
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        scrollGrid(on: ours)
        XCTAssertLessThan(ours.frame.minY, 0, "scrolled: our own tile has gone off the top")
        
        let chosen = try XCTUnwrap(tileNearestTheMiddle())
        let before = chosen.frame
        
        chosen.doubleTap()
        XCTAssertTrue(waitForDisappearance(of: ours), "went full screen from the scrolled grid")
        
        chosen.doubleTap()
        XCTAssertTrue(waitUntilHittable(chosen), "back on the stage")
        XCTAssertEqual(chosen.frame.minY, before.minY, accuracy: 2, "at the offset we left, not rewound to the top")
    }
    
    // MARK: - Chrome
    
    func testASingleTapRaisesAndLowersTheChrome() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        
        bob.doubleTap()
        XCTAssertFalse(exitButton.exists, "full screen starts with the picture and nothing else")
        
        bob.tap()
        XCTAssertTrue(exitButtonAppears(), "a tap brought the chrome up")
        XCTAssertTrue(hangUpButton.exists, "and the controls with it")
        
        bob.tap()
        XCTAssertTrue(waitForDisappearance(of: exitButton), "and another put it away")
    }
    
    func testTheExitButtonLeavesFullScreen() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        
        bob.doubleTap()
        bob.tap()
        XCTAssertTrue(exitButtonAppears())
        
        exitButton.tap()
        XCTAssertTrue(tile("dan").waitForExistence(timeout: 2), "back on the stage")
    }
    
    /// The chrome's visibility lives on the context rather than in a view's own state, so a
    /// rotation cannot forget it. Worth a test because that is an easy thing to lose later: put it
    /// in an @State on the screen and this breaks with nothing else to show for it.
    func testTheChromeSurvivesARotation() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        
        bob.doubleTap()
        bob.tap()
        XCTAssertTrue(exitButtonAppears(), "chrome up")
        
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        
        XCTAssertTrue(exitButton.waitForExistence(timeout: 3), "still up after rotating")
        XCTAssertTrue(hangUpButton.exists, "controls with it")
        XCTAssertFalse(tile("dan").exists, "and still full screen")
    }
    
    // MARK: - Gestures that must not collide
    
    /// A pinch is two fingers moving apart; the strip's paging drag is one finger moving sideways.
    /// They share a view tree, and the arrangement relies on full screen reporting a single page to
    /// keep the paging gesture out of the way.
    func testPinchingInFullScreenNeitherExitsNorPages() {
        launch("listen_mode")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        
        bob.doubleTap()
        XCTAssertTrue(waitForDisappearance(of: tile("dan")))
        
        bob.pinch(withScale: 3, velocity: 1)
        XCTAssertTrue(bob.exists, "still full screen")
        XCTAssertFalse(tile("dan").exists, "and still the only tile")
        
        bob.pinch(withScale: 0.2, velocity: -1)
        XCTAssertTrue(bob.exists, "pinching back out springs to the fitted size rather than leaving")
        XCTAssertFalse(tile("dan").exists)
    }
    
    /// The other half of the same arrangement: outside full screen the tile's own gestures must not
    /// have eaten the drag the grid scrolls with.
    func testTheGridStillScrollsWhenNotFullScreen() {
        launch("listen_mode")
        let ours = tile("alice")
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        let before = ours.frame
        scrollGrid(on: ours)
        XCTAssertLessThan(ours.frame.minY, before.minY - 40, "the tile's own gestures have not eaten the scroll")
    }
    
    /// A `Button` inside the tile has to keep its taps: child gestures beat the parent's, which is
    /// why the tile uses `.gesture` and not `.highPriorityGesture`.
    func testTappingTheFlipButtonDoesNotGoFullScreen() {
        launch("one_to_one")
        let alice = tile("alice")
        XCTAssertTrue(alice.waitForExistence(timeout: 10))
        let flip = app.buttons["Switch camera"].firstMatch
        XCTAssertTrue(flip.waitForExistence(timeout: 2))
        
        flip.doubleTap()
        
        // Both halves matter and only the second one has ever been wrong: the chrome is layered over
        // the gesture surface rather than inside it, so a tap that lands on the button is the
        // button's alone. Full screen shows the picture and nothing else, so the other person's tile
        // going away is what tells you the tile took the taps.
        XCTAssertTrue(flip.exists, "the button is still there to be tapped")
        XCTAssertTrue(tile("bob").exists, "still the one-to-one arrangement, not full screen")
    }
    
    /// Our own tile follows the camera button. The harness applies the tap to the view state
    /// itself, and it used to light the button alone, leaving our tile's picture (and so its flip
    /// button) where it was. The flip button is drawn only on our own tile with video, so it going
    /// and coming back is our tile following the camera.
    func testTheCameraButtonTurnsOurOwnPictureOffAndOn() {
        launch("one_to_one")
        XCTAssertTrue(tile("alice").waitForExistence(timeout: 10))
        let flip = app.buttons["Switch camera"].firstMatch
        XCTAssertTrue(flip.waitForExistence(timeout: 2))
        
        app.buttons["Turn camera off"].tap()
        XCTAssertTrue(flip.waitForNonExistence(timeout: 2), "our tile lost its picture with the camera")
        
        app.buttons["Turn camera on"].tap()
        XCTAssertTrue(flip.waitForExistence(timeout: 2), "our tile has its picture back")
    }
    
    // MARK: - With a picture in the tile
    
    /// The only case with a Metal surface actually drawing, which is a different thing from a tile
    /// with an avatar in it: the surface is resized by the animation, and what it does while that
    /// happens is not something an avatar can tell you. Pair it with the recording recipe in
    /// AGENTS.md when the move itself is what you need to look at.
    func testFullScreenWorksWithAPictureInTheTile() {
        launch("video")
        let carol = tile("carol")
        XCTAssertTrue(carol.waitForExistence(timeout: 10))
        
        carol.doubleTap()
        XCTAssertTrue(waitForDisappearance(of: tile("dan")), "full screen with the video mounted")
        
        carol.tap()
        XCTAssertTrue(exitButtonAppears())
        XCTAssertTrue(app.staticTexts["Carol"].exists)
        
        carol.doubleTap()
        XCTAssertTrue(tile("dan").waitForExistence(timeout: 3), "and back, with the picture intact")
    }
    
    // MARK: - Screen share
    
    /// A sharer is two tiles, and the one you double-tap is the one you get.
    ///
    /// This used to be a question of *size*: a big tile swapped a sharer's camera for their screen,
    /// so going full screen on what looked like their camera showed their screen, and there was no
    /// way to ask for the camera at all. The tile carries its own stream now, so there is nothing
    /// left to infer.
    func testASharerIsTwoTilesAndFullScreenTakesTheOneYouTapped() {
        launch("screen_share")
        XCTAssertTrue(share("frank").waitForExistence(timeout: 10))
        XCTAssertTrue(tile("frank").exists, "his camera is on the stage beside his screen")
        
        share("frank").doubleTap()
        share("frank").tap()
        XCTAssertTrue(exitButtonAppears())
        XCTAssertTrue(app.staticTexts["Frank (Screen share)"].waitForExistence(timeout: 2))
        
        share("frank").doubleTap()
        XCTAssertTrue(tile("frank").waitForExistence(timeout: 3))
        tile("frank").doubleTap()
        tile("frank").tap()
        XCTAssertTrue(exitButtonAppears())
        XCTAssertTrue(app.staticTexts["Frank"].waitForExistence(timeout: 2), "his camera, named as him")
    }
    
    /// The two tiles are addressable apart rather than collapsing into one element — which is what
    /// `tilesOnScreen` would silently do while the identifier named only the member, since it
    /// collects them into a `Set`.
    func testASharersTwoTilesAreCountedAsTwo() {
        launch("screen_share")
        XCTAssertTrue(share("frank").waitForExistence(timeout: 5))
        let onScreen = tilesOnScreen()
        XCTAssertTrue(onScreen.contains(share("frank").identifier))
        XCTAssertTrue(onScreen.contains(tile("frank").identifier))
    }
    
    /// A sharer's camera scrolled out of view must not take their screen with it.
    ///
    /// The transport releases a stream, and the stage used to ask it to release a *member*: scrolling
    /// the camera away therefore unsubscribed the screen filling the spotlight, a few seconds later,
    /// with a visible re-negotiation to undo. Nothing in-process can see that — the placements are
    /// all correct — so it takes a running app.
    func testScrollingAwayASharersCameraLeavesTheirScreenDrawing() {
        launch("share_on_long_grid")
        let ours = tile("alice")
        XCTAssertTrue(ours.waitForExistence(timeout: 5))
        scrollGrid(on: ours)
        XCTAssertTrue(share("frank").isHittable, "the hero is still on screen after the scroll")
    }
    
    // MARK: - Helpers
    
    private func exitButtonAppears() -> Bool {
        exitButton.waitForExistence(timeout: 2)
    }
    
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 3) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
