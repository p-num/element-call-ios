//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// When the stage's chrome shows and hides (spec 017), driven by real touches.
///
/// The rules themselves are `ElementCallChromeVisibilityTests`, in process. What is here is what
/// only a touch can answer: whether a tap reaches the stage past the tiles' own gestures and the
/// scroller, whether a control keeps its tap, and whether the scroller reports the user's scrolling
/// and nothing else. The control bar is probed by hang up and the top bar by minimize: in landscape
/// they go together (R1), and in portrait the top bar stays (R30). Up means on screen rather than
/// present: the chrome stays mounted and slides off screen.
final class ChromeVisibilityUITests: XCTestCase {
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
    
    /// Long enough that chrome a scroll hid is still away when a test looks, however slow the
    /// runner. Every query walks the whole tree, and over two hundred tiles on CI a few of them took
    /// longer than the real two seconds, so the test saw the chrome already back.
    private static let heldReturnDelay: TimeInterval = 60
    /// For a test that waits for the return: long enough to see it go first, short enough to wait
    /// out. Eight seconds was not: CI ran these about five times slower than a Mac, and one look at
    /// the tree took longer than that.
    private static let observableReturnDelay: TimeInterval = 30
    
    private func launch(_ fixture: String, chromeReturnDelay: TimeInterval? = nil) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-fixture", fixture]
        if let chromeReturnDelay {
            app.launchArguments += ["-chromeReturnDelay", String(chromeReturnDelay)]
        }
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
    
    private var hangUp: XCUIElement {
        app.buttons["elementCall.hangUp"]
    }
    
    private var minimize: XCUIElement {
        app.buttons["elementCall.minimize"]
    }
    
    /// Whether a piece of chrome is up: on screen, as opposed to slid off the edge it is on. Not
    /// `exists`, because the chrome stays mounted and is always in the tree. Not `isHittable`
    /// either: after a rotation it reported the control bar as unhittable while a real touch on it
    /// hung up the call.
    private func isUp(_ element: XCUIElement) -> Bool {
        element.exists && app.windows.firstMatch.frame.contains(element.frame)
    }
    
