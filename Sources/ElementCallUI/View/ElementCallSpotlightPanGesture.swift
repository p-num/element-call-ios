//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
import UIKit

/// The drag on the spotlight: a sideways swipe switches heroes (003 R22) and a vertical one does
/// nothing, and either way the grid does not scroll (R64).
///
/// A UIKit pan rather than a SwiftUI `DragGesture`, and not for taste. The scroller's pan is a
/// UIKit recognizer, and a SwiftUI drag — high priority or not — does not stop it: the UI test that
/// drags the spotlight and expects the grid to stay put moved it by a screen. What does stop it is
/// the one thing only a `UIGestureRecognizerDelegate` can say: the scroller's pan must **wait for
/// this one to fail**. A pan that begins on any movement never fails once the finger moves, so a
/// drag that starts here never reaches the grid; a tap moves nothing, so it never begins, and the
/// double tap lands as before.
///
/// **Attached to the whole scrolling content, once, not to the spotlight tile.** A recognizer on a
/// tile gives that tile a platform view of its own, and UIKit hit-tests that view above every plain
/// SwiftUI sibling whatever the stack's z-order: the arrows drawn over the spotlight got a tap
/// once, until the hero switched and the new spotlight's view was created above them. So the
/// content root carries the recognizer, and the delegate accepts only touches that start inside
/// the spotlight's rect and outside the arrows', in the content's own coordinates.
struct ElementCallSpotlightPanGesture: UIGestureRecognizerRepresentable {
    /// Where the spotlight is, in the content's coordinates; nil disables the drag.
    let spotlightFrame: CGRect?
    /// Rects a touch may start in without being this gesture's: the arrows.
    let excluded: [CGRect]
    /// Positive for a swipe towards the leading edge (show the next hero), negative for the other.
    let onSwipe: (Int) -> Void
    
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, spotlightFrame: spotlightFrame, excluded: excluded, onSwipe: onSwipe)
    }
    
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }
    
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // The action fires on the value the recognizer was made with, not the latest one, so
        // everything it needs lives on the coordinator, which is updated: the stack it captured
        // on first render said "the first hero is shown" forever, and "previous" never moved.
        context.coordinator.spotlightFrame = spotlightFrame
        context.coordinator.excluded = excluded
        context.coordinator.onSwipe = onSwipe
    }
    
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        // Sideways, and either far enough or fast enough to read as a swipe rather than a nudge.
        guard abs(translation.x) > abs(translation.y), abs(translation.x) > 40 || abs(velocity.x) > 300 else { return }
        context.coordinator.onSwipe(translation.x < 0 ? 1 : -1)
    }
    
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let converter: CoordinateSpaceConverter
        var spotlightFrame: CGRect?
        var excluded: [CGRect]
        var onSwipe: (Int) -> Void
        
        init(converter: CoordinateSpaceConverter, spotlightFrame: CGRect?, excluded: [CGRect], onSwipe: @escaping (Int) -> Void) {
            self.converter = converter
            self.spotlightFrame = spotlightFrame
            self.excluded = excluded
            self.onSwipe = onSwipe
        }
        
        /// Only a touch that starts on the spotlight, and not on an arrow, is this gesture's.
        /// Everything else is the scroller's or a button's, untouched.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let spotlightFrame, let view = gestureRecognizer.view else { return false }
            let point = converter.convert(globalPoint: touch.location(in: view), to: .local)
            return spotlightFrame.contains(point) && !excluded.contains { $0.contains(point) }
        }
        
        /// The scroller's pan waits for this one, which is what keeps a drag that starts on the
        /// spotlight from scrolling the grid.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
        }
    }
}
