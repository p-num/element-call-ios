//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// The reaction button and its picker, driven by real touches (spec 009).
///
/// What is sent, and when the sheet closes for the call's own reasons, are `ReactionSendingTests`,
/// in process. What is here is what only a touch can answer: whether the bar's `…` and its sheet
/// take the tap over the stage beneath, whether a reaction in the picker takes its own tap and
/// closes the picker (009 R16, R19), and whether the banner's Cancel is reachable (R2).
final class ReactionPickerUITests: XCTestCase {
    private var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-fixture", "group"]
        app.launch()
        XCTAssertTrue(app.otherElements["elementCall.tile.@alice:example.com:DEVICE"].waitForExistence(timeout: 10))
    }
    
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let hittable = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: element)
        return XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed
    }
    
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
    
    /// The bar's `…`, then the More sheet's Emoji reactions row.
    private func openPicker() {
        let more = app.buttons["elementCall.controlsMore"]
        XCTAssertTrue(waitUntilHittable(more), "the `…` is in the bar and can be tapped")
        more.tap()
        let reactions = app.buttons["elementCall.reactions"]
        XCTAssertTrue(waitUntilHittable(reactions), "the tap opened the More sheet")
        reactions.tap()
    }
    
    func testPickingAReactionClosesThePicker() {
        openPicker()
        
        let thumbsUp = app.buttons["elementCall.reaction.thumbsup"]
        XCTAssertTrue(waitUntilHittable(thumbsUp), "the tap opened the picker")
        thumbsUp.tap()
        
        XCTAssertTrue(waitUntilGone(thumbsUp), "sending a reaction closes the picker (009 R19)")
    }
    
    /// The banner's Cancel lowers the hand the More sheet raised (009 R2).
    func testTheBannerLowersTheHandTheMenuRaised() {
        app.buttons["elementCall.controlsMore"].tap()
        let raise = app.buttons["elementCall.raisedHand"]
        XCTAssertTrue(waitUntilHittable(raise))
        raise.tap()
        let cancel = app.buttons["elementCall.lowerHand"]
        XCTAssertTrue(waitUntilHittable(cancel), "raising the hand shows the banner")
        cancel.tap()
        XCTAssertTrue(waitUntilGone(cancel), "Cancel lowers the hand and the banner goes")
    }
    
    func testClosingThePickerSendsNothingAndClosesIt() {
        openPicker()
        let close = app.buttons["elementCall.close"]
        XCTAssertTrue(waitUntilHittable(close))
        close.tap()
        XCTAssertTrue(waitUntilGone(app.buttons["elementCall.reaction.thumbsup"]), "the picker closes (009 R20)")
    }
}
