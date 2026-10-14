//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallUI
import Testing

/// When the stage's chrome is up: spec 017, rule by rule. The value is the whole of the decision, so
/// the rules are tested here and the UI tests only check that the touches reach it.
struct ElementCallChromeVisibilityTests {
    private func chrome(_ events: ElementCallChromeVisibility.Event...) -> ElementCallChromeVisibility {
        var visibility = ElementCallChromeVisibility()
        events.forEach { visibility.apply($0) }
        return visibility
    }
    
    @Test("Shown before the stage exists, whatever comes (R13)")
    func shownBeforeTheStage() {
        #expect(chrome().isVisible)
        #expect(chrome(.userScrolled(towardEnd: true)).isVisible)
        #expect(chrome(.restored).isVisible)
    }
    
    @Test("Starts hidden in landscape and shown in portrait (R10, R11)")
    func startingState() {
        #expect(!chrome(.stageAppeared(isLandscape: true)).isVisible)
        #expect(chrome(.stageAppeared(isLandscape: false)).isVisible)
    }
    
    @Test("A rotation resets to the new orientation's start (R12)")
    func rotationResets() {
        #expect(!chrome(.stageAppeared(isLandscape: false), .rotated(isLandscape: true)).isVisible)
        #expect(chrome(.stageAppeared(isLandscape: true), .tap, .tap, .rotated(isLandscape: false)).isVisible)
        // Tapped up in landscape, round trip: back to landscape's start, not to what it was.
        #expect(!chrome(.stageAppeared(isLandscape: true), .tap, .rotated(isLandscape: false), .rotated(isLandscape: true)).isVisible)
    }
    
    @Test("A resize that keeps the shape is not a rotation")
    func resizeIsNotRotation() {
        #expect(chrome(.stageAppeared(isLandscape: true), .tap, .rotated(isLandscape: true)).isVisible)
        #expect(!chrome(.stageAppeared(isLandscape: false), .tap, .rotated(isLandscape: false)).isVisible)
    }
    
    @Test("A tap toggles, in both orientations (R14)")
    func tapToggles() {
        #expect(!chrome(.stageAppeared(isLandscape: false), .tap).isVisible)
        #expect(chrome(.stageAppeared(isLandscape: false), .tap, .tap).isVisible)
        #expect(chrome(.stageAppeared(isLandscape: true), .tap).isVisible)
        #expect(!chrome(.stageAppeared(isLandscape: true), .tap, .tap).isVisible)
    }
    
    @Test("In portrait, scrolling toward the end hides and toward the start shows (R18, R19)")
    func portraitScrolling() {
        let hidden = chrome(.stageAppeared(isLandscape: false), .userScrolled(towardEnd: true))
        #expect(!hidden.isVisible)
        #expect(hidden.hiddenBy == .scroll)
        #expect(chrome(.stageAppeared(isLandscape: false), .userScrolled(towardEnd: true), .userScrolled(towardEnd: false)).isVisible)
    }
    
    @Test("Scrolling toward the start also undoes a tap-hide (R21)")
    func scrollingUpUndoesATapHide() {
        #expect(chrome(.stageAppeared(isLandscape: false), .tap, .userScrolled(towardEnd: false)).isVisible)
    }
    
    @Test("Scroll-hidden chrome comes back once the user stops (R20)")
    func scrollHideReturns() {
        let hidden = chrome(.stageAppeared(isLandscape: false), .userScrolled(towardEnd: true))
        #expect(hidden.isAwaitingReturn)
        var returned = hidden
        returned.apply(.scrollIdleElapsed)
        #expect(returned.isVisible)
        #expect(!returned.isAwaitingReturn)
    }
    
    @Test("Tap-hidden chrome never comes back by itself, scrolled on or not (R21)")
    func tapHideStays() {
        let tapped = chrome(.stageAppeared(isLandscape: false), .tap)
        #expect(!tapped.isAwaitingReturn)
        #expect(!chrome(.stageAppeared(isLandscape: false), .tap, .scrollIdleElapsed).isVisible)
        // Scrolling on toward the end past a tap-hide keeps it a tap-hide.
        let scrolledOn = chrome(.stageAppeared(isLandscape: false), .tap, .userScrolled(towardEnd: true), .scrollIdleElapsed)
        #expect(!scrolledOn.isVisible)
        #expect(scrolledOn.hiddenBy == .tap)
    }
    
    @Test("In landscape scrolling changes nothing and nothing returns by itself (R22)")
    func landscapeIgnoresScrolling() {
        #expect(chrome(.stageAppeared(isLandscape: true), .tap, .userScrolled(towardEnd: true)).isVisible)
        #expect(!chrome(.stageAppeared(isLandscape: true), .userScrolled(towardEnd: false)).isVisible)
        #expect(!chrome(.stageAppeared(isLandscape: true), .scrollIdleElapsed).isVisible)
        #expect(!chrome(.stageAppeared(isLandscape: true)).isAwaitingReturn)
    }
    
    @Test("A screen reader forces it up and refuses every hide (R24)")
    func screenReader() {
        #expect(chrome(.stageAppeared(isLandscape: true), .screenReader(isRunning: true)).isVisible)
        #expect(chrome(.screenReader(isRunning: true), .stageAppeared(isLandscape: true)).isVisible)
        #expect(chrome(.screenReader(isRunning: true), .stageAppeared(isLandscape: false), .tap).isVisible)
        #expect(chrome(.screenReader(isRunning: true), .stageAppeared(isLandscape: false), .userScrolled(towardEnd: true)).isVisible)
        #expect(chrome(.screenReader(isRunning: true), .stageAppeared(isLandscape: false), .rotated(isLandscape: true)).isVisible)
        // Once it stops, the ordinary rules are back.
        #expect(!chrome(.screenReader(isRunning: true), .stageAppeared(isLandscape: false), .screenReader(isRunning: false), .tap).isVisible)
    }
    
    @Test("Leaving full screen yourself returns to the orientation's start (R27)")
    func leavingFullscreen() {
        #expect(!chrome(.stageAppeared(isLandscape: true), .tap, .fullscreenEnded(byDeparture: false)).isVisible)
        #expect(chrome(.stageAppeared(isLandscape: false), .tap, .fullscreenEnded(byDeparture: false)).isVisible)
    }
    
    @Test("Full screen ended by a departure shows the chrome, in both orientations (R28)")
    func fullscreenEndedByDeparture() {
        #expect(chrome(.stageAppeared(isLandscape: true), .fullscreenEnded(byDeparture: true)).isVisible)
        #expect(chrome(.stageAppeared(isLandscape: false), .tap, .fullscreenEnded(byDeparture: true)).isVisible)
    }
    
    @Test("Coming back from minimized returns to the orientation's start (R29)")
    func restored() {
        #expect(!chrome(.stageAppeared(isLandscape: true), .tap, .restored).isVisible)
        #expect(chrome(.stageAppeared(isLandscape: false), .tap, .restored).isVisible)
    }
    
    @Test("A pinned preview ignores the resets, so both renders of it show one state")
    func pinned() {
        var shown = ElementCallChromeVisibility.pinned(isVisible: true)
        shown.apply(.stageAppeared(isLandscape: true))
        #expect(shown.isVisible)
        var hidden = ElementCallChromeVisibility.pinned(isVisible: false)
        hidden.apply(.stageAppeared(isLandscape: false))
        #expect(!hidden.isVisible)
    }
}
