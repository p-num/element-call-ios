//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
@testable import ElementCallKit
import Testing

nonisolated struct CallSoundEffectRendererTests {
    private func render(_ renderer: CallSoundEffectRenderer, frames: Int) -> [Float] {
        var output = [Float](repeating: .nan, count: frames)
        output.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(mNumberBuffers: 1,
                                       mBuffers: AudioBuffer(mNumberChannels: 1,
                                                             mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                                             mData: buffer.baseAddress))
            withUnsafeMutablePointer(to: &list) {
                _ = renderer.render(frameCount: AVAudioFrameCount(frames), audioBufferList: $0)
            }
        }
        return output
    }
    
    private func matches(_ rendered: [Float], _ expected: [Float]) -> Bool {
        rendered.count == expected.count && zip(rendered, expected).allSatisfy { abs($0 - $1) < 1e-6 }
    }
    
    @Test
    func rendersSilenceUntilTriggered() {
        let renderer = CallSoundEffectRenderer(join: [1, 1, 1], leave: [1, 1, 1], raiseHand: [])
        #expect(matches(render(renderer, frames: 4), [0, 0, 0, 0]))
    }
    
    @Test
    func playsTheSoundOnceAtHalfLevelFromItsStart() {
        // R14: half the call's level.
        let renderer = CallSoundEffectRenderer(join: [0.2, 0.4, 0.6, 0.8], leave: [], raiseHand: [])
        renderer.play(.join)
        #expect(matches(render(renderer, frames: 3), [0.1, 0.2, 0.3]))
        // Across the end of the sound: the rest, then silence, and nothing loops.
        #expect(matches(render(renderer, frames: 3), [0.4, 0, 0]))
        #expect(matches(render(renderer, frames: 2), [0, 0]))
    }
    
    @Test
    func aJoinAndALeaveOverlapRatherThanCutEachOtherOff() {
        let renderer = CallSoundEffectRenderer(join: [0.2, 0.2, 0.2], leave: [0.4, 0.4], raiseHand: [])
        renderer.play(.join)
        #expect(matches(render(renderer, frames: 1), [0.1]))
        renderer.play(.leave)
        #expect(matches(render(renderer, frames: 3), [0.3, 0.3, 0]))
    }
    
    @Test
    func aRetriggerStartsOver() {
        let renderer = CallSoundEffectRenderer(join: [0.2, 0.4, 0.6], leave: [], raiseHand: [])
        renderer.play(.join)
        _ = render(renderer, frames: 2)
        renderer.play(.join)
        #expect(matches(render(renderer, frames: 1), [0.1]))
    }
    
    /// Over the ceiling, the whole buffer comes down to it at once, rather than being clipped.
    @Test
    func theMixIsLimitedUnderFullScale() {
        let renderer = CallSoundEffectRenderer(join: [2, 1], leave: [2, 1], raiseHand: [])
        renderer.play(.join)
        renderer.play(.leave)
        let ceiling = CallSoundEffectRenderer.limiterCeiling
        #expect(matches(render(renderer, frames: 2), [ceiling, ceiling / 2]))
    }
    
    /// After a peak the level comes back gradually, and a quiet mix is left exactly as it was.
    @Test
    func theLimiterLetsGoAfterAPeak() {
        let renderer = CallSoundEffectRenderer(join: [4] + .init(repeating: 0.2, count: 96000), leave: [], raiseHand: [])
        renderer.play(.join)
        _ = render(renderer, frames: 1)
        let soonAfter = render(renderer, frames: 480)
        #expect(soonAfter.allSatisfy { $0 < 0.1 })
        // A second later, in the buffers the engine actually asks for, it is back to the sound's level.
        var later: [Float] = []
        for _ in 0..<100 {
            later = render(renderer, frames: 480)
        }
        #expect(abs(later[479] - 0.1) < 1e-4)
    }
    
    // MARK: - The sound effects volume (037 R22, R23)
    
    @Test
    func theVolumeSetsEveryEffectsLevelIncludingOneAlreadyPlaying() {
        let renderer = withReactions([("generic", [0.4, 0.4])])
        renderer.play(.join)
        renderer.playReaction("generic")
        #expect(matches(render(renderer, frames: 1), [0.3]))
        renderer.setEffectsGain(0.25)
        #expect(matches(render(renderer, frames: 1), [0.15]))
    }
    
    @Test
    func theRingbackKeepsItsLevelWhateverTheVolume() {
        let renderer = CallSoundEffectRenderer(join: [], leave: [], raiseHand: [], ringback: [0.2, 0.4])
        renderer.setEffectsGain(0)
        renderer.play(.ringback)
        #expect(matches(render(renderer, frames: 2), [0.1, 0.2]))
    }
    
    // MARK: - Reactions (037 R10)
    
    private func withReactions(_ sounds: [(String, [Float])]) -> CallSoundEffectRenderer {
        let renderer = CallSoundEffectRenderer(join: [0.2, 0.2], leave: [], raiseHand: [])
        renderer.installReactionSounds(.init(sounds))
        return renderer
    }
    
    @Test
    func aReactionPlaysNothingUntilItsSoundsAreInstalled() {
        let renderer = CallSoundEffectRenderer(join: [], leave: [], raiseHand: [])
        renderer.playReaction("clap")
        #expect(matches(render(renderer, frames: 2), [0, 0]))
    }
    
    @Test
    func theSameReactionSoundOverlapsItself() {
        let renderer = withReactions([("generic", [0.2]), ("clap", [0.2, 0.4, 0.6])])
        renderer.playReaction("clap")
        #expect(matches(render(renderer, frames: 1), [0.1]))
        renderer.playReaction("clap")
        // The first carries on where it was; the second starts from its beginning beside it.
        #expect(matches(render(renderer, frames: 3), [0.3, 0.5, 0.3]))
    }
    
    @Test
    func anUnknownNamePlaysTheGenericSound() {
        let renderer = withReactions([("generic", [0.6]), ("clap", [0.2])])
        renderer.playReaction("kazoo")
        #expect(matches(render(renderer, frames: 2), [0.3, 0]))
    }
    
    /// Eight at once, and a ninth plays nothing rather than cutting one short.
    @Test
    func aNinthReactionSoundIsDropped() {
        let renderer = withReactions([("generic", [0.01, 0.01])])
        for _ in 0..<9 {
            renderer.playReaction("generic")
        }
        let eight = Float(CallSoundEffectRenderer.reactionVoiceCount) * 0.005
        #expect(matches(render(renderer, frames: 2), [eight, eight]))
    }
    
    @Test
    func reactionsNeverTakeTheJoinSoundsPlace() {
        let renderer = withReactions([("generic", [0.01, 0.01])])
        for _ in 0..<CallSoundEffectRenderer.reactionVoiceCount {
            renderer.playReaction("generic")
        }
        renderer.play(.join)
        #expect(matches(render(renderer, frames: 2), [0.14, 0.14]))
    }
    
    /// Eight copies of a loud sound would be four times full scale: the limiter, not the clamp, holds
    /// them, so no sample is flattened at the rail.
    @Test
    func eightLoudReactionsDoNotDistort() {
        let renderer = withReactions([("generic", [0.9, -0.9, 0.5])])
        for _ in 0..<CallSoundEffectRenderer.reactionVoiceCount {
            renderer.playReaction("generic")
        }
        let output = render(renderer, frames: 3)
        #expect(output.allSatisfy { abs($0) <= CallSoundEffectRenderer.limiterCeiling + 1e-6 })
        #expect(output[0] > output[2])
    }
    
    @Test
    func theRaisedHandHasAVoiceOfItsOwn() {
        let renderer = CallSoundEffectRenderer(join: [0.2, 0.2], leave: [], raiseHand: [0.4, 0.4])
        renderer.play(.join)
        renderer.play(.raiseHand)
        #expect(matches(render(renderer, frames: 3), [0.3, 0.3, 0]))
    }
    
    @Test
    func aSecondHandWhileTheFirstPlaysJoinsIt() {
        // 009 R34: two hands close together are one sound, never one cut off and restarted.
        let renderer = CallSoundEffectRenderer(join: [], leave: [], raiseHand: [0.2, 0.4, 0.6])
        renderer.play(.raiseHand)
        #expect(matches(render(renderer, frames: 1), [0.1]))
        renderer.play(.raiseHand)
        #expect(matches(render(renderer, frames: 3), [0.2, 0.3, 0]))
        // Once it has finished, the next hand plays it again.
        renderer.play(.raiseHand)
        #expect(matches(render(renderer, frames: 1), [0.1]))
    }
    
    @Test
    func bundledRendererCanLoadFromABackgroundTask() async throws {
        let renderer = try #require(await Task.detached { await CallSoundEffectRenderer.bundled() }.value)
        renderer.play(.join)
        #expect(render(renderer, frames: 48000).contains { $0 != 0 })
    }
    
    /// Back to back while the other phone rings, and cut off mid-tone when it stops (030 R23).
    @Test
    func theRingbackLoopsUntilStopped() {
        let renderer = CallSoundEffectRenderer(join: [], leave: [], raiseHand: [], ringback: [0.2, 0.4])
        renderer.play(.ringback)
        #expect(matches(render(renderer, frames: 5), [0.1, 0.2, 0.1, 0.2, 0.1]))
        renderer.stop(.ringback)
        #expect(matches(render(renderer, frames: 2), [0, 0]))
    }
    
    /// Between two renders only the last request counts, whichever order they came in.
    @Test
    func theLastOfAPlayAndAStopWins() {
        let renderer = CallSoundEffectRenderer(join: [], leave: [], raiseHand: [], ringback: [0.2, 0.4])
        renderer.play(.ringback)
        renderer.stop(.ringback)
        #expect(matches(render(renderer, frames: 2), [0, 0]))
        renderer.stop(.ringback)
        renderer.play(.ringback)
        #expect(matches(render(renderer, frames: 2), [0.1, 0.2]))
    }
    
    @Test
    func anEndSoundPlaysOnceAndSaysHowLongItLasts() {
        let renderer = CallSoundEffectRenderer(join: [], leave: [], raiseHand: [], declined: [0.2, 0.4], timeout: .init(repeating: 0, count: 48000))
        renderer.play(.declined)
        #expect(matches(render(renderer, frames: 3), [0.1, 0.2, 0]))
        #expect(renderer.duration(of: .timeout) == .seconds(1))
    }
    
    /// The files have to be in the bundle and decodable, or the first anyone hears of it is a silent
    /// call on a device.
    @MainActor
    @Test(arguments: [("join_call", 44928), ("left_call", 44928), ("ringtone", 57600), ("call_declined", 54144), ("call_timeout", 54144)])
    func theBundledSoundsDecode(resource: String, frames: Int) throws {
        let samples = try CallSoundEffectRenderer.decode(resource: resource)
        // Web's files at 48 kHz: 0.936 s, 1.2 s and 1.128 s. The decoder's priming trim may shave
        // a frame or two.
        #expect(abs(samples.count - frames) < 2048)
        #expect(samples.contains { $0 != 0 })
        #expect(samples.allSatisfy { abs($0) <= 1 })
    }
    
    /// Every sound the core can name is in the bundle and decodes, or that reaction would be silent.
    @Test
    @MainActor
    func theReactionSoundsDecode() throws {
        #expect(CallSoundEffectRenderer.reactionSoundNames.count == 12)
        for name in CallSoundEffectRenderer.reactionSoundNames {
            let samples = try CallSoundEffectRenderer.decode(resource: name, subdirectory: "Sounds/reactions")
            #expect(samples.count > 4800, "\(name)")
            #expect(samples.contains { $0 != 0 }, "\(name)")
        }
    }
    
    /// Web's file is 24 kHz and 0.648 s; at the engine's 48 kHz that is about 31,100 frames. Left at
    /// its own rate it would play an octave up in half the time.
    @Test
    @MainActor
    func theRaisedHandIsResampledToTheEnginesRate() throws {
        let samples = try CallSoundEffectRenderer.decode(resource: "raise_hand")
        #expect(abs(samples.count - 31104) < 2048)
        #expect(samples.contains { $0 != 0 })
        #expect(samples.allSatisfy { abs($0) <= 1 })
    }
}
