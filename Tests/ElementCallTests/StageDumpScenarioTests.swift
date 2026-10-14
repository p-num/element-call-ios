//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
@testable import ElementCallUI
import Foundation
import SnapshotTesting
import Testing

/// Every scenario in the vendored corpus, run through the real call over the scripted session, the
/// real view model, and the real arrangement, one frame at a time on the manual clock; each frame's
/// dump is a line snapshot. This is where the transition rules are pinned (spec 003 R42, R48, R49,
/// R52–R59, R60, R63), because they are sequences rather than states: a tile crossing the band edge
/// keeps its picture and its stream, the window moves on row boundaries only, the linger holds
/// through a bounce, the offset survives fullscreen, a leaver never leaves an empty area.
///
/// What the stage does in SwiftUI — read the offset back, re-anchor after a rotation, restore the
/// offset after fullscreen, feed the live set back for hysteresis — is mirrored here by
/// ``ScenarioStage``, the one part of this that is not shipped code. The gestures themselves are
/// the UI tests' business.
@MainActor
struct StageDumpScenarioTests {
    private var recordMode: SnapshotTestingConfiguration.Record {
        // The same marker as the image snapshots, for the same reason (see `PreviewTests`).
        let marker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".record-snapshots")
        return ProcessInfo().environment["RECORD_FAILURES"].map(Bool.init) == true || FileManager.default.fileExists(atPath: marker.path) ? .failed : .missing
    }
    
    @Test(arguments: try ScenarioParserTests.corpus())
    func scenarioDumpsMatch(url: URL) async throws {
        let scenario = try ScenarioParserTests.load(url)
        let stage = ScenarioStage(scenario: scenario)
        let dumps = try await stage.run()
        await stage.finish()
        withSnapshotTesting(record: recordMode) {
            assertSnapshot(of: dumps.joined(separator: "\n\n") + "\n", as: .lines, named: scenario.name)
        }
    }
}

/// Drives one scenario the way `ElementCallStage` drives a call: the same layout input, the same
/// side effects on the call, the same bookkeeping around the offset. Mirrored rather than shared
/// because the stage's copy lives in SwiftUI state and modifiers, which cannot run in-process.
@MainActor
final class ScenarioStage {
    let scenario: MatrixRTCScenario
    let player: MatrixRTCScenarioPlayer
    let controller: ElementCallController
    let viewModel: ElementCallScreenViewModel
    
    private var metrics: ElementCallStageLayout.Metrics
    private var scrollOffset: CGFloat = 0
    private var liveTileIDs: Set<MatrixRTCTileID> = []
    private var isMaximized = true
    private var offsetBeforeFullscreen: CGFloat?
    
    init(scenario: MatrixRTCScenario) {
        self.scenario = scenario
        player = MatrixRTCScenarioPlayer(scenario: scenario)
        controller = .fake(connection: .connected, call: player.call)
        viewModel = ElementCallScreenViewModel(controller: controller)
        metrics = Self.metrics(for: MatrixRTCScenario.defaultViewport)
    }
    
    private var context: ElementCallScreenContext {
        viewModel.context
    }
    
    func run() async throws -> [String] {
        await player.start()
        var dumps = [String]()
        while let frame = await player.step() {
            try await apply(frame)
            let (layout, tiles) = arrange()
            await declare(layout)
            dumps.append(ElementCallStageDump.render(frame: frame, layout: layout, tiles: tiles, call: player.call))
        }
        return dumps
    }
    
    func finish() async {
        await player.call.disconnect()
    }
    
    // MARK: - Frames
    
