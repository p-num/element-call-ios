//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCallHost
import Foundation
import Testing

/// Where a minimized call goes, which the controller decides and the host carries out.
///
/// This is the branch the example harness runs on and the one a host has to implement, and it had no
/// coverage at all: the system window needs a bound `MatrixRTCMediaSession`, so every test, preview and
/// harness takes the other path, and nothing said so.
@Suite("Minimizing")
struct MinimizeRoutingTests {
    /// Collected through a reference so the closure has somewhere to write that outlives the call.
    @MainActor
    private final class Recorder {
        var actions: [ElementCallControllerAction] = []
        var cancellable: AnyCancellable?
        
        init(_ controller: ElementCallController) {
            cancellable = controller.actions.sink { [self] action in actions.append(action) }
        }
        
        func sawMinimizeRequested() -> Bool {
            actions.contains {
                if case .minimizeRequested = $0 {
                    true
                } else {
                    false
                }
            }
        }
        
        func sawPictureInPictureUnavailable() -> Bool {
            actions.contains {
                if case .pictureInPictureUnavailable = $0 {
                    true
                } else {
                    false
                }
            }
        }
    }
    
    /// A controller with no call bound has no window to open — `AVPictureInPictureController` is
    /// only ever built in `bind(call:spotlightProvider:)` — so it asks the host for a minimized
    /// presentation of its own. That is the contract the minimized bar exists to satisfy.
    @Test
    func minimizingWithNoWindowAvailableAsksTheHostForItsOwn() {
        let controller = ElementCallController.fake(connection: .connected)
        let recorder = Recorder(controller)
        
        controller.requestMinimize()
        
        #expect(!controller.isMaximized)
        #expect(recorder.sawMinimizeRequested())
        #expect(recorder.sawPictureInPictureUnavailable())
    }
    
    @Test
    func restoringMaximizesAgain() {
        let controller = ElementCallController.fake(connection: .connected)
        controller.requestMinimize()
        
        controller.restore()
        
        #expect(controller.isMaximized)
    }
    
    /// The duration the minimized bar shows. Only a joined call sets it otherwise, which left that
    /// branch of the bar unreachable from anything that could be looked at.
    @Test
    func aFakeCanCarryAConnectionTimeForTheBar() {
        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        
        #expect(ElementCallController.fake(connection: .connected).connectedAt == nil)
        #expect(ElementCallController.fake(connection: .connected, connectedAt: startedAt).connectedAt == startedAt)
    }
}
