//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import SwiftUI
import UIKit

/// Dragging our own floating tile to another corner (019 R2, R21, R22).
///
/// A UIKit pan for the reason the spotlight's is (see ``ElementCallSpotlightPanGesture``), and one
/// more: it begins only once the finger moves, and when it begins UIKit cancels the touch every
/// other view was tracking. So a tap on the flip button never starts a drag and is the button's
/// alone, while a drag that starts on the button moves the tile and does not flip the camera (R22).
/// A SwiftUI drag with a zero minimum distance would take the button's tap; one with a distance
/// still lets the button fire on release.
///
/// **On the content root, not on the tile**, as the spotlight's is: a recognizer on the tile gives
/// it a platform view of its own, which UIKit hit-tests above the tile's SwiftUI contents, the flip
/// button included. The delegate accepts only touches that start inside the tile's frame.
struct ElementCallOwnTileDragGesture: UIGestureRecognizerRepresentable {
    /// Where our floating tile is, in the content's coordinates, as drawn; nil disables the drag.
    let tileFrame: CGRect?
    /// The finger's travel so far.
    let onChange: (CGSize) -> Void
    /// The finger lifted after a drag, moving at this velocity in points per second; where it was is
    /// what `onChange` last said.
    let onEnd: (CGSize) -> Void
    /// The system took the touch away; the tile goes back to its corner.
    let onCancel: () -> Void
    
    /// How long a finger may rest before lifting and still throw the tile.
    static let heldRelease: TimeInterval = 0.1
    
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, gesture: self)
    }
    
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }
    
    /// The action fires on the value the recognizer was made with, as the spotlight's found, so the
    /// coordinator holds the latest one and both the action and the delegate read it from there.
    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.gesture = self
    }
    
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let view = recognizer.view else { return }
        let translation = recognizer.translation(in: view)
        let travel = CGSize(width: translation.x, height: translation.y)
        let coordinator = context.coordinator
        let gesture = coordinator.gesture
        switch recognizer.state {
        case .began, .changed:
            coordinator.lastMove = .now
            gesture.onChange(travel)
        case .ended:
            // The recognizer's velocity is that of the last movement, and a finger held still sends
            // none, so after a pause it is stale: a release that long after moving is a drop.
            let isHeld = coordinator.lastMove.map { Date.now.timeIntervalSince($0) > Self.heldRelease } ?? true
            let velocity = isHeld ? .zero : recognizer.velocity(in: view)
            gesture.onEnd(CGSize(width: velocity.x, height: velocity.y))
        case .cancelled, .failed:
            gesture.onCancel()
        default:
            break
        }
    }
    
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let converter: CoordinateSpaceConverter
        var gesture: ElementCallOwnTileDragGesture
        /// When the finger last moved, for telling a flick from a drop.
        var lastMove: Date?
        
        init(converter: CoordinateSpaceConverter, gesture: ElementCallOwnTileDragGesture) {
            self.converter = converter
            self.gesture = gesture
        }
        
        /// Only a touch that starts on our tile. Everything else is the stage's, untouched.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let tileFrame = gesture.tileFrame, let view = gestureRecognizer.view else { return false }
            return tileFrame.contains(converter.convert(globalPoint: touch.location(in: view), to: .local))
        }
    }
}
