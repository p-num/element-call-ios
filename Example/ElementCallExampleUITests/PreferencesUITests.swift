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
        let settings = app.buttons["elementCall.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "The settings button should be in the top bar.")
        settings.tap()
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
        XCTAssertTrue(app.buttons["elementCall.settings"].isHittable, "The stage should be where it was, not full screen.")
        XCTAssertFalse(app.buttons["elementCall.exitFullscreen"].exists, "The tap should not have reached a tile.")
    }
    
    /// 043 R2, R3: the button is Settings to a screen reader, and its menu ends with Preferences, then
    /// Developer options in developer mode, which every fixture has.
    func testTheSettingsMenuOffersPreferencesThenDeveloperOptions() {
        let settings = app.buttons["elementCall.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(settings.label, "Settings")
        settings.tap()
        let preferences = app.buttons["elementCall.preferences"]
        let developerOptions = app.buttons["elementCall.developerOptions"]
        XCTAssertTrue(preferences.waitForExistence(timeout: 3))
        XCTAssertTrue(developerOptions.waitForExistence(timeout: 3))
        XCTAssertLessThan(preferences.frame.minY, developerOptions.frame.minY, "Preferences should come first.")
    }
    
    /// 043 R6, R7: two switches; with reactions hidden the sound one is greyed and keeps its position.
    func testHidingReactionsGreysTheSoundSwitchWithoutMovingIt() {
        openPreferences()
        let show = app.switches["elementCall.preferences.showReactions"]
        let sounds = app.switches["elementCall.preferences.playReactionSounds"]
        XCTAssertTrue(show.waitForExistence(timeout: 3))
        XCTAssertTrue(sounds.exists)
        XCTAssertEqual(sounds.value as? String, "1")
        XCTAssertTrue(sounds.isEnabled)
        
        show.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(show.value as? String, "0")
        XCTAssertFalse(sounds.isEnabled, "The sound switch should be greyed while reactions are hidden.")
        XCTAssertEqual(sounds.value as? String, "1", "It should keep the position the user left it in.")
        
        show.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(sounds.isEnabled)
        XCTAssertEqual(sounds.value as? String, "1")
    }
    
    /// 043 R9: tile stats have moved to Developer options.
    func testPreferencesHasNoDeveloperSection() {
        openPreferences()
        XCTAssertTrue(app.switches["elementCall.preferences.showReactions"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.switches["elementCall.developerOptions.tileStats"].exists)
        XCTAssertFalse(app.staticTexts["Tile stats"].exists)
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
