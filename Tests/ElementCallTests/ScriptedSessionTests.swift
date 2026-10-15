//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation
import Testing

/// The scripted session and the manual clock, which every scenario dump runs on: a roster frame
/// reaches the call's tiles, a `me` frame reaches its own tile, `detail-only` narrows detail, and
/// something the call schedules on its clock fires when the clock is advanced and not before.
@MainActor
struct ScriptedSessionTests {
    private func a(_ name: String, kind: MatrixRTCTileKind = .person) -> MatrixRTCTileID {
        MatrixRTCTileID(memberID: "@\(name):example.com:DEVICE", kind: kind)
    }
    
    @Test
    func rosterFramesReachTheCallInOrderAndDetailOnlyNarrowsThem() async throws {
        let scenario = try MatrixRTCScenario.parse("""
        0s  A#* B! C
        1s  detail-only B
        2s  B! A#* C
        """, name: "t")
        let player = MatrixRTCScenarioPlayer(scenario: scenario)
        await player.start()
        
        _ = await player.step()
        #expect(player.call.tiles.order.map(\.id) == [a("A", kind: .screenShare), a("B"), a("C")])
        #expect(player.call.tiles.detail.count == 3)
        #expect(player.call.tiles.detail[a("B")]?.isSpeaking == true)
        #expect(player.call.tiles.order.first?.isHero == true)
        
        _ = await player.step()
        _ = await player.step()
        #expect(player.call.tiles.order.map(\.id) == [a("B"), a("A", kind: .screenShare), a("C")])
        #expect(Set(player.call.tiles.detail.keys) == [a("B")], "a narrowed window delivers references for the rest")
        #expect(player.call.tiles.order[1].isHero == true, "hero is a property of the reference")
        #expect(player.isFinished)
        #expect(await player.step() == nil)
        await player.call.disconnect()
    }
    
    @Test
    func ourOwnTileFollowsTheMeFrame() async throws {
        let scenario = try MatrixRTCScenario.parse("0s B\n1s me vm", name: "t")
        let player = MatrixRTCScenarioPlayer(scenario: scenario)
        await player.start()
        #expect(player.call.ownTile?.isLocal == true)
        #expect(player.call.ownTile?.hasVideo == false)
        _ = await player.step()
        _ = await player.step()
        #expect(player.call.ownTile?.hasVideo == true)
        #expect(player.call.ownTile?.isMicrophoneMuted == true)
        await player.call.disconnect()
    }
    
    /// The camera button during a scenario: a scripted call has no device to open (on a phone the
    /// example app has no camera usage string, and opening it aborted the process), so turning the
    /// camera on or flipping it changes the call's state only.
    /// A scenario has no raise times, so the queue is the roster's order with ours last, and ours
    /// moves up as hands ahead of it come down: Android's harness numbers the same way (009 C7).
    @Test
    func handsAreNumberedInRosterOrderWithOursLast() async throws {
        let scenario = try MatrixRTCScenario.parse("0s B^ C D^\n1s me ^\n2s C D^", name: "t")
        let player = MatrixRTCScenarioPlayer(scenario: scenario)
        await player.start()
        
        _ = await player.step()
        #expect(player.call.tiles.detail[a("B")]?.handRaisedPosition == 1)
        #expect(player.call.tiles.detail[a("C")]?.handRaisedPosition == nil)
        #expect(player.call.tiles.detail[a("D")]?.handRaisedPosition == 2)
        _ = await player.step()
        try await waitFor { player.call.ownTile?.handRaisedPosition == 3 }
        _ = await player.step()
        #expect(player.call.tiles.detail[a("D")]?.handRaisedPosition == 1)
        try await waitFor { player.call.ownTile?.handRaisedPosition == 2 }
        await player.call.disconnect()
    }
    
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
    
    @Test
    func theCameraTurnsOnAndFlipsWithoutADevice() async throws {
        let scenario = try MatrixRTCScenario.parse("0s B", name: "t")
        let player = MatrixRTCScenarioPlayer(scenario: scenario)
        await player.start()
        _ = await player.step()
        try await player.call.setCameraEnabled(true)
        #expect(player.call.isCameraEnabled)
        try player.call.switchCamera()
        #expect(player.call.isFrontCamera == false)
        try await player.call.setCameraEnabled(false)
        #expect(player.call.isCameraEnabled == false)
        await player.call.disconnect()
    }
    
    /// The linger is the call's own timer, and it is what the scenario clock exists for: a released
    /// stream is paused at once and disabled only three seconds later, on the scenario's clock.
    @Test
    func theReleaseLingerRunsOnTheScenarioClock() async throws {
        let scenario = try MatrixRTCScenario.parse("0s B C\n1s tick\n4s tick", name: "t")
        let player = MatrixRTCScenarioPlayer(scenario: scenario)
        await player.start()
        _ = await player.step()
        
        player.call.attachVideo(VideoFrameSlot(), memberID: a("C").memberID)
        player.call.setReleasedVideoStreams([a("C")])
        await player.settle()
        let stream = MatrixRTCStreamRef(memberID: a("C").memberID, kind: .camera)
        #expect(player.session.lastConstraints(for: stream)?.isVisible == false)
        #expect(player.session.lastConstraints(for: stream)?.isEnabled == true, "paused, not yet released")
        
        _ = await player.step()
        #expect(player.session.lastConstraints(for: stream)?.isEnabled == true, "one second in, still lingering")
        
        _ = await player.step()
        #expect(player.session.lastConstraints(for: stream)?.isEnabled == false, "the linger expired on the clock")
        #expect(player.session.constraints.last?.time == .seconds(4))
        await player.call.disconnect()
    }
    
    @Test
    func theWindowIsRecordedWithItsTime() async throws {
        let scenario = try MatrixRTCScenario.parse("0s B C\n2s tick", name: "t")
        let player = MatrixRTCScenarioPlayer(scenario: scenario)
        await player.start()
        _ = await player.step()
        _ = await player.step()
        player.session.setDetailWindow(offset: 2, len: 4, also: [])
        #expect(player.session.detailWindow?.time == .seconds(2))
        #expect(player.session.detailWindow?.offset == 2)
        #expect(player.session.detailWindow?.length == 4)
        await player.call.disconnect()
    }
    
    @Test
    func aSleeperWakesOnlyWhenTheClockPassesIt() async throws {
        let clock = MatrixRTCManualClock()
        let woke = Woke()
        // The deadline is fixed before the task starts: a `sleep(for:)` inside the task would read
        // the clock whenever the task happened to run, which can be after the advances below.
        let deadline = clock.now.advanced(by: .seconds(2))
        let sleeper = Task {
            try await clock.sleep(until: deadline, tolerance: nil)
            await woke.set()
        }
        await Task.yield()
        clock.advance(by: .seconds(1))
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await woke.value == false)
        clock.advance(by: .seconds(1))
        _ = try await sleeper.value
        #expect(await woke.value == true)
        
        let far = clock.now.advanced(by: .seconds(10))
        let cancelled = Task { try await clock.sleep(until: far, tolerance: nil) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
    
    private actor Woke {
        var value = false
        func set() {
            value = true
        }
    }
}
