//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation
import Testing

/// What reaches the core when the layout declares its window and its bands (spec 003 R52–R58): the
/// exact range and set, once per change, and the paused band kept subscribed while the released one
/// lingers and goes.
@MainActor
struct DetailWindowTests {
    private func a(_ name: String, kind: MatrixRTCTileKind = .person) -> MatrixRTCTileID {
        MatrixRTCTileID(memberID: "@\(name):example.com:DEVICE", kind: kind)
    }
    
    private func stream(_ name: String) -> MatrixRTCStreamRef {
        MatrixRTCStreamRef(memberID: a(name).memberID, kind: .camera)
    }
    
    private func player(_ text: String) async throws -> MatrixRTCScenarioPlayer {
        let player = try MatrixRTCScenarioPlayer(scenario: MatrixRTCScenario.parse(text, name: "t"))
        await player.start()
        _ = await player.step()
        return player
    }
    
    @Test
    func theWindowIsForwardedExactlyAndAnEqualOneIsNotRepeated() async throws {
        let player = try await player("0s A#* B C D E F")
        player.call.setDetailWindow(.init(ranks: 2..<5, also: [a("A", kind: .screenShare)]))
        await player.settle()
        #expect(player.session.detailWindows.count == 1)
        #expect(player.session.detailWindow?.offset == 2)
        #expect(player.session.detailWindow?.length == 3)
        #expect(player.session.detailWindow?.also == [a("A", kind: .screenShare)])
        
        // The core republishes the roster on every declaration, so a repeat is a cost, not a no-op.
        player.call.setDetailWindow(.init(ranks: 2..<5, also: [a("A", kind: .screenShare)]))
        await player.settle()
        #expect(player.session.detailWindows.count == 1)
        
        player.call.setDetailWindow(.init(ranks: 0..<0, also: [a("D")]))
        await player.settle()
        #expect(player.session.detailWindows.count == 2)
        #expect(player.session.detailWindow?.length == 0, "fullscreen: no ranks, one identity")
        #expect(player.call.detailWindow == .init(ranks: 0..<0, also: [a("D")]))
        await player.call.disconnect()
    }
    
    /// A paused stream is subscribed but not sent, and stays that way however long it is paused; a
    /// released one that was drawn is paused at once and disabled after the linger.
    @Test
    func pausedStaysSubscribedAndReleasedGoesAfterTheLinger() async throws {
        let player = try await player("0s B C\n5s tick")
        player.call.attachVideo(VideoFrameSlot(), memberID: a("C").memberID)
        player.call.setVideoVisibility(paused: [a("B")], released: [a("C")])
        await player.settle()
        #expect(player.session.lastConstraints(for: stream("B")) == .init(isEnabled: true, isVisible: false, pixelSize: nil))
        #expect(player.session.lastConstraints(for: stream("C")) == .init(isEnabled: true, isVisible: false, pixelSize: nil))
        
        _ = await player.step()
        #expect(player.session.lastConstraints(for: stream("B"))?.isEnabled == true, "paused is never released by the linger")
        #expect(player.session.lastConstraints(for: stream("C"))?.isEnabled == false)
        await player.call.disconnect()
    }
    
    /// A tile bouncing at the edge of the band: released and back within the linger costs nothing.
    @Test
    func releasedAndBackWithinTheLingerIsNeverDisabled() async throws {
        let player = try await player("0s B\n1s tick\n5s tick")
        player.call.attachVideo(VideoFrameSlot(), memberID: a("B").memberID)
        player.call.setVideoVisibility(paused: [], released: [a("B")])
        await player.settle()
        _ = await player.step()
        player.call.setVideoVisibility(paused: [a("B")], released: [])
        await player.settle()
        _ = await player.step()
        #expect(player.session.constraints.map(\.constraints.isEnabled).allSatisfy { $0 }, "the pending release was cancelled")
        await player.call.disconnect()
    }
    
    /// A stream no tile ever drew has no picture to keep and nothing to come back to: a hero
    /// arriving behind the one shown, or at a join everyone past the band. It is released at once,
    /// not held open by the linger (Android's appendix 2).
    @Test
    func aStreamNeverDrawnIsReleasedAtOnce() async throws {
        let player = try await player("0s B C\n5s tick")
        player.call.setVideoVisibility(paused: [], released: [a("B")])
        await player.settle()
        #expect(player.session.lastConstraints(for: stream("B")) == .init(isEnabled: false, isVisible: false, pixelSize: nil))
        
        _ = await player.step()
        #expect(player.session.constraints.count { $0.stream == stream("B") } == 1, "the linger has nothing left to do")
        await player.call.disconnect()
    }
    
    /// A paused tile keeps its view, so when it scrolls back in nothing re-attaches: the call has to
    /// ask for the stream itself, at the size the tile last reported.
    @Test
    func aStreamLeavingThePausedBandIsAskedForAgainAtItsDrawnSize() async throws {
        let player = try await player("0s B")
        let slot = VideoFrameSlot()
        player.call.attachVideo(slot, memberID: a("B").memberID)
        player.call.reportDrawnSize(CGSize(width: 320, height: 240), slot: slot, memberID: a("B").memberID)
        await player.settle()
        #expect(player.session.lastConstraints(for: stream("B")) == .init(isEnabled: true, isVisible: true, pixelSize: CGSize(width: 320, height: 240)))
        
        player.call.setVideoVisibility(paused: [a("B")], released: [])
        await player.settle()
        #expect(player.session.lastConstraints(for: stream("B"))?.isVisible == false)
        // A size report while paused must not re-subscribe behind the stage's back.
        player.call.reportDrawnSize(CGSize(width: 640, height: 480), slot: slot, memberID: a("B").memberID)
        await player.settle()
        #expect(player.session.lastConstraints(for: stream("B"))?.isVisible == false)
        
        player.call.setVideoVisibility(paused: [], released: [])
        await player.settle()
        #expect(player.session.lastConstraints(for: stream("B")) == .init(isEnabled: true, isVisible: true, pixelSize: CGSize(width: 640, height: 480)))
        await player.call.disconnect()
    }
}
