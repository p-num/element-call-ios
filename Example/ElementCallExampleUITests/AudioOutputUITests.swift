//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The control bar's audio button: a toggle with only the phone's outputs, a menu with a headset.
///
/// Here rather than in a snapshot because the bug was a touch: the system route picker sat over the
/// toggle at 2% opacity and never received a tap, which looks identical to a working button in an
/// image. A menu's rows exist only once a real tap opens it.
///
/// XCTest rather than swift-testing, for the reason given in `TileFullscreenUITests`.
final class AudioOutputUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }
    
    private func launch(headset: Bool) -> XCUIElement {
        app.launchArguments = ["-fixture", "group"] + (headset ? ["-headset"] : [])
        app.launch()
        let button = app.buttons["elementCall.audioOutput"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "The audio button should be in the control bar.")
        return button
    }
    
    func testWithoutAHeadsetTheButtonTogglesTheSpeaker() {
        let button = launch(headset: false)
        XCTAssertEqual(button.value as? String, "Phone")
        
        button.tap()
        XCTAssertEqual(button.value as? String, "Speaker")
        XCTAssertFalse(app.buttons["AirPods Pro"].exists, "Without a headset the button toggles; it opens nothing.")
        
        button.tap()
        XCTAssertEqual(button.value as? String, "Phone")
    }
    
    func testWithAHeadsetTheButtonOffersEveryOutput() {
        let button = launch(headset: true)
        XCTAssertEqual(button.value as? String, "AirPods Pro")
        
        button.tap()
        for row in ["AirPods Pro", "Phone", "Speaker"] {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 3), "The menu should offer \(row).")
        }
        app.buttons["Speaker"].tap()
        
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertEqual(button.value as? String, "Speaker")
    }
}
