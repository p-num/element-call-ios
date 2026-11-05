//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation

/// A call's audio from the join to its end: the one engine every voice and sound of the call plays
/// through, and the sound effects on it.
///
/// The call's rather than its media's, because a call has sounds before it has media: the core rings
/// the callee right after the join, and the ringback plays from then, on the call's own output
/// (spec 030 R23, R24; 024 R10). The media session borrows the engine when it connects and gives
/// back what it added when it disconnects.
final class CallAudio {
    let engine = CallAudioEngine()
    /// Arrives once the bundled files are decoded, off this actor; until then nothing plays.
    private var soundEffects: CallSoundEffectRenderer?
    private var isRingbackWanted = false
    private var installation: Task<Void, Never>?
    /// Wanted once the call plays reaction sounds, and kept for the rest of the call after that.
    private var reactionSounds: CallSoundEffectRenderer.ReactionSounds?
    private var reactionDecoding: Task<Void, Never>?
    /// Kept, so sounds decoded after it was set still play at it.
    private var effectsGain = CallSoundEffectRenderer.gain
    
    /// The bundled sounds, decoded off this actor, unless a test hands over sounds of known length.
    init(soundEffects: CallSoundEffectRenderer? = nil) {
        if let soundEffects {
            install(soundEffects)
        } else {
            installation = Task { [weak self] in await self?.installSoundEffects() }
        }
    }
    
    /// Once the audio session is active; before, the engine has no output to start on.
    func start() {
        engine.start()
    }
    
    func stop() {
        engine.stop()
    }
    
    func play(_ sound: CallSoundEffect) {
        soundEffects?.play(sound)
    }
    
    /// Decodes the reaction sounds, off this actor, the first time a call wants them. They are
    /// several megabytes, so a call with reaction sounds off never decodes them.
    func prepareReactionSounds() {
        guard reactionSounds == nil, reactionDecoding == nil else { return }
        reactionDecoding = Task { [weak self] in
            let sounds = await Task.detached(priority: .utility) { await CallSoundEffectRenderer.decodeReactionSounds() }.value
            guard let self, let sounds, !Task.isCancelled else { return }
            reactionSounds = sounds
            soundEffects?.installReactionSounds(sounds)
        }
    }
    
    /// The user's sound effects volume, 0 to 1 of the call's level (037 R22).
    func setEffectsGain(_ gain: Float) {
        effectsGain = gain
        soundEffects?.setEffectsGain(gain)
    }
    
    /// Nothing until ``prepareReactionSounds()`` has finished.
    func playReaction(_ sound: String) {
        soundEffects?.playReaction(sound)
    }
    
    /// Kept as wanted rather than played, so a ring that goes out before the sounds are decoded is
    /// still heard once they are.
    func setRingback(_ isPlaying: Bool) {
        guard isPlaying != isRingbackWanted else { return }
        isRingbackWanted = isPlaying
        applyRingback()
    }
    
    /// Nil before the sounds are decoded, which is also when playing one does nothing.
    func duration(of sound: CallSoundEffect) -> Duration? {
        soundEffects?.duration(of: sound)
    }
    
    /// The end of the call's audio, and of its engine.
    func shutdown() {
        installation?.cancel()
        reactionDecoding?.cancel()
        soundEffects?.stop(.ringback)
        engine.shutdown()
    }
    
    private func installSoundEffects() async {
        let renderer = await CallSoundEffectRenderer.bundled()
        guard let renderer, !Task.isCancelled else { return }
        install(renderer)
    }
    
    private func install(_ renderer: CallSoundEffectRenderer) {
        soundEffects = renderer
        renderer.setEffectsGain(effectsGain)
        if let reactionSounds {
            renderer.installReactionSounds(reactionSounds)
        }
        engine.setSoundEffectSource(render: renderer.renderBlock)
        applyRingback()
    }
    
    private func applyRingback() {
        if isRingbackWanted {
            soundEffects?.play(.ringback)
        } else {
            soundEffects?.stop(.ringback)
        }
    }
}
