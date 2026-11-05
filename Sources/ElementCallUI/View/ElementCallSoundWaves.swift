//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import SwiftUI

/// The one other person in a one-to-one call speaking with their camera off: sound waves round their
/// avatar, and the speaking ring just outside it. A card has its ring on its edge; a picture filling
/// the screen has no edge to put one on.
///
/// The waves are Element Call web's three (`MediaView`'s sound waves), in points round our larger
/// avatar, set moving. While the person speaks, ripples leave the avatar's edge and grow to the
/// outermost wave, passing through the waves' colours from the inside out, then fade where they
/// stopped. A new one leaves each time the last reaches the innermost wave, so the three are on the
/// stage at once. Shown and hidden with speaking rather than following the voice's level, as on web.
/// With reduce motion the waves stand still, as web draws them.
struct ElementCallSoundWaves: View {
    @Environment(\.elementCallStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.elementCallSoundWavesRipple) private var isRippleEnabled
    let isSpeaking: Bool
    let avatarDiameter: CGFloat
    
    /// When the person started speaking, so the first ripple leaves the avatar at once rather than
    /// partway through a cycle that began before.
    @State private var speakingSince: Date?
    
    /// Web's spacing, from the avatar outward: the ring, then each wave one step further.
    static let ringGrowth: CGFloat = 12
    static let firstWaveGrowth: CGFloat = 20
    static let waveStep: CGFloat = 40
    static let ringWidth: CGFloat = 2
    /// The canvas kept clear round the ring, so it reads as a ring over the waves.
    static let ringGap: CGFloat = 4
    /// From the avatar's edge to the outermost wave.
    static let rippleGrowthDuration = 1.8
    /// Fading where it stopped.
    static let rippleFadeDuration = 0.5
    
    var body: some View {
        ZStack {
            if reduceMotion || !isRippleEnabled {
                stillWaves
            } else {
                ripples
            }
            ring
        }
        .opacity(isSpeaking ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: isSpeaking)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: isSpeaking, initial: true) { _, isSpeaking in
            // Kept when speaking stops: the paused timeline holds the ripples where they were while
            // the whole fades out.
            if isSpeaking {
                speakingSince = .now
            }
        }
    }
    
    // MARK: - Geometry
    
    private var waveCount: Int {
        style.theme.soundWaveFills.count
    }
    
    /// The diameter of the wave at `index`, innermost first.
    private func waveDiameter(_ index: Int) -> CGFloat {
        avatarDiameter + Self.firstWaveGrowth + CGFloat(index + 1) * Self.waveStep
    }
    
    // MARK: - Ripples
    
    /// The timeline is paused while nobody speaks, so a silent call redraws nothing.
    private var ripples: some View {
        let start = avatarDiameter
        let end = waveDiameter(waveCount - 1)
        // Growth is steady, so a ripple reaches the innermost wave after the same time every time,
        // and that is how often a new one leaves.
        let interval = Self.rippleGrowthDuration * Double((waveDiameter(0) - start) / (end - start))
        return TimelineView(.animation(paused: !isSpeaking)) { timeline in
            let age = speakingSince.map { timeline.date.timeIntervalSince($0) } ?? 0
            ZStack {
                ForEach(Self.liveRipples(age: age, interval: interval), id: \.self) { index in
                    ripple(age: age - Double(index) * interval, from: start, to: end)
                }
            }
        }
    }
    
    /// The ripples on the stage `age` seconds after speaking began, oldest first so the newer and
    /// smaller are drawn over them. Identified by when they left, so each keeps its view as it grows.
    static func liveRipples(age: Double, interval: Double) -> [Int] {
        guard age >= 0, interval > 0 else { return [] }
        let newest = Int((age / interval).rounded(.down))
        let lifetime = rippleGrowthDuration + rippleFadeDuration
        let oldest = max(0, Int(((age - lifetime) / interval).rounded(.up)))
        return oldest <= newest ? Array(oldest...newest) : []
    }
    
    private func ripple(age: Double, from start: CGFloat, to end: CGFloat) -> some View {
        let growth = min(1, age / Self.rippleGrowthDuration)
        let fade = max(0, (age - Self.rippleGrowthDuration) / Self.rippleFadeDuration)
        let diameter = start + (end - start) * CGFloat(growth)
        return Circle()
            .fill(fill(at: growth))
            .overlay(Circle().strokeBorder(style.theme.soundWaveEdge, lineWidth: 1))
            .frame(width: diameter, height: diameter)
            .opacity(1 - fade)
    }
    
    /// The waves' colours from the inside out, as a ripple grows from the first to the last.
    private func fill(at progress: Double) -> Color {
        let fills = style.theme.soundWaveFills
        guard fills.count > 1 else { return fills.first ?? .clear }
        let position = progress * Double(fills.count - 1)
        let lower = min(fills.count - 2, Int(position.rounded(.down)))
        return fills[lower].mix(with: fills[lower + 1], by: position - Double(lower))
    }
    
    // MARK: - Still
    
    /// Outermost drawn first, so each sits on the one beyond it.
    private var stillWaves: some View {
        let fills = style.theme.soundWaveFills
        return ZStack {
            ForEach(fills.indices.reversed(), id: \.self) { index in
                Circle()
                    .fill(fills[index])
                    .overlay(Circle().strokeBorder(style.theme.soundWaveEdge, lineWidth: 1))
                    .frame(width: waveDiameter(index), height: waveDiameter(index))
            }
        }
    }
    
    private var ring: some View {
        let diameter = avatarDiameter + Self.ringGrowth
        let size = CGSize(width: diameter, height: diameter)
        return ZStack {
            Circle()
                .fill(style.theme.bgCanvasDefault)
                .frame(width: diameter + 2 * Self.ringGap, height: diameter + 2 * Self.ringGap)
            ForEach(Array(style.theme.activeSpeakerBorder(in: size).enumerated()), id: \.offset) { _, layer in
                Circle()
                    .strokeBorder(layer, lineWidth: Self.ringWidth)
                    .frame(width: diameter, height: diameter)
            }
        }
    }
}
