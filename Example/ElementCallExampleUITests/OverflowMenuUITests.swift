//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// What is inside the top bar's overflow menu.
///
/// This belongs here rather than in a snapshot for a concrete reason: a SwiftUI `Menu` renders only
/// its label until it is opened, so an image of the call screen says nothing about its contents. A
/// real tap is the only way to see them, which is the same reason the tile gestures live here.
///
/// XCTest rather than swift-testing, for the reason given in `TileFullscreenUITests`.
final class OverflowMenuUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-fixture", "group"]
        app.launch()
    }
    
    private func openMenu() {
        let more = app.buttons["elementCall.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "The overflow button should be in the top bar.")
        more.tap()
    }
    
    /// The diagnostics live one level down, so reaching the toggle is two taps.
    private func openDeveloperOptions() {
        openMenu()
        let submenu = app.buttons["Developer Options"]
        XCTAssertTrue(submenu.waitForExistence(timeout: 3),
                      "Developer mode is on in the fixtures, so the submenu should be offered.")
        submenu.tap()
    }
    
    private var statsItem: XCUIElement {
        app.buttons["Tile stats"]
    }
    
    private var anyTileStats: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'pkts'")).firstMatch
    }
    
    /// The overlay itself, which is what the toggle is for. The harness fakes the strings, since a
    /// fixture has no call to take receive statistics from, but the path from tap to drawn overlay
    /// is the real one.
    func testTheToggleShowsAndHidesTheOverlay() {
        XCTAssertFalse(anyTileStats.exists, "No overlay before it is asked for.")
        
        openDeveloperOptions()
        XCTAssertTrue(statsItem.waitForExistence(timeout: 3))
        statsItem.tap()
        XCTAssertTrue(anyTileStats.waitForExistence(timeout: 3), "Tapping it should draw the overlay.")
        
        openDeveloperOptions()
        statsItem.tap()
        XCTAssertFalse(anyTileStats.waitForExistence(timeout: 2), "Tapping again should take it away.")
    }
    
    /// Reopening the menu should say whether the overlay is on, which is the whole reason the item
    /// is a `Toggle` rather than a `Button`.
    func testTheItemIsCheckedWhileTheOverlayIsOn() {
        openDeveloperOptions()
        XCTAssertTrue(statsItem.waitForExistence(timeout: 3))
        XCTAssertFalse(statsItem.isSelected, "It starts off, so it starts unchecked.")
        statsItem.tap()
        
        openDeveloperOptions()
        XCTAssertTrue(statsItem.waitForExistence(timeout: 3))
        XCTAssertTrue(statsItem.isSelected, "With the overlay on, the item should be checked.")
    }
    
    func testTheSubmenuOffersTheStatsOverlay() {
        openDeveloperOptions()
        
        XCTAssertTrue(statsItem.waitForExistence(timeout: 3),
                      "The stats toggle should be inside Developer Options.")
    }
    
    /// The version row is what a bug report quotes, and it is also what keeps the menu from being
    /// empty for a host with everything gated off. Disabled, so it cannot be tapped.
    func testTheMenuNamesThePackageVersion() {
        openMenu()
        
        let version = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'version: '")).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 3), "The menu should name the package version.")
        XCTAssertFalse(version.isEnabled, "The version is a label, not an action.")
        
        let core = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'matrix-rust-rtc '")).firstMatch
        XCTAssertTrue(core.exists, "The menu should name the matrix-rust-rtc version, as Android's does.")
        XCTAssertFalse(core.isEnabled, "The version is a label, not an action.")
    }
}
