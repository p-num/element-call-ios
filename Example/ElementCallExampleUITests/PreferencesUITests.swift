//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The way into the Preferences sheet, and what is in it (spec 037, R12–R17).
///
/// Here rather than in a snapshot because a `Menu` renders only its label until it is opened, and a
/// sheet only once something presents it: a real tap is the only way to see either, and the only
/// way to know a tap outside the sheet closes it without reaching the tile under it (R12a).
///
/// XCTest rather than swift-testing, for the reason given in `TileFullscreenUITests`.
final class PreferencesUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-fixture", "group"]
        app.launch()
    }
    
    private var sheet: XCUIElement {
        app.descendants(matching: .any)["elementCall.preferencesSheet"]
    }
    
    private func openPreferences() {
        let more = app.buttons["elementCall.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "The overflow button should be in the top bar.")
        more.tap()
        let item = app.buttons["elementCall.preferences"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "The menu should offer Preferences.")
        item.tap()
        XCTAssertTrue(app.buttons["elementCall.preferences.close"].waitForExistence(timeout: 3), "Preferences should open a sheet.")
    }
    
    private var anyTileStats: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'pkts'")).firstMatch
    }
    
    func testTheCloseButtonClosesTheSheet() {
        openPreferences()
        app.buttons["elementCall.preferences.close"].tap()
        XCTAssertFalse(app.buttons["elementCall.preferences.close"].waitForExistence(timeout: 2))
    }
    
    /// R12a: the tap that closes the sheet does nothing else, so the tile it lands on stays a tile.
    func testATapAboveTheSheetClosesItAndNothingElse() {
        openPreferences()
        // Halfway down whatever the sheet leaves uncovered: it is sized to its content, so a fixed
        // point lands on it once it grows taller than that point on a small phone.
        let uncovered = sheet.frame.minY
        XCTAssertGreaterThan(uncovered, 0, "The sheet should leave some of the call in view.")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.3, dy: uncovered / 2)).tap()
        XCTAssertFalse(app.buttons["elementCall.preferences.close"].waitForExistence(timeout: 2), "A tap outside should close it.")
        XCTAssertTrue(app.buttons["elementCall.more"].isHittable, "The stage should be where it was, not full screen.")
        XCTAssertFalse(app.buttons["elementCall.exitFullscreen"].exists, "The tap should not have reached a tile.")
    }
    
    /// R13: the three choices, and the one picked is what the row then says.
    func testTheReactionsSettingOffersThreeChoices() {
        openPreferences()
        let picker = app.buttons["elementCall.preferences.reactions"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap()
        for choice in ["On", "Silent", "Off"] {
            XCTAssertTrue(app.buttons[choice].waitForExistence(timeout: 2), "\(choice) should be offered.")
        }
        app.buttons["Silent"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 2))
        XCTAssertTrue(picker.label.contains("Silent") || (picker.value as? String)?.contains("Silent") == true,
                      "The row should show the choice made.")
    }
    
    /// R16: the developer options' section holds the stats overlay's toggle.
    func testDeveloperOptionsTogglesTheStatsOverlay() {
        XCTAssertFalse(anyTileStats.exists, "No overlay before it is asked for.")
        openPreferences()
        let toggle = app.switches["elementCall.preferences.tileStats"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "Developer mode is on in the fixtures.")
        // On the switch itself, at the row's trailing end: the middle of the row is its label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(anyTileStats.waitForExistence(timeout: 3), "Turning it on should draw the overlay.")
    }
    
    /// R17: what a bug report quotes, for everyone.
    func testTheSheetNamesBothVersions() {
        openPreferences()
        let version = app.descendants(matching: .any)["elementCall.preferences.version"]
        XCTAssertTrue(version.waitForExistence(timeout: 3))
        XCTAssertTrue(version.label.contains("Version "), "It should name the package version.")
        XCTAssertTrue(version.label.contains("matrix-rust-rtc "), "It should name the core's version, as Android does.")
    }
}
