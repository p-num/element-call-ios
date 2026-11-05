//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
@testable import ElementCallKit
import MatrixRtc
import Testing

/// What happens between the core announcing a reaction and the UI drawing it: the preference, the
/// spread, the sound and the four seconds (spec 037).
@Suite("Reaction reception")
@MainActor
struct ReactionReceptionTests {
    @Test
    func offShowsAndPlaysNothing() async throws {
        let call = try await Call(mode: .off, spread: .zero)
        call.react("@bob:example.com:DEVICE", name: "clapping")
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.session.reactions.isEmpty)
        #expect(call.session.reactionTimers.isEmpty)
        #expect(call.renderPeak() == 0)
    }
    
    /// R2b: it waits out its spread, then shows and sounds at the same moment.
    @Test
    func showsAndSoundsTogetherOnceItsSpreadIsOver() async throws {
        let call = try await Call(mode: .withSound, spread: .milliseconds(300))
        call.react("@bob:example.com:DEVICE", name: "clapping")
        try await call.waitForReception(count: 1)
        
        call.clock.advance(by: .milliseconds(299))
        await settle()
        #expect(call.session.reactions.isEmpty)
        #expect(call.renderPeak() == 0)
        
        call.clock.advance(by: .milliseconds(1))
        try await waitUntil { !call.session.reactions.isEmpty }
        let reaction = try #require(call.session.reactions.first)
        #expect(reaction.memberID == "@bob:example.com:DEVICE")
        #expect(reaction.emoji == "👏")
        #expect(reaction.sound == "clap")
        #expect(reaction.spread == .milliseconds(300))
        #expect(call.renderPeak() > 0)
    }
    
    @Test
    func withoutSoundShowsButIsSilent() async throws {
        let call = try await Call(mode: .withoutSound, spread: .zero)
        call.react("@bob:example.com:DEVICE", name: "clapping")
        try await waitUntil { !call.session.reactions.isEmpty }
        #expect(call.renderPeak() == 0)
    }
    
    /// R1a with R2b: four seconds from arrival, however long it waited to show.
    @Test
    func goesFourSecondsAfterItArrived() async throws {
        let call = try await Call(mode: .withoutSound, spread: .milliseconds(400))
        call.react("@bob:example.com:DEVICE", name: "party")
        try await call.waitForReception(count: 1)
        
        call.clock.advance(by: .milliseconds(3999))
        try await waitUntil { call.session.reactions.count == 1 }
        call.clock.advance(by: .milliseconds(1))
        try await waitUntil { call.session.reactions.isEmpty }
        #expect(call.session.reactionTimers.isEmpty)
    }
    
    /// R15: a change applies to what arrives after it; what is already showing finishes.
    @Test
    func turningOffLeavesWhatIsShowing() async throws {
        let call = try await Call(mode: .withoutSound, spread: .zero)
        call.react("@bob:example.com:DEVICE", name: "party")
        try await waitUntil { call.session.reactions.count == 1 }
        
        call.session.reactionsMode = .off
        call.react("@carol:example.com:DEVICE", name: "party")
        try await Task.sleep(for: .milliseconds(50))
        #expect(call.session.reactions.map(\.memberID) == ["@bob:example.com:DEVICE"])
    }
    
    /// Spreads beyond half a second are cut to it, so nothing can outlive R1a's four seconds.
    @Test
    func theSpreadIsCappedAtHalfASecond() async throws {
        let call = try await Call(mode: .withoutSound, spread: .seconds(2))
        call.react("@bob:example.com:DEVICE", name: "party")
        try await call.waitForReception(count: 1)
        call.clock.advance(by: .milliseconds(500))
        try await waitUntil { call.session.reactions.first?.spread == .milliseconds(500) }
    }
    
    // MARK: - Support
    
    private struct Call {
        let clock = MatrixRTCManualClock()
        let scripted: MatrixRTCScriptedSession
        let session: MatrixRTCMediaSession
        let renderer: CallSoundEffectRenderer
        
        init(mode: MatrixRTCReactionsMode, spread: Duration) async throws {
            scripted = MatrixRTCScriptedSession(localMemberID: "@alice:example.com:DEVICE", clock: clock)
            renderer = CallSoundEffectRenderer(join: [], leave: [], raiseHand: [])
            // Every sound a single loud sample, installed before the call can decode the real ones.
            renderer.installReactionSounds(.init(CallSoundEffectRenderer.reactionSoundNames.map { ($0, [1, 1, 1, 1]) }))
            session = MatrixRTCMediaSession(localMemberID: "@alice:example.com:DEVICE",
                                            mediaSession: scripted,
                                            audio: CallAudio(soundEffects: renderer),
                                            clock: clock,
                                            capturesCamera: false,
                                            reactionSpread: { spread })
            session.reactionsMode = mode
            await session.start()
        }
        
        /// The emoji and sound the core resolves for `name`, as it delivers them.
        func react(_ memberID: String, name: String) {
            let emoji = reactionCatalog().first { $0.name == name }?.emoji ?? "🎉"
            let sound = reactionSoundFor(name: name)
            scripted.push(event: .reaction(memberId: memberID, emoji: emoji, name: name, sound: sound))
        }
        
        func waitForReception(count: Int) async throws {
            try await waitUntil { session.reactionTimers.count == count }
        }
        
        func renderPeak() -> Float {
            var output = [Float](repeating: 0, count: 4)
            output.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(mNumberBuffers: 1,
                                           mBuffers: AudioBuffer(mNumberChannels: 1,
                                                                 mDataByteSize: UInt32(4 * MemoryLayout<Float>.size),
                                                                 mData: buffer.baseAddress))
                withUnsafeMutablePointer(to: &list) {
                    _ = renderer.render(frameCount: 4, audioBufferList: $0)
                }
            }
            return output.map(abs).max() ?? 0
        }
    }
    
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
}
