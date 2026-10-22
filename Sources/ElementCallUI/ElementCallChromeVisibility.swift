//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI

/// Whether the stage's chrome — the top bar and the control bar, together (017 R1) — is up, and why
/// not when it is not.
///
/// A value with one entry point rather than a flag the views flip, because what happens next depends
/// on how it got here: chrome hidden by scrolling comes back by itself, chrome hidden by a tap does not
/// (R20, R21), and a flag cannot tell the two apart. Every rule is a branch of ``apply(_:)``, so every
/// rule is a unit test that needs no view.
///
/// Separate from the full-screen chrome's flag on the context, not merged into it: full screen keeps
/// its chrome across a rotation (000 R10) and the stage resets on one (R12), and one flag cannot do
/// both.
struct ElementCallChromeVisibility: Equatable {
    enum Reason: Equatable {
        case tap
        case scroll
    }
    
    enum Event: Equatable {
        /// The stage is up for the first time; before this the screen draws the chrome regardless (R13).
        case stageAppeared(isLandscape: Bool)
        /// The shape of the space changed. Only a change of orientation resets anything.
        case rotated(isLandscape: Bool)
        /// A single tap on the stage (R14).
        case tap
        /// The user's own scrolling, never the app's (R23). Portrait only (R22).
        case userScrolled(towardEnd: Bool)
        /// `elementCallChromeReturnDelay` has passed since the user's scrolling fully stopped (R20).
        case scrollIdleElapsed
        /// A tile has stopped being full screen: left by the user, or by its member leaving (R27, R28).
        case fullscreenEnded(byDeparture: Bool)
        /// Back from Picture in Picture or the minimized bar (R29).
        case restored
        case screenReader(isRunning: Bool)
    }
    
    /// How the chrome slides, and with it whatever the stage pins to the chrome's edge, so the two
    /// move as one.
    static let slide: Animation = .spring(duration: 0.25, bounce: 0)
    
    private(set) var isVisible = true
    /// Why it is hidden; nil while it is visible.
    private(set) var hiddenBy: Reason?
    /// The orientation it was last reset for; nil until the stage first appears.
    private(set) var isLandscape: Bool?
    private(set) var isScreenReaderRunning = false
    /// A preview's: the resets are ignored, so the portrait and landscape renders of one preview show
    /// the same state rather than each orientation's starting one.
    private var isPinned = false
    
    init() { }
    
    static func pinned(isVisible: Bool) -> ElementCallChromeVisibility {
        var visibility = ElementCallChromeVisibility()
        visibility.isPinned = true
        visibility.isVisible = isVisible
        visibility.hiddenBy = isVisible ? nil : .tap
        return visibility
    }
    
    /// Whether the screen should be counting down to ``scrollIdleElapsed``.
    var isAwaitingReturn: Bool {
        hiddenBy == .scroll
    }
    
    mutating func apply(_ event: Event) {
        switch event {
        case .stageAppeared(let isLandscape):
            reset(isLandscape: isLandscape)
        case .rotated(let isLandscape):
            // A resize that keeps the shape is not a rotation: the iPad's split view resizes the
            // window all the time, and resetting on each would undo every tap.
            guard isLandscape != self.isLandscape else { return }
            reset(isLandscape: isLandscape)
        case .tap:
            isVisible ? hide(.tap) : show()
        case .userScrolled(let towardEnd):
            guard isLandscape == false else { return }
            if !towardEnd {
                show()
            } else if isVisible {
                // Only from visible: scrolling on past a tap-hide must not turn it into one that
                // comes back by itself.
                hide(.scroll)
            }
        case .scrollIdleElapsed:
            guard hiddenBy == .scroll else { return }
            show()
        case .fullscreenEnded(let byDeparture):
            if byDeparture {
                // The user did not choose to leave, and lands somewhere they did not ask to be: they
                // get the chrome whatever the orientation (R28, 000 R19).
                show()
            } else if let isLandscape {
                reset(isLandscape: isLandscape)
            }
        case .restored:
            guard let isLandscape else { return }
            reset(isLandscape: isLandscape)
        case .screenReader(let isRunning):
            isScreenReaderRunning = isRunning
            if isRunning {
                show()
            }
        }
    }
    
    /// Each orientation's starting state: hidden in landscape, shown in portrait (R10, R11).
    private mutating func reset(isLandscape: Bool) {
        self.isLandscape = isLandscape
        guard !isPinned else { return }
        // Landscape's start counts as a tap-hide: nothing brings it back but the user (R22).
        isLandscape ? hide(.tap) : show()
    }
    
    private mutating func show() {
        isVisible = true
        hiddenBy = nil
    }
    
    /// Refused while a screen reader runs: a control it cannot see does not exist for it (R24).
    private mutating func hide(_ reason: Reason) {
        guard !isScreenReaderRunning else {
            show()
            return
        }
        isVisible = false
        hiddenBy = reason
    }
}
