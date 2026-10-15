//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCall
import SwiftUI

/// The example app's stand-in for a host: it owns where the call is, which is the one job a host has
/// that the package deliberately does not do for it.
///
/// This exists because the harness used to be a *view* harness — it drew a call screen and nothing
/// else, so minimize and hang up did nothing and the handover a real host has to implement was
/// invisible here. There is now somewhere to go back to, so they mean something.
@MainActor
@Observable
final class ElementCallExampleHost {
    /// A connected fixture has no call behind it, so its screen runs on a context whose taps are
    /// applied to the view state; a connecting one has a real view model over a fake controller,
    /// which routes minimize and hang up through ``ElementCallController`` exactly as a shipping
    /// screen does. Keeping the two apart here means neither has to pretend to be the other.
    enum Presentation {
        case harness(ElementCallScreenContext)
        case live(ElementCallScreenViewModel)
        /// A real view model over a fake controller carrying a scripted call: the shipping screen,
        /// with the rosters coming from a scenario file rather than a backend.
        case scripted(ElementCallScreenViewModel, ElementCallExampleScenarioPlayback)
    }
    
    struct Session {
        /// Nil for a scenario.
        let fixture: ElementCallExampleFixture?
        let presentation: Presentation
        /// What the minimized bar is drawn from. For a `live` session it is the very controller the
        /// screen runs on; for a `harness` one there is no controller behind the screen at all, so
        /// this is one made to stand beside it.
        let controller: ElementCallController
    }
    
    private(set) var session: Session?
    /// A scenario that did not parse, named with its line, shown on the catalogue rather than
    /// printed: the package's lint forbids `print`, and a notice on screen is what a person and a
    /// failure screenshot can both read.
    private(set) var notice: String?
    /// The catalogue row last opened, so the list can come back to it: it is unmounted while a call
    /// is up, and a new list starts at the top.
    private(set) var lastOpenedRow: String?
    private var cancellables = Set<AnyCancellable>()
    /// Only for a harness session. A live one is asked, below.
    private var isHarnessMinimized = false
    
    /// A live session does not get a second copy of this: `isMaximized` is the controller's own bit
    /// and the same one `ElementCallView` unmounts its tiles on, so it is read rather than
    /// mirrored. A harness session has no controller behind its screen and cannot write
    /// `viewState` — that setter is fileprivate so only the package moves it — so the example owns
    /// the bit there. It costs nothing, because the call screen is unmounted while minimized and
    /// `viewState.isMaximized` is only consulted by a screen that is on the tree.
    var isMinimized: Bool {
        guard let session else { return false }
        switch session.presentation {
        case .harness: return isHarnessMinimized
        case .live, .scripted: return !session.controller.isMaximized
        }
    }
    
    func open(_ scenario: ElementCallExampleScenario) {
        lastOpenedRow = ElementCallExampleCatalogue.rowID(scenario)
        cancellables.removeAll()
        isHarnessMinimized = false
        notice = nil
        do {
            let playback = try ElementCallExampleScenarioPlayback(scenario: scenario.load())
            let controller = ElementCallController.fake(connection: .connected,
                                                        room: ElementCallFakeRoom(displayName: scenario.name),
                                                        connectedAt: .now,
                                                        call: playback.player.call)
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            let viewModel = ElementCallScreenViewModel(controller: controller)
            playback.attach(context: viewModel.context, controller: controller)
            session = Session(fixture: nil,
                              presentation: .scripted(viewModel, playback),
                              controller: controller)
            Task {
                await playback.start()
                playback.play()
            }
        } catch {
            notice = "Scenario \(scenario.name) failed to load: \(error)"
        }
    }
    
    func open(_ fixture: ElementCallExampleFixture) {
        lastOpenedRow = ElementCallExampleCatalogue.rowID(fixture)
        cancellables.removeAll()
        isHarnessMinimized = false
        
        switch fixture.kind {
        case .connected(var state):
            // A headset cannot be paired with the simulator, so the menu the audio button becomes
            // with one is reached by asking for it.
            if ProcessInfo.processInfo.arguments.contains("-headset") {
                state.audioOutputs = ElementCallPreviewFixtures.headsetAudioOutputs
                state.audioOutput = state.audioOutputs.first
            }
            // Built from the view state rather than defaulted, so the name on the bar and the name
            // in the top bar cannot drift apart. They agree today only by coincidence: the fake
            // room and `ElementCallPreviewFixtures.connected` happen to pick the same string.
            let room = ElementCallFakeRoom(displayName: state.roomName, isDirect: state.isDirect)
            let controller = makeController(connection: .connected, room: room)
            let context = ElementCallScreenContext.harness(state: state) { [weak self] action in
                self?.handle(action)
            }
            session = Session(fixture: fixture, presentation: .harness(context), controller: controller)
            isHarnessMinimized = fixture.opensMinimized
            
        case .connecting(let connection):
            let controller = makeController(connection: connection, room: ElementCallFakeRoom())
            // The real host contract, and the only place in this repository it is exercised: the
            // screen calls `requestMinimize()`, the fake has no Picture in Picture window to open
            // because binding one needs a live call, so the controller reports
            // `pictureInPictureUnavailable` and we put up the bar — which is exactly what the
            // package's documentation tells a host to do.
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            session = Session(fixture: fixture,
                              presentation: .live(ElementCallScreenViewModel(controller: controller)),
                              controller: controller)
        }
    }
    
    func restore() {
        guard let session else { return }
        switch session.presentation {
        case .harness: isHarnessMinimized = false
        case .live, .scripted: session.controller.restore()
        }
    }
    
    /// Deliberately does not tear down `cancellables`: for a live fixture this is called *from*
    /// that subscription's own delivery, and dropping the session is enough — the controller goes
    /// with it and takes its publisher along, leaving the subscription inert. `open` clears them.
    func endCall() {
        isHarnessMinimized = false
        if case .scripted(_, let playback)? = session?.presentation {
            Task { await playback.stop() }
        }
        session = nil
    }
    
    // MARK: - Private
    
    /// `connectedAt` so the bar draws its duration timer. Nothing else can give it one — only a
    /// joined call sets it otherwise — and the timer is half of what makes the bar look like an
    /// ongoing call rather than a button.
    private func makeController(connection: ElementCallConnection,
                                room: ElementCallFakeRoom) -> ElementCallController {
        .fake(connection: connection, room: room, connectedAt: .now)
    }
    
    /// From a harness context, which can only report these rather than perform them.
    private func handle(_ action: ElementCallScreenViewAction) {
        switch action {
        case .minimize:
            isHarnessMinimized = true
        case .hangUp, .dismiss:
            endCall()
        default:
            // Everything reversible is applied to the view state by the context itself.
            break
        }
    }
    
    /// From a real controller, on a connecting fixture.
    private func handle(_ action: ElementCallControllerAction) {
        switch action {
        case .ended:
            endCall()
        case .minimizeRequested, .restoreRequested, .pictureInPictureStarted, .pictureInPictureUnavailable:
            // The controller has already moved `isMaximized`, which `isMinimized` reads, so the bar
            // comes and goes without anything else happening here. A host with its own chrome to
            // rearrange would have more to do.
            break
        }
    }
}