    /// The chrome is up or away, within the time a slide takes. The top bar goes with the control bar
    /// in landscape only; in portrait it never leaves (R30).
    private func waitForChrome(visible: Bool, timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        let topBarVisible = visible || window.frame.width <= window.frame.height
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, isUp(hangUp) != visible || isUp(minimize) != topBarVisible {
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(isUp(hangUp), visible, "the control bar is \(visible ? "up" : "away")", file: file, line: line)
        XCTAssertEqual(isUp(minimize), topBarVisible, "the top bar is \(topBarVisible ? "up" : "away")", file: file, line: line)
        // Past the slide and past the double-tap window: a tap sooner than that is the second half
        // of a double tap, which goes full screen, for a test as for a person (017 R16).
        Thread.sleep(forTimeInterval: 0.5)
    }
    
    private func rotate(to orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let window = app.windows.firstMatch
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (window.frame.width > window.frame.height) != orientation.isLandscape {
            Thread.sleep(forTimeInterval: 0.2)
        }
        // The arrangement moves after the window does.
        Thread.sleep(forTimeInterval: 0.8)
    }
    
    // MARK: - Tap
    
    /// A tap on a tile puts the control bar away, and another brings it back; the top bar stays in
    /// portrait (R14, R30).
    func testATapOnATileTogglesTheWholeChrome() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 5))
        waitForChrome(visible: true)
        
        bob.tap()
        waitForChrome(visible: false)
        bob.tap()
        waitForChrome(visible: true)
    }
    
    /// Between tiles is the stage too (R14): the gap belongs to no tile, so only the stage's own tap
    /// can answer it.
    func testATapBetweenTilesTogglesToo() {
        launch("group")
        XCTAssertTrue(tile("alice").waitForExistence(timeout: 5))
        // The first row's two cells, found by where they are rather than by who: the order is
        // the model's, and which member lands where is not this test's business.
        let tiles = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "elementCall.tile."))
        let frames = tiles.allElementsBoundByAccessibilityElement.map(\.frame).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        XCTAssertGreaterThanOrEqual(frames.count, 2)
        let left = frames[0]
        let right = frames[1]
        XCTAssertEqual(left.midY, right.midY, accuracy: 1, "side by side in the first row")
        let gap = CGVector(dx: (left.maxX + right.minX) / 2, dy: left.midY)
        
        app.coordinate(withNormalizedOffset: .zero).withOffset(gap).tap()
        
        waitForChrome(visible: false)
    }
    
    /// A double tap is full screen and nothing else (R16): 000's chrome starts down, and on the way
    /// back the stage is at portrait's start rather than at whatever a stray first tap left (R27).
    func testADoubleTapGoesFullScreenWithoutTogglingTheChrome() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 5))
        
        bob.doubleTap()
        XCTAssertFalse(tile("carol").exists, "full screen")
        XCTAssertFalse(app.buttons["elementCall.exitFullscreen"].exists, "full screen's own chrome starts down")
        
        bob.doubleTap()
        XCTAssertTrue(tile("carol").waitForExistence(timeout: 3), "back on the stage")
        waitForChrome(visible: true)
    }
    
    /// A control keeps its tap (R15): the microphone in the bar, and the flip button drawn inside a
    /// tile, which sits over the tile's gesture surface rather than in it.
    func testATapOnAControlLeavesTheChromeAlone() {
        launch("one_to_one")
        XCTAssertTrue(tile("alice").waitForExistence(timeout: 10))
        waitForChrome(visible: true)
        
        app.buttons["elementCall.microphone"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        waitForChrome(visible: true)
        
        let flip = app.buttons["Switch camera"].firstMatch
        XCTAssertTrue(flip.waitForExistence(timeout: 2))
        flip.tap()
        Thread.sleep(forTimeInterval: 0.6)
        waitForChrome(visible: true)
    }
    
    /// Tap-hidden chrome stays away (R21). The wait is past the scroll return's, so a timer armed
    /// by the wrong thing would have fired.
    func testATapHideStaysHidden() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 5))
        bob.tap()
        waitForChrome(visible: false)
        
        Thread.sleep(forTimeInterval: 3.5)
        
        waitForChrome(visible: false, timeout: 0)
    }
    
    // MARK: - Orientation
    
    /// Landscape starts with the chrome away and a tap brings it (R10, R14); turning back to portrait
    /// is portrait's start, whatever landscape was doing (R11, R12).
    func testLandscapeStartsHiddenAndATapShowsIt() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 5))
        waitForChrome(visible: true)
        
        rotate(to: .landscapeLeft)
        waitForChrome(visible: false)
        
        bob.tap()
        waitForChrome(visible: true)
        bob.tap()
        waitForChrome(visible: false)
        
        rotate(to: .portrait)
        waitForChrome(visible: true)
    }
    
    /// In landscape the top bar is only there after a tap, so minimizing starts with one, and coming
    /// back is landscape's start (R29).
    func testTheMinimizeRoundTripWorksInLandscape() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 5))
        rotate(to: .landscapeLeft)
        bob.tap()
        waitForChrome(visible: true)
        
        minimize.tap()
        let bar = app.buttons["elementCall.minimizedBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        bar.tap()
        
        XCTAssertTrue(bob.waitForExistence(timeout: 3))
        waitForChrome(visible: false)
    }
    
    // MARK: - Scroll
    
    /// Toward the end hides, toward the start shows at once (R18, R19).
    func testScrollingTowardTheEndHidesAndTowardTheStartShows() {
        launch("listen_mode", chromeReturnDelay: Self.heldReturnDelay)
        let alice = tile("alice")
        XCTAssertTrue(alice.waitForExistence(timeout: 5))
        waitForChrome(visible: true)
        
        app.swipeUp()
        waitForChrome(visible: false, timeout: 3)
        // Back by the scroll toward the start, since the return is a minute away. Not
        // `app.swipeDown()`: that starts above the middle of the window, on the spotlight, and a
        // drag there never scrolls the grid. The timer used to bring the chrome back regardless,
        // which hid that this swipe moved nothing.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        waitForChrome(visible: true, timeout: 3)
    }
    
    /// A grid that barely scrolls keeps its chrome through a scroll, bounce and all (R18); a tap
    /// still hides it (R14).
    func testAShortGridDoesNotHideTheChromeOnScroll() {
        launch("group")
        let bob = tile("bob")
        XCTAssertTrue(bob.waitForExistence(timeout: 5))
        waitForChrome(visible: true)
        
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.5)
        waitForChrome(visible: true, timeout: 0)
        
        bob.tap()
        waitForChrome(visible: false)
    }
    
    /// Scroll-hidden chrome comes back once the scrolling has stopped (R20): within the return delay
    /// of the fling ending, with slack for the fling itself.
    ///
    /// On `listen_mode`, which one swipe does not scroll to the end, rather than `two_hundred`: every
    /// query walks the whole tree, and over two hundred tiles on a loaded runner the look for the
    /// chrome going took longer than the return delay, so it saw the chrome already back.
    func testScrollHiddenChromeComesBack() {
        launch("listen_mode", chromeReturnDelay: Self.observableReturnDelay)
        XCTAssertTrue(tile("alice").waitForExistence(timeout: 5))
        
        app.swipeUp()
        waitForChrome(visible: false, timeout: 3)
        waitForChrome(visible: true, timeout: Self.observableReturnDelay + 30)
    }
    
    /// A fling that reaches the end bounces back from it, and the bounce is not a scroll toward the
    /// start (R23): the chrome stays away through it, and still comes back by itself once
    /// everything has stopped (R20).
    func testAFlingToTheEndStaysHiddenThroughTheBounceAndComesBack() {
        launch("listen_mode", chromeReturnDelay: Self.observableReturnDelay)
        XCTAssertTrue(tile("alice").waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        for _ in 0..<3 {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)),
                       withVelocity: .fast, thenHoldForDuration: 0)
        }
        // Inside the return delay: anything up now came back on the bounce.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(isUp(hangUp), "the bounce at the end did not bring the chrome back")
        waitForChrome(visible: true, timeout: Self.observableReturnDelay + 30)
    }
    
    /// The chrome going mid-drag moves nothing under the finger (R6). A slow drag with no fling: the
    /// row travels the finger's distance less the touch slop, where a clearance that changed with
    /// the chrome would add to it.
    func testHidingWhileDraggingKeepsTheRowUnderTheFinger() {
        launch("listen_mode", chromeReturnDelay: Self.heldReturnDelay)
        let alice = tile("alice")
        XCTAssertTrue(alice.waitForExistence(timeout: 5))
        let before = alice.frame.minY
        
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1)
        
        waitForChrome(visible: false, timeout: 0)
        let moved = before - alice.frame.minY
        let finger = start.screenPoint.y - end.screenPoint.y
        XCTAssertEqual(moved, finger, accuracy: 15, "the row followed the finger, and only the finger")
    }
}