    private func apply(_ frame: MatrixRTCScenario.Frame) async throws {
        switch frame.event {
        case .roster(let tokens):
            // The view model refreshes on the roster the player already delivered; the stage
            // sees the tiles once it has.
            let expected = [player.call.ownTile?.id].compactMap { $0 } + tokens.map(\.tileID)
            // Hands as well as identities: a frame that only raises one keeps every id, and would
            // otherwise be dumped before the screen had it. Shown hands, so none one-to-one (009 R33).
            let hands = Dictionary(uniqueKeysWithValues: tokens.map { ($0.tileID, $0.hasHandRaised) })
            try await waitUntil("tiles \(tokens.map(\.name))") { [self] in
                let state = context.viewState
                return state.tiles.map(\.id) == expected && state.tiles.allSatisfy { tile in
                    tile.isLocal || tile.hasHandRaised == (!state.isOneToOne && hands[tile.id] == true)
                }
            }
            // A departure that shortens the grid past the offset: the stage settles to the new end.
            clampOffset()
        case .me(let hasVideo, let isMicrophoneMuted, let hasHandRaised):
            try await waitUntil("me") { [self] in
                context.viewState.tiles.first?.hasVideo == hasVideo && context.viewState.tiles.first?.isMicrophoneMuted == isMicrophoneMuted
                    && context.viewState.isHandRaised == hasHandRaised
            }
        case .viewport(let size, let top, let bottom):
            metrics = Self.metrics(for: .viewport(size: size, topInset: top, bottomInset: bottom))
        case .scroll(let offset):
            scrollOffset = min(max(0, offset), arrange().0.maxScrollOffset)
        case .rotate(let orientation):
            let anchor = firstVisibleGridTile()
            let area = metrics.area
            let isLandscape = orientation == .landscape
            metrics.area = CGSize(width: isLandscape ? max(area.width, area.height) : min(area.width, area.height),
                                  height: isLandscape ? min(area.width, area.height) : max(area.width, area.height))
            // The first visible grid tile is still visible afterwards (R66).
            if let anchor, let placement = arrange().0.placements.first(where: { $0.id == anchor && !$0.isSpotlight }) {
                let layout = arrange().0
                let gridTop = layout.placements.filter { !$0.isSpotlight }.map(\.frame.minY).min() ?? 0
                scrollOffset = min(layout.maxScrollOffset, max(0, placement.frame.minY - gridTop))
            }
        case .fullscreen(let tileID):
            if let tileID {
                offsetBeforeFullscreen = scrollOffset
                context.fullscreenTileID = tileID
            } else {
                context.fullscreenTileID = nil
                if let offset = offsetBeforeFullscreen {
                    scrollOffset = min(offset, arrange().0.maxScrollOffset)
                    offsetBeforeFullscreen = nil
                }
            }
        case .swipeHero(let direction):
            let heroes = ElementCallSpotlight.heroes(in: context.viewState.tiles)
            guard let spotlight = context.viewState.spotlightID, let shown = heroes.firstIndex(of: spotlight) else { break }
            // The stack does not wrap (R23).
            let target = direction == .next ? min(heroes.count - 1, shown + 1) : max(0, shown - 1)
            guard target != shown else { break }
            context.shownHeroID = heroes[target]
            try await waitUntil("hero \(target)") { [self] in context.viewState.spotlightID == heroes[target] }
        case .minimize:
            isMaximized = false
            // The stage unmounts, and with it every tile's video view: each detaches its slot and
            // a source with no slot left goes idle, which is what pauses its stream in the app.
            for (id, slot) in slots {
                player.call.detachVideo(slot, memberID: id.memberID, kind: id.kind.videoStreamKind)
            }
            slots.removeAll()
            await player.settle()
            // What `ElementCallView` declares while the stage is unmounted.
            let pictureInPicture = context.viewState.pictureInPictureTile
            let also = [pictureInPicture.id, player.call.pictureInPictureCandidate(spotlight: pictureInPicture.id, isExact: pictureInPicture.isExact)].compactMap { $0 }
            player.call.setDetailWindow(.init(ranks: 0..<ElementCallView.minimizedDetailWindowLength, also: Set(also)))
        case .restore:
            isMaximized = true
        case .detailOnly, .tick:
            break
        }
    }
    
    // MARK: - The stage's own bookkeeping
    
