//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import Foundation
import SwiftUI

/// A scenario file from the vendored corpus (`Tests/ElementCallTests/Scenarios`, bundled here as a
/// folder), so the rows in the catalogue and the dumps the tests pin are the same timelines.
struct ElementCallExampleScenario: Identifiable, Hashable {
    let name: String
    let url: URL
    
    var id: String {
        name
    }
    
    static let all: [ElementCallExampleScenario] = (Bundle.main.urls(forResourcesWithExtension: "txt", subdirectory: "Scenarios") ?? [])
        .map { ElementCallExampleScenario(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
        .sorted { $0.name < $1.name }
    
    static func named(_ name: String) -> ElementCallExampleScenario? {
        all.first { $0.name == name }
    }
    
    /// The scenario's own first comment line, which is what each file opens with.
    var detail: String {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let first = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("//") }) else { return "" }
        return first.dropFirst(2).trimmingCharacters(in: .whitespaces)
    }
    
    func load() throws -> MatrixRTCScenario {
        try MatrixRTCScenario.parse(String(contentsOf: url, encoding: .utf8), name: name)
    }
}

/// Plays a scenario into a scripted call at real-time pace, or one frame at a time, on the real
/// screen: rosters and `me` through the call, and the user's actions through the seams the screen
/// has for them — a scroll request, the fullscreen and shown-hero ids on the context, minimize and
/// restore on the controller. Rotation is the one thing the app cannot do to itself; its frame is
/// a cue on the scrubber to turn the phone. This is what lets the same scenario be watched on an
/// iOS and an Android device side by side.
@MainActor
@Observable
final class ElementCallExampleScenarioPlayback {
    let scenario: MatrixRTCScenario
    let player: MatrixRTCScenarioPlayer
    private(set) var current: MatrixRTCScenario.Frame?
    private(set) var isPlaying = false
    private var playTask: Task<Void, Never>?
    /// The screen the actions go to; attached by the host once the view model exists.
    private weak var context: ElementCallScreenContext?
    private weak var controller: ElementCallController?
    
    init(scenario: MatrixRTCScenario) {
        self.scenario = scenario
        player = MatrixRTCScenarioPlayer(scenario: scenario)
    }
    
    func attach(context: ElementCallScreenContext, controller: ElementCallController) {
        self.context = context
        self.controller = controller
    }
    
    /// What the frame that just landed asks of you, if anything: the one action the app cannot
    /// perform on itself.
    var cue: String? {
        if case .rotate(let orientation)? = current?.event {
            return "Turn the phone to \(orientation == .landscape ? "landscape" : "portrait")"
        }
        return nil
    }
    
    private func apply(_ frame: MatrixRTCScenario.Frame) {
        guard let context, let controller else { return }
        switch frame.event {
        case .scroll(let offset):
            context.scrollRequest = ElementCallScrollRequest(offset: offset)
        case .fullscreen(let tileID):
            context.fullscreenTileID = tileID
            context.isFullscreenChromeVisible = false
        case .swipeHero(let direction):
            // The same arithmetic as the stage's swipe: the stack in the model's order, clamped.
            let heroes = context.viewState.tiles.filter { $0.isHero && !$0.isLocal }.map(\.id)
            guard let spotlight = context.viewState.spotlightID, let shown = heroes.firstIndex(of: spotlight) else { return }
            let target = direction == .next ? min(heroes.count - 1, shown + 1) : max(0, shown - 1)
            context.shownHeroID = heroes[target]
        case .minimize:
            controller.requestMinimize()
        case .restore:
            controller.restore()
        case .roster, .me, .viewport, .rotate, .detailOnly, .tick:
            break
        }
    }
    
    var position: Int {
        player.position
    }
    
    var count: Int {
        scenario.frames.count
    }
    
    var isFinished: Bool {
        player.isFinished
    }
    
    func start() async {
        await player.start()
    }
    
    func step() async {
        current = await player.step()
        if let current {
            apply(current)
        }
    }
    
    /// Real-time pacing between frames, capped so a long quiet stretch does not stall the demo.
    func play() {
        guard !isPlaying, !isFinished else { return }
        isPlaying = true
        playTask = Task { [weak self] in
            while let self, !Task.isCancelled, !isFinished {
                let elapsed = player.clock.elapsed
                if let next = scenario.frames[safe: position] {
                    let wait = min(next.time - elapsed, .seconds(3))
                    if wait > .zero {
                        try? await Task.sleep(for: wait)
                    }
                }
                guard !Task.isCancelled else { break }
                await step()
            }
            self?.isPlaying = false
        }
    }
    
    func pause() {
        playTask?.cancel()
        playTask = nil
        isPlaying = false
    }
    
    func stop() async {
        pause()
        await player.call.disconnect()
    }
}

/// The transport controls over a scripted call: play, pause, step, and the frame that just landed.
struct ElementCallExampleScenarioScrubber: View {
    let playback: ElementCallExampleScenarioPlayback
    
    var body: some View {
        HStack(spacing: 12) {
            Button {
                if playback.isPlaying {
                    playback.pause()
                } else {
                    playback.play()
                }
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityIdentifier("example.scenario.playPause")
            Button {
                Task { await playback.step() }
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .disabled(playback.isFinished || playback.isPlaying)
            .accessibilityIdentifier("example.scenario.step")
            Text("\(playback.position)/\(playback.count)")
                .monospacedDigit()
            Text(playback.cue ?? playback.current?.text ?? playback.scenario.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(playback.cue == nil ? .white : .yellow)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("example.scenario.frame")
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.7), in: Capsule())
        .padding(.horizontal, 16)
    }
}
