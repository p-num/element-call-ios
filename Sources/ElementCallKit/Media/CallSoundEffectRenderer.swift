//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import MatrixRtc
import Synchronization

/// A short cue mixed over the call, as opposed to the call's own audio.
nonisolated enum CallSoundEffect: CaseIterable, Sendable {
    case join, leave, raiseHand
    /// What the caller hears while the other phone rings, looped until stopped (030 R23).
    case ringback
    /// A direct call ending because the callee declined, or because nobody answered (030 R25).
    case declined, timeout
}

/// The call's sound effects' render path: one source node on the call's own engine, so they go
/// wherever the call's audio goes, at the call's volume, mixed over the voices rather than
/// interrupting them. A separate player would have its own route and volume and follow the ringer
/// switch, which is what spec 024 rules out (R10, R14, R15, R16).
///
/// Built like ``AudioPlaybackRenderer``: it owns its render block, cannot reach the engine, and
/// renders without one in tests. One voice per effect, so a join and a leave close together overlap
/// instead of cutting each other off.
///
/// Reactions are not effects: there is a sound per reaction name rather than one per case, and the
/// same one may overlap itself, so they get a pool of voices of their own (037 R10).
final nonisolated class CallSoundEffectRenderer: @unchecked Sendable {
    /// Web's default effect volume, relative to the call (024 R14), and where the user's sound
    /// effects volume starts (037 R22).
    static let gain: Float = 0.5
    /// At most this many reaction sounds at once, whichever they are. Separate from the effects'
    /// voices, so a room full of applause never silences a join (037 R10).
    static let reactionVoiceCount = 8
    /// Where the limiter holds the mix's peaks: under full scale, so the clamp after it never has
    /// anything to cut (037 R10).
    static let limiterCeiling: Float = 0.95
    /// How long the limiter takes to let the level back up after a peak: short enough that a quiet
    /// sound after a burst is not left ducked, long enough not to pump on every wave of a roar.
    static let limiterRelease = 0.1
    
    private let join: Voice
    private let leave: Voice
    private let raiseHand: Voice
    private let ringback: Voice
    private let declined: Voice
    private let timeout: Voice
    
    /// Decoded only for a call that plays reactions, and installed once (``installReactionSounds(_:)``).
    private let reactionSounds = AtomicLazyReference<ReactionSounds>()
    private let reactionRequests = RequestRing()
    /// The user's sound effects volume, as a `Float`'s bits: there is no atomic `Float`.
    private let effectsGain = Atomic<UInt32>(CallSoundEffectRenderer.gain.bitPattern)
    // Render thread only.
    private let reactionVoices: UnsafeMutableBufferPointer<ReactionVoice>
    private var limiterGain: Float = 1
    
    init(join: [Float], leave: [Float], raiseHand: [Float], ringback: [Float] = [], declined: [Float] = [], timeout: [Float] = []) {
        self.join = Voice(join)
        self.leave = Voice(leave)
        // Two hands close together are one sound, not a sound cut off and started again (009 R34).
        self.raiseHand = Voice(raiseHand, coalesces: true)
        // Back to back, as web plays it (030 R23).
        self.ringback = Voice(ringback, loops: true)
        self.declined = Voice(declined)
        self.timeout = Voice(timeout)
        reactionVoices = .allocate(capacity: Self.reactionVoiceCount)
        reactionVoices.initialize(repeating: ReactionVoice())
    }
    
    deinit {
        reactionVoices.deallocate()
    }
    
    /// From any thread. Restarts that sound from its beginning on the next render.
    func play(_ sound: CallSoundEffect) {
        voice(for: sound).trigger()
    }
    
    /// From any thread. Silences that sound on the next render, mid-way if need be (030 R23).
    func stop(_ sound: CallSoundEffect) {
        voice(for: sound).stop()
    }
    
    /// How long one play of the sound lasts, at the engine's rate.
    func duration(of sound: CallSoundEffect) -> Duration {
        .seconds(Double(voice(for: sound).length) / AudioFormat.float32.sampleRate)
    }
    
    /// From any thread. How loud every effect plays, 0 to 1 of the call's own level, taking effect on
    /// the next render, sounds already playing included (037 R22). Not the ringback, which is the
    /// call still ringing rather than an effect (037 R23).
    func setEffectsGain(_ gain: Float) {
        effectsGain.store(min(max(gain, 0), 1).bitPattern, ordering: .relaxed)
    }
    
    /// Hands over the reaction sounds; only the first call counts. Until then a reaction plays nothing,
    /// as an effect plays nothing before the effects are decoded.
    func installReactionSounds(_ sounds: ReactionSounds) {
        _ = reactionSounds.storeIfNil(sounds)
    }
    
    var hasReactionSounds: Bool {
        reactionSounds.load() != nil
    }
    
    /// From one thread at a time. Plays `sound` on top of whatever is playing, itself included, if a
    /// voice is free when it reaches the render thread; otherwise nothing plays, rather than a playing
    /// sound being cut short for it (037 R10). A name with no file plays the generic sound.
    func playReaction(_ sound: String) {
        guard let sounds = reactionSounds.load() else { return }
        _ = reactionRequests.push(sounds.index(of: sound))
    }
    
    /// The block handed to the engine. It captures the renderer and nothing else.
    var renderBlock: AVAudioSourceNodeRenderBlock {
        { [self] _, _, frameCount, audioBufferList in
            render(frameCount: frameCount, audioBufferList: audioBufferList)
        }
    }
    
    /// Runs on the real-time thread: no allocation, no locks, no engine.
    func render(frameCount: AVAudioFrameCount, audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard let first = buffers.first, let data = first.mData else { return noErr }
        let output = data.assumingMemoryBound(to: Float.self)
        let count = Int(frameCount)
        for index in 0..<count {
            output[index] = 0
        }
        let gain = Float(bitPattern: effectsGain.load(ordering: .relaxed))
        join.mix(into: output, count: count, gain: gain)
        leave.mix(into: output, count: count, gain: gain)
        raiseHand.mix(into: output, count: count, gain: gain)
        ringback.mix(into: output, count: count, gain: Self.gain)
        declined.mix(into: output, count: count, gain: gain)
        timeout.mix(into: output, count: count, gain: gain)
        mixReactions(into: output, count: count, gain: gain)
        limit(output, count: count)
        for index in 0..<count {
            output[index] = min(1, max(-1, output[index]))
        }
        return noErr
    }
    
    private func mixReactions(into output: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        guard let sounds = reactionSounds.load() else { return }
        reactionRequests.drain { sound in
            for slot in 0..<Self.reactionVoiceCount where reactionVoices[slot].sound < 0 {
                reactionVoices[slot] = ReactionVoice(sound: Int(sound), playhead: 0)
                return
            }
        }
        for slot in 0..<Self.reactionVoiceCount where reactionVoices[slot].sound >= 0 {
            let samples = sounds.samples[reactionVoices[slot].sound]
            let playhead = reactionVoices[slot].playhead
            let available = min(count, samples.count - playhead)
            for index in 0..<available {
                output[index] += samples[playhead + index] * gain
            }
            reactionVoices[slot].playhead += available
            if reactionVoices[slot].playhead >= samples.count {
                reactionVoices[slot] = ReactionVoice()
            }
        }
    }
    
    /// Brings a mix that went over the ceiling back under it, at once, and lets it back up over
    /// ``limiterRelease``. Below the ceiling it leaves the mix exactly as it was. The clamp that
    /// follows used to be all there was, and eight overlapping claps at half level are far past it:
    /// clamped, they crackle (037 R10).
    private func limit(_ output: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(output[index]))
        }
        let target = peak > Self.limiterCeiling ? Self.limiterCeiling / peak : 1
        let start = limiterGain
        if target <= start {
            // Down at once, for the whole buffer, so not one sample of it is over.
            limiterGain = target
            guard target < 1 else { return }
            for index in 0..<count {
                output[index] *= target
            }
            return
        }
        // Back up gradually, never past this buffer's own target.
        let step = Float(1 - exp(-Double(count) / (Self.limiterRelease * AudioFormat.float32.sampleRate)))
        let end = start + (target - start) * step
        limiterGain = end
        guard start < 1 else { return }
        for index in 0..<count {
            output[index] *= start + (end - start) * Float(index + 1) / Float(count)
        }
    }
    
    private func voice(for sound: CallSoundEffect) -> Voice {
        switch sound {
        case .join: join
        case .leave: leave
        case .raiseHand: raiseHand
        case .ringback: ringback
        case .declined: declined
        case .timeout: timeout
        }
    }
    
    /// One sound. A play or a stop crosses threads as a generation count, with whether the sound
    /// is wanted beside it; the playhead belongs to the render thread alone, which notices a new
    /// generation and starts over, or falls silent. A coalescing voice instead lets a trigger that
    /// arrives while it plays join the sound already playing: its cooldown is the sound's own
    /// length, read where the playhead is rather than on a clock. A looping voice starts over at
    /// its end for as long as it is wanted.
    private final class Voice: @unchecked Sendable {
        private let samples: UnsafeMutableBufferPointer<Float>
        private let coalesces: Bool
        private let loops: Bool
        private let requested = Atomic<UInt32>(0)
        private let isWanted = Atomic<Bool>(false)
        // Render thread only.
        private var started: UInt32 = 0
        private var isPlaying = false
        private var playhead: Int
        
        var length: Int {
            samples.count
        }
        
        init(_ source: [Float], coalesces: Bool = false, loops: Bool = false) {
            self.coalesces = coalesces
            self.loops = loops
            samples = .allocate(capacity: source.count)
            _ = samples.initialize(from: source)
            // At the end: silent until first triggered.
            playhead = source.count
        }
        
        deinit {
            samples.deallocate()
        }
        
        /// The flag is written before the generation is published, so a render that sees the
        /// generation sees the flag that came with it, and a play and a stop between two renders
        /// leave whichever was last.
        func trigger() {
            isWanted.store(true, ordering: .relaxed)
            requested.wrappingAdd(1, ordering: .releasing)
        }
        
        func stop() {
            isWanted.store(false, ordering: .relaxed)
            requested.wrappingAdd(1, ordering: .releasing)
        }
        
        func mix(into output: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
            let generation = requested.load(ordering: .acquiring)
            if generation != started {
                started = generation
                isPlaying = isWanted.load(ordering: .relaxed)
                if !isPlaying {
                    playhead = samples.count
                } else if !coalesces || playhead >= samples.count {
                    playhead = 0
                }
            }
            var written = 0
            while written < count {
                if playhead >= samples.count {
                    guard loops, isPlaying, !samples.isEmpty else { return }
                    playhead = 0
                }
                let available = min(count - written, samples.count - playhead)
                for index in 0..<available {
                    output[written + index] += samples[playhead + index] * gain
                }
                playhead += available
                written += available
            }
        }
    }
}

