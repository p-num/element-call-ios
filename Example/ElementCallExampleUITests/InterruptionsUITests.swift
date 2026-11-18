//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The service interruptions indicator, driven by a real touch (034 R35, R36, R15).
///
/// How causes map to entries, and which controls they disable, are `InterruptionEntriesTests`, in
/// process. What is here is what only a touch answers: that the indicator over the stage takes the
/// tap rather than the tile beneath it, that the list opens as a popover a phone does not turn into
/// a sheet, and that the list closes on its own when the outage ends.
final class InterruptionsUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }
    
    private var indicator: XCUIElement {
        app.buttons["elementCall.interruptions"]
    }
    
    private var list: XCUIElement {
        app.otherElements["elementCall.interruptionsList"]
    }
    
    /// The hand is a row of the bar's `…` sheet, so whether it waits for our server is read from
    /// there, and the sheet closed again before anything else is tapped.
    private func handRowIsEnabled() -> Bool {
        app.buttons["elementCall.controlsMore"].tap()
        let row = app.buttons["elementCall.raisedHand"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the `…` opened the More sheet")
        let isEnabled = row.isEnabled
        app.buttons["elementCall.close"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, "the sheet closed")
        return isEnabled
    }
    
    /// `outage.homeserver.30s`: our server goes at 5 s and comes back at 35 s, on the wall clock,
    /// so CI's slowness lengthens nothing here.
    func testTheIndicatorOpensTheListWhichClosesWithTheOutage() {
        app.launchArguments = ["-fixture", "outage.homeserver.30s"]
        app.launch()
        
        XCTAssertTrue(indicator.waitForExistence(timeout: 20), "the indicator appears with the outage")
        XCTAssertFalse(handRowIsEnabled(), "the hand waits for our server (R15)")
        
        indicator.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 5), "the tap reached the indicator and opened the list")
        XCTAssertTrue(list.staticTexts.element(boundBy: 0).label.hasPrefix("Your server is unreachable"))
        
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: list)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 45), .completed, "the list closes on its own when the last entry clears (R36)")
        XCTAssertFalse(indicator.exists)
        XCTAssertTrue(handRowIsEnabled())
    }
}
