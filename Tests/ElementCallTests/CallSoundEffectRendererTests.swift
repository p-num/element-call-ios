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
    
    @Test
    func theMixIsClamped() {
        let renderer = CallSoundEffectRenderer(join: [2], leave: [2], raiseHand: [])
        renderer.play(.join)
        renderer.play(.leave)
        #expect(matches(render(renderer, frames: 1), [1]))
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
    
    /// The files have to be in the bundle and decodable, or the first anyone hears of it is a silent
    /// call on a device.
    @Test(arguments: ["join_call", "left_call"])
    func theBundledSoundsDecode(resource: String) throws {
        let samples = try CallSoundEffectRenderer.decode(resource: resource)
        // Web's files are 0.936 s at 48 kHz; the decoder's priming trim may shave a frame or two.
        #expect(abs(samples.count - 44928) < 2048)
        #expect(samples.contains { $0 != 0 })
        #expect(samples.allSatisfy { abs($0) <= 1 })
    }
    
    /// Web's file is 24 kHz and 0.648 s; at the engine's 48 kHz that is about 31,100 frames. Left at
    /// its own rate it would play an octave up in half the time.
    @Test
    func theRaisedHandIsResampledToTheEnginesRate() throws {
        let samples = try CallSoundEffectRenderer.decode(resource: "raise_hand")
        #expect(abs(samples.count - 31104) < 2048)
        #expect(samples.contains { $0 != 0 })
        #expect(samples.allSatisfy { abs($0) <= 1 })
    }
}