    private func arrange() -> (ElementCallStageLayout, [ElementCallTile]) {
        let tiles = context.viewState.tiles
        guard isMaximized else {
            // Unmounted: nothing composed, the window is whatever was declared on the way out.
            let viewport = CGRect(origin: CGPoint(x: 0, y: scrollOffset), size: metrics.area)
            return (ElementCallStageLayout(placements: [],
                                           contentHeight: viewport.height,
                                           viewport: viewport,
                                           detailWindow: player.call.detailWindow ?? .none),
                    tiles)
        }
        var layout = ElementCallStageLayout.compute(input(tiles: tiles))
        // The live set feeds back for the edge hysteresis; one more pass is where it converges.
        let live = Set(layout.placements.filter { $0.visibility == .live }.map(\.id))
        if live != liveTileIDs {
            liveTileIDs = live
            layout = ElementCallStageLayout.compute(input(tiles: tiles))
        }
        return (layout, tiles)
    }
    
    private func input(tiles: [ElementCallTile]) -> ElementCallStageLayout.Input {
        .init(tiles: tiles,
              spotlightID: context.viewState.spotlightID,
              fullscreenID: context.fullscreenTileID,
              scrollOffset: scrollOffset,
              liveTileIDs: liveTileIDs,
              metrics: metrics,
              speakerID: context.viewState.smallCallSpeakerID,
              // The chrome is always up in a scenario: what `ElementCallView` passes then, with the
              // top bar at the height it measures at the default text size.
              floatingInsets: .init(top: metrics.isLandscape ? 44 + ElementCallView.topChromeSpacing : 0,
                                    bottom: ElementCallView.controlsClearance))
    }
    
    /// The side effects the stage runs on a change of arrangement.
    private func declare(_ layout: ElementCallStageLayout) async {
        guard isMaximized else { return }
        let paused = Set(layout.placements.filter { $0.visibility == .paused }.map(\.id))
        player.call.setVideoVisibility(paused: paused, released: layout.hiddenTileIDs)
        player.call.setDetailWindow(layout.detailWindow)
        // A live tile's view attaches and reports the size it draws at; the harness stands in for
        // the view, so the constraints column says what the real stage would have sent.
        for placement in layout.placements where placement.visibility == .live && !placement.tile.isLocal {
            attach(placement)
        }
        await player.settle()
    }
    
    private var slots = [MatrixRTCTileID: VideoFrameSlot]()
    
    private func attach(_ placement: ElementCallTilePlacement) {
        let slot = slots[placement.id] ?? VideoFrameSlot()
        if slots[placement.id] == nil {
            slots[placement.id] = slot
            player.call.attachVideo(slot, memberID: placement.tile.memberID, kind: placement.tile.kind.videoStreamKind)
        }
        // Points at 2x, as a phone draws them.
        player.call.reportDrawnSize(CGSize(width: placement.frame.width * 2, height: placement.frame.height * 2),
                                    slot: slot,
                                    memberID: placement.tile.memberID,
                                    kind: placement.tile.kind.videoStreamKind)
    }
    
    private func clampOffset() {
        let maxOffset = arrange().0.maxScrollOffset
        if scrollOffset > maxOffset {
            scrollOffset = maxOffset
        }
    }
    
    private func firstVisibleGridTile() -> MatrixRTCTileID? {
        let layout = arrange().0
        let gridTop = layout.placements.filter { !$0.isSpotlight }.map(\.frame.minY).min() ?? 0
        return layout.placements
            .filter { !$0.isSpotlight && $0.frame.maxY > layout.viewport.minY + gridTop }
            .min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }?.id
    }
    
    private static func metrics(for viewport: MatrixRTCScenario.Event) -> ElementCallStageLayout.Metrics {
        guard case .viewport(let size, _, let bottom) = viewport else { preconditionFailure("not a viewport") }
        return .init(area: size, bottomInset: bottom, controlsClearance: ElementCallView.controlsClearance)
    }
    
    private struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String {
            "the screen never showed \(what)"
        }
    }
    
    /// Sleeps between looks so the view model's own main-actor work can run meanwhile.
    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout(what: what) }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
