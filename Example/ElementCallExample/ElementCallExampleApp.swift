//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import SwiftUI

/// A call screen with no call behind it, for driving by hand or by a UI test.
///
/// It opens on a catalogue of fixtures and minimizes back to it, which is how the Android harness
/// works and for the same reason: the handover between full screen and minimized is the host's job,
/// and a harness that cannot leave the call screen cannot show it going wrong.
///
/// `-fixture <key>` skips the catalogue and opens that fixture directly, and `-scenario <name>` plays
/// that scenario file, so a test starts where it means to rather than tapping its way there through
/// a menu it does not care about. With the argument present the hierarchy is exactly what it was
/// before the catalogue existed. The keys are shared with Android's sample: see
/// `element-call-feature-hq/harness/fixtures.md`.
///
/// `-chromeReturnDelay <seconds>` replaces how long chrome a scroll hid takes to come back. For the
/// UI tests that check it went: on a slow CI runner the check came after the default two seconds,
/// and saw it already back.
///
/// `-headset` connects pretend AirPods to every fixture, so the audio button is a menu.
@main
struct ElementCallExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ElementCallExampleRootView(target: .fromLaunchArguments())
                .environment(\.elementCallChromeReturnDelay, Self.chromeReturnDelay ?? EnvironmentValues().elementCallChromeReturnDelay)
        }
    }
    
    private static var chromeReturnDelay: Duration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-chromeReturnDelay"),
              let seconds = arguments[safe: index + 1].flatMap(Double.init) else { return nil }
        return .seconds(seconds)
    }
}

struct ElementCallExampleRootView: View {
    let target: ElementCallExampleLaunchTarget
    
    @State private var host = ElementCallExampleHost()
    @State private var video = TestPatternVideo()
    
    var body: some View {
        ZStack {
            // The catalogue is not merely covered while the call is up, it is unmounted. A `List`
            // losing its scroll position costs nothing, and in exchange the accessibility tree a UI
            // test walks during a call is the one it walked before any of this existed.
            if host.session == nil || host.isMinimized {
                ElementCallExampleCatalogue(target: target,
                                            notice: host.notice,
                                            returningTo: host.lastOpenedRow,
                                            onPick: { host.open($0) },
                                            onPickScenario: { host.open($0) })
                    .transition(.opacity)
                    // An inset rather than an overlay: it pushes the list down instead of covering
                    // its first row, which is what a host does and what makes the point of the
                    // thing — you can see the catalogue behind the call — actually legible.
                    .safeAreaInset(edge: .top) {
                        if let session = host.session {
                            ElementCallMinimizedBar(controller: session.controller) { host.restore() }
                        }
                    }
            }
            
            // Unmounted while minimized rather than left to draw `ElementCallView`'s own minimized
            // branch. That branch is `Color.clear`, which SwiftUI still hit-tests, so a shipping
            // host gets away with it and a full-screen one over this catalogue would silently eat
            // every tap on the list and look like a broken list.
            if let session = host.session, !host.isMinimized {
                callScreen(session)
                    .transition(.opacity)
            }
        }
        // The shape of the space, as the stage decides it, so our own pattern turns when the stage does.
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { video.setLandscape($0) }
        // Presenting the call is the host's to animate, so the harness does what a host would: a
        // cross-fade between the catalogue and the call, both ways.
        .animation(.easeInOut(duration: 0.3), value: host.session == nil || host.isMinimized)
        .onAppear {
            guard host.session == nil else { return }
            // Opened by a launch argument: straight to the call, with no fade from a catalogue the
            // user never saw, so a UI test starts on the tree it expects.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                switch target {
                case .fixture(let fixture): host.open(fixture)
                case .scenario(let scenario): host.open(scenario)
                case .catalogue, .unknown: break
                }
            }
        }
    }
    
    /// How far the control bar reaches above the bottom safe area: `ElementCallView.controlsClearance`,
    /// which is the package's own and not public.
    private static let controlBarClearance: CGFloat = 84
    
    @ViewBuilder
    private func callScreen(_ session: ElementCallExampleHost.Session) -> some View {
        switch session.presentation {
        case .harness(let context):
            ElementCallHarnessScreen(context: context)
                // Always attached: a tile draws the pattern exactly when it has video, so our own
                // tile lights up when the camera is turned on, as on Android. The timer only runs
                // while some slot is attached, so a fixture with no video costs nothing.
                .environment(\.elementCallPreviewVideo, video.source)
        case .live(let viewModel):
            // The shipping view, not the harness one: a connecting state is the one thing a real
            // view model can render without a joined call, so there is no reason to fake it.
            ElementCallScreen(viewModel: viewModel)
        case .scripted(let viewModel, let playback):
            // The shipping view over a scripted call: tiles marked with video draw the test
            // pattern, because the scripted session has no pictures of its own.
            ElementCallScreen(viewModel: viewModel)
                .environment(\.elementCallPreviewVideo, video.source)
                // Floating just above the control bar, so it covers neither bar and the call is laid
                // out exactly as it is without it.
                .overlay(alignment: .bottom) {
                    ElementCallExampleScenarioScrubber(playback: playback)
                        .padding(.bottom, Self.controlBarClearance + 8)
                }
        }
    }
}
