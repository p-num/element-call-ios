//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The settings menu's Developer options sheet (043 R4, R5, R10, R11, R14, R15): a real menu, a real
/// sheet and real touches, which is what earns these a place here.
///
/// XCTest rather than swift-testing, for the reason given in `TileFullscreenUITests`.
final class DeveloperOptionsUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-fixture", "group"]
    }
    
    private var close: XCUIElement {
        app.buttons["elementCall.developerOptions.close"]
    }
    
    private func openDeveloperOptions() {
        let settings = app.buttons["elementCall.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "The settings button should be in the top bar.")
        settings.tap()
        let item = app.buttons["elementCall.developerOptions"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Developer mode is on in the fixtures.")
        item.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "Developer options should open a sheet.")
    }
    
    private var anyTileStats: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'pkts'")).firstMatch
    }
    
    /// R4: a host without developer mode has Preferences alone.
    func testWithoutDeveloperModeTheMenuHasPreferencesAlone() {
        app.launchArguments += ["-noDeveloperMode"]
        app.launch()
        let settings = app.buttons["elementCall.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.buttons["elementCall.preferences"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["elementCall.developerOptions"].exists)
    }
    
    /// R5: it closes like Preferences, with its close button.
    func testTheCloseButtonClosesTheSheet() {
        app.launch()
        openDeveloperOptions()
        close.tap()
        XCTAssertFalse(close.waitForExistence(timeout: 2))
    }
    
    /// R5: a setting, so it is still open after the app comes back from the background, which the
    /// reaction picker and the More sheet are not.
    func testTheSheetSurvivesBackgrounding() {
        app.launch()
        openDeveloperOptions()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Developer options should still be open.")
    }
    
    /// R10: tile stats are here now, and turn the overlay on.
    func testTileStatsToggleTheOverlay() {
        app.launch()
        XCTAssertFalse(anyTileStats.exists, "No overlay before it is asked for.")
        openDeveloperOptions()
        let toggle = app.switches["elementCall.developerOptions.tileStats"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        // On the switch itself, at the row's trailing end: the middle of the row is its label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(anyTileStats.waitForExistence(timeout: 3), "Turning it on should draw the overlay.")
    }
    
    /// R11, R14, R18: both formats are listed and either can be chosen; the card says when it applies.
    func testBothFormatsCanBeChosen() {
        app.launch()
        openDeveloperOptions()
        XCTAssertTrue(app.staticTexts["Takes effect the next time you join a call."].firstMatch.waitForExistence(timeout: 3))
        let roomState = app.buttons["elementCall.developerOptions.membershipFormat.roomState"]
        let msc = app.buttons["elementCall.developerOptions.membershipFormat.msc"]
        XCTAssertTrue(roomState.waitForExistence(timeout: 3))
        XCTAssertTrue(roomState.isSelected, "Room state is the default (R13a).")
        XCTAssertFalse(msc.isSelected)
        msc.tap()
        XCTAssertTrue(msc.isSelected, "The row tapped should carry the checkmark.")
        XCTAssertFalse(roomState.isSelected)
    }
    
    /// R15, R15a: Auto first, naming what it publishes, then what the device can encode; R15b: the
    /// card warns that a receiver that cannot decode the codec sees no video.
    func testTheCodecOffersAutoFirst() {
        app.launch()
        openDeveloperOptions()
        let auto = app.buttons["elementCall.developerOptions.videoCodec.auto"]
        XCTAssertTrue(auto.waitForExistence(timeout: 3))
        XCTAssertEqual(auto.label, "Auto (VP8)")
        XCTAssertTrue(auto.isSelected, "Auto is the default (R16).")
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Takes effect the next time you join a call. Anyone whose app'"))
            .firstMatch.exists)
        let vp8 = app.buttons["elementCall.developerOptions.videoCodec.vp8"]
        XCTAssertTrue(vp8.exists, "VP8 can be encoded everywhere.")
        XCTAssertGreaterThan(vp8.frame.minY, auto.frame.minY, "Auto should come first.")
    }
}