// MARK: - Reactions

nonisolated extension CallSoundEffectRenderer {
    /// The reaction sounds, decoded, by name.
    final class ReactionSounds: @unchecked Sendable {
        private let names: [String: Int32]
        /// Read on the render thread, so a buffer of buffers rather than an array: no retain there.
        let samples: UnsafeMutableBufferPointer<UnsafeMutableBufferPointer<Float>>
        
        /// The first sound is what a name without one of its own plays.
        init(_ sounds: [(name: String, samples: [Float])]) {
            precondition(!sounds.isEmpty, "Reactions need at least the generic sound")
            names = Dictionary(sounds.enumerated().map { ($1.name, Int32($0)) }, uniquingKeysWith: { first, _ in first })
            samples = .allocate(capacity: sounds.count)
            for (index, sound) in sounds.enumerated() {
                let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: sound.samples.count)
                _ = buffer.initialize(from: sound.samples)
                samples[index] = buffer
            }
        }
        
        deinit {
            samples.forEach { $0.deallocate() }
            samples.deallocate()
        }
        
        func index(of name: String) -> Int32 {
            names[name] ?? 0
        }
    }
    
    /// One playing reaction sound: an index into the sounds, or none.
    private struct ReactionVoice {
        var sound = -1
        var playhead = 0
    }
    
    /// Requests for the render thread, from a single other thread: a fixed ring with one atomic index
    /// per side, so neither side ever allocates or waits. A request that finds it full is dropped,
    /// which is what a pool with no free voice would have done with it anyway.
    private final class RequestRing: @unchecked Sendable {
        private static let capacity = 16
        private let slots = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
        private let head = Atomic<Int>(0)
        private let tail = Atomic<Int>(0)
        
        deinit {
            slots.deallocate()
        }
        
        func push(_ value: Int32) -> Bool {
            let tail = tail.load(ordering: .relaxed)
            guard tail - head.load(ordering: .acquiring) < Self.capacity else { return false }
            slots[tail % Self.capacity] = value
            self.tail.store(tail + 1, ordering: .releasing)
            return true
        }
        
        func drain(_ body: (Int32) -> Void) {
            let head = head.load(ordering: .relaxed)
            let tail = tail.load(ordering: .acquiring)
            guard head != tail else { return }
            for index in head..<tail {
                body(slots[index % Self.capacity])
            }
            self.head.store(tail, ordering: .releasing)
        }
    }
    
    /// Every sound a received reaction can name: the catalogue's, and what plays for a name outside it.
    static let reactionSoundNames = Set(reactionCatalog().map(\.sound) + [reactionSoundFor(name: "")]).sorted()
    
    /// Web's reaction files, decoded; about 4.6 MB, so per call rather than per process, and only for
    /// a call that plays them. Nil if any fails, which is logged: reactions still show.
    static func decodeReactionSounds() async -> ReactionSounds? {
        do {
            let urls = try await MainActor.run {
                try reactionSoundNames.map { name in
                    try (name, resourceURL(name, subdirectory: "Sounds/reactions"))
                }
            }
            return try ReactionSounds(urls.map { name, url in
                try (name, decode(url: url))
            })
        } catch {
            MatrixRTCLog.error("Failed to decode the reaction sounds: \(error)")
            return nil
        }
    }
}

// MARK: - The bundled sounds

nonisolated extension CallSoundEffectRenderer {
    /// A renderer over the bundled files, or nil if they could not be decoded, which is logged: a
    /// call without its join sound is still a call.
    static func bundled() async -> CallSoundEffectRenderer? {
        guard let samples = await bundledSamples.value else { return nil }
        return CallSoundEffectRenderer(join: samples.join, leave: samples.leave, raiseHand: samples.raiseHand,
                                       ringback: samples.ringback, declined: samples.declined, timeout: samples.timeout)
    }
    
    private struct BundledSamples: Sendable {
        let join, leave, raiseHand, ringback, declined, timeout: [Float]
    }
    
    /// Bundle lookup belongs to the main actor; file IO and decoding do not.
    private static let bundledSamples: Task<BundledSamples?, Never> = .detached(priority: .utility) {
        do {
            let urls = try await MainActor.run {
                try ["join_call", "left_call", "raise_hand", "ringtone", "call_declined", "call_timeout"].map { try resourceURL($0) }
            }
            return try BundledSamples(join: decode(url: urls[0]), leave: decode(url: urls[1]), raiseHand: decode(url: urls[2]),
                                      ringback: decode(url: urls[3]), declined: decode(url: urls[4]), timeout: decode(url: urls[5]))
        } catch {
            MatrixRTCLog.error("Failed to decode the call sounds: \(error)")
            return nil
        }
    }
    
    @MainActor
    static func decode(resource: String, subdirectory: String = "Sounds") throws -> [Float] {
        try decode(url: resourceURL(resource, subdirectory: subdirectory))
    }
    
    @MainActor
    private static func resourceURL(_ resource: String, subdirectory: String = "Sounds") throws -> URL {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "mp3", subdirectory: subdirectory) else {
            throw MatrixRTCError.media("\(resource).mp3 is not in the bundle")
        }
        return url
    }
    
    /// To the engine's mono Float32: the channels averaged, then resampled to the engine's 48 kHz if
    /// the file is at another rate. Web's own files, unchanged, are not all at one rate:
    /// `raise_hand` is 24 kHz.
    static func decode(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32 else {
            throw MatrixRTCError.media("\(url.lastPathComponent) is \(format), expected Float32")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MatrixRTCError.media("Could not allocate a buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw MatrixRTCError.media("\(url.lastPathComponent) decoded without channel data")
        }
        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        let stride = format.isInterleaved ? channelCount : 1
        let mono = (0..<frames).map { frame in
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += format.isInterleaved ? channels[0][frame * stride + channel] : channels[channel][frame]
            }
            return sum / Float(channelCount)
        }
        guard format.sampleRate != AudioFormat.float32.sampleRate else { return mono }
        return try resample(mono, from: format.sampleRate, name: url.lastPathComponent)
    }
    
    /// Once per file per process, so the converter's quality matters more than its speed.
    static func resample(_ samples: [Float], from sampleRate: Double, name: String) throws -> [Float] {
        let target = AudioFormat.float32.sampleRate
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let destination = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: destination),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
              let inputData = input.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: destination,
                                            frameCapacity: AVAudioFrameCount((Double(samples.count) * target / sampleRate).rounded(.up)) + 1024) else {
            throw MatrixRTCError.media("Could not set up resampling \(name) from \(sampleRate) Hz")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = input.frameCapacity
        for (index, sample) in samples.enumerated() {
            inputData[0][index] = sample
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData else {
            throw MatrixRTCError.media("Could not resample \(name): \(conversionError.map { "\($0)" } ?? "\(status)")")
        }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
