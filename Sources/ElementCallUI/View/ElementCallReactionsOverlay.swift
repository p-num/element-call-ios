//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import SwiftUI

/// Received reactions, rising over the call like bubbles in sparkling water (spec 037).
///
/// A sibling of the stage, never part of a tile: a reaction changes nothing a tile reads, so no tile
/// redraws and no video flashes when somebody claps (R5). It takes no touches and is invisible to
/// screen readers (R18).
///
/// It keeps its own bubbles rather than drawing the model's list: the model drops a reaction four
/// seconds after it arrived, while a bubble is drawn from when it appeared, so the two would not
/// agree on the last frames of a flight. Each bubble is added when its reaction is first seen and
/// removed when its flight ends.
struct ElementCallReactionsOverlay: View {
    let reactions: [ElementCallReactionBubble]
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flights = ElementCallReactionFlights()
    
    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: flights.bubbles.isEmpty)) { timeline in
                ZStack {
                    ForEach(flights.bubbles) { flight in
                        let elapsed = Duration.seconds(timeline.date.timeIntervalSince(flight.appeared))
                        ElementCallReactionBubbleView(bubble: flight.bubble,
                                                      frame: flight.motion.frame(at: elapsed, in: geometry.size))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Initially, every reaction already there is marked seen and not drawn: this view is gone
        // while the call is minimised, and what arrived then is not shown on the way back (R8).
        .onChange(of: reactions.map(\.id), initial: true) { previous, current in
            let launched = flights.receive(reactions, isInitial: previous == current && flights.isEmpty,
                                           reduceMotion: reduceMotion, at: .now)
            for flight in launched {
                Task {
                    try? await Task.sleep(for: flight.motion.lifetime)
                    flights.land(flight.id)
                }
            }
        }
    }
}

/// Which reactions rise, kept apart from the view so the rules can be tested without drawing.
struct ElementCallReactionFlights {
    /// At most this many on screen; one arriving past it is not shown, nor kept for later (R2a).
    static let maximumBubbles = 30
    
    struct Flight: Identifiable {
        let bubble: ElementCallReactionBubble
        let appeared: Date
        let motion: ElementCallReactionBubbleMotion
        
        var id: UInt64 {
            bubble.id
        }
    }
    
    private(set) var bubbles: [Flight] = []
    /// Every reaction already accounted for, drawn or not, so none is drawn late.
    private var seen: Set<UInt64> = []
    
    var isEmpty: Bool {
        bubbles.isEmpty && seen.isEmpty
    }
    
    /// Takes the model's current reactions and returns the flights it launched. `isInitial` marks the
    /// ones already there when the overlay appears as seen without drawing them: the overlay is gone
    /// while the call is minimised, and what arrived then is not shown on the way back (R8).
    mutating func receive(_ reactions: [ElementCallReactionBubble], isInitial: Bool, reduceMotion: Bool, at now: Date) -> [Flight] {
        // Once a reaction leaves the model it never comes back, so it need not be remembered.
        seen.formIntersection(reactions.map(\.id))
        var launched: [Flight] = []
        for bubble in reactions where !seen.contains(bubble.id) {
            seen.insert(bubble.id)
            // R6: with reduced motion nothing rises at all; the sound still plays.
            guard !isInitial, !reduceMotion, bubbles.count < Self.maximumBubbles else { continue }
            let flight = Flight(bubble: bubble, appeared: now,
                                motion: ElementCallReactionBubbleMotion(seed: bubble.id, spread: bubble.spread))
            bubbles.append(flight)
            launched.append(flight)
        }
        return launched
    }
    
    /// A flight is over: it leaves the screen, and its place under the cap.
    mutating func land(_ id: UInt64) {
        bubbles.removeAll { $0.id == id }
    }
}

/// One bubble: the emoji in a round, the sender's name beneath, placed and sized by its motion.
struct ElementCallReactionBubbleView: View {
    let bubble: ElementCallReactionBubble
    let frame: ElementCallReactionBubbleMotion.Frame
    
    @Environment(\.elementCallStyle) private var style
    @Environment(\.elementCallGlassEnabled) private var isGlassEnabled
    
    /// The design size, which the motion scales: the circle, the emoji in it, and how wide a name
    /// may be before it is shortened.
    static let diameter: CGFloat = 52
    static let maximumNameWidth: CGFloat = 96
    
    var body: some View {
        VStack(spacing: 4) {
            Text(bubble.emoji)
                .font(.system(size: Self.diameter * 0.56))
                .frame(width: Self.diameter, height: Self.diameter)
                .background { fallbackRound }
                .elementCallGlass(in: Circle(), fallback: .clear)
            Text(bubble.senderName)
                .font(style.theme.bodySMSemibold)
                .foregroundStyle(style.theme.textPrimary)
                // Shortened in the middle, never wrapped: the start and end of a name are what tell
                // two people apart (R4).
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(style.theme.bgCanvasDefault.opacity(0.8), in: Capsule())
                .frame(maxWidth: Self.maximumNameWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scaleEffect(frame.scale)
        .rotationEffect(frame.angle)
        .opacity(frame.opacity)
        .position(frame.center)
    }
    
    /// Glass flexes by itself as the bubble moves, which is what makes it read as a bubble; a flat
    /// fill holds still, so below iOS 26 the motion's wobble stands in for it. Nothing where there
    /// is glass, or iOS 26 would wobble twice.
    @ViewBuilder
    private var fallbackRound: some View {
        if #available(iOS 26, *), isGlassEnabled {
            EmptyView()
        } else {
            // The fill is close to the stage's own dark, so without the rim the round, and its
            // wobble, all but vanished and only the emoji was seen to move.
            Circle()
                .fill(style.theme.bgSubtleSecondary)
                .overlay(Circle().strokeBorder(style.theme.borderInteractiveSecondary, lineWidth: 1))
                .scaleEffect(x: frame.wobble.width, y: frame.wobble.height)
        }
    }
}

/// Where a bubble is, how big, how tilted and how visible, at any moment of its flight (R1, R1a, R2,
/// R3, R21). A pure function of its seed, so a preview or a test draws the same path every time.
///
/// Every distance is a fraction of the stage, so a landscape flight is the portrait one scaled down
/// rather than a different one; and the bubble itself is sized from the stage's height, which is
/// what makes it smaller in landscape (R21), where the same bubble crossed the screen in four of its
/// own heights and read as a hop rather than a rise.
nonisolated struct ElementCallReactionBubbleMotion: Sendable {
    struct Frame: Equatable {
        var center: CGPoint
        var scale: CGFloat
        var angle: Angle
        var opacity: Double
        /// How far the round is stretched across and up, each near 1 and out of step with the other.
        var wobble: CGSize
    }
    
    /// From appearing to gone: four seconds from the reaction's arrival, less what it waited (R1a).
    let lifetime: Duration
    /// Fully visible until three seconds from arrival, then fading (R1a).
    let visibleFor: Duration
    
    /// Where across the stage it rises, as a fraction of the width: clear of the edges (R2).
    let startX: CGFloat
    private let swayAmplitude: CGFloat
    private let swayFrequencies: (CGFloat, CGFloat)
    private let swayPhases: (CGFloat, CGFloat)
    private let wobbleFrequency: CGFloat
    private let wobblePhase: CGFloat
    
    /// Small at first, full size a third of the way up (R3).
    static let startScale: CGFloat = 0.55
    static let fullSizeAt: CGFloat = 1.0 / 3
    static let fadeIn: Duration = .milliseconds(150)
    /// The bubble's design size against the stage's height: about 52 pt on a portrait phone, and the
    /// lower bound in landscape.
    static let sizeForHeight: CGFloat = 0.065
    static let sizeRange: ClosedRange<CGFloat> = 0.6...1.1
    /// How far the round stretches either way as it wobbles, as a fraction of its size.
    static let wobbleAmplitude: CGFloat = 0.1
    
    init(seed: UInt64, spread: Duration = .zero) {
        let spread = min(max(spread, .zero), MatrixRTCMediaSession.maximumReactionSpread)
        lifetime = MatrixRTCReaction.lifetime - spread
        visibleFor = MatrixRTCReaction.visibleFor - spread
        var random = SplitMix64(seed: seed)
        startX = 0.1 + 0.8 * random.unit()
        swayAmplitude = 0.6 + 0.4 * random.unit()
        swayFrequencies = (0.55 + 0.3 * random.unit(), 1.3 + 0.6 * random.unit())
        swayPhases = (2 * .pi * random.unit(), 2 * .pi * random.unit())
        // Drawn last, so every earlier value of a seed stays what it was.
        wobbleFrequency = 0.9 + 0.4 * random.unit()
        wobblePhase = 2 * .pi * random.unit()
    }
    
    /// How far up it has come, 0 to 1: fastest at first, then slowing (R3).
    static func rise(at progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return 1 - (1 - progress) * (1 - progress)
    }
    
    /// The bubble's size for a stage of this height, relative to its design size (R21).
    static func size(in stage: CGSize) -> CGFloat {
        min(max(stage.height * sizeForHeight / ElementCallReactionBubbleView.diameter, sizeRange.lowerBound), sizeRange.upperBound)
    }
    
    func frame(at elapsed: Duration, in stage: CGSize) -> Frame {
        let seconds = CGFloat(elapsed / .seconds(1))
        let progress = seconds / CGFloat(lifetime / .seconds(1))
        let risen = Self.rise(at: progress)
        
        // Growing on the same ease, so it is full size by a third of the way up.
        let growth = Self.rise(at: risen / Self.fullSizeAt)
        let size = Self.size(in: stage)
        let scale = size * (Self.startScale + (1 - Self.startScale) * growth)
        
        // From just below the bottom edge, behind the controls, to just past the top.
        let height = ElementCallReactionBubbleView.diameter * 2 * size
        let y = stage.height + height / 2 - risen * (stage.height + height)
        
        // Two sines, the slower leading, swaying more as it rises, as a real bubble does once it has
        // speed; the tilt leans into the slower one's direction of travel.
        let amplitude = 0.03 * min(stage.width, stage.height) * swayAmplitude * (0.4 + 0.6 * risen)
        let first = 2 * .pi * swayFrequencies.0 * seconds + swayPhases.0
        let second = 2 * .pi * swayFrequencies.1 * seconds + swayPhases.1
        let x = startX * stage.width + amplitude * (0.7 * sin(first) + 0.3 * sin(second))
        let angle = Angle.degrees(5 * cos(first))
        
        let fadeIn = min(seconds / CGFloat(Self.fadeIn / .seconds(1)), 1)
        let visible = CGFloat(visibleFor / .seconds(1))
        let fadeOut = seconds <= visible ? 1 : max(0, 1 - (seconds - visible) / (CGFloat(lifetime / .seconds(1)) - visible))
        
        // Wider as it gets shorter and back, a quarter turn apart, so the round flexes rather than
        // pulses.
        let wobbleAngle = 2 * .pi * wobbleFrequency * seconds + wobblePhase
        let wobble = CGSize(width: 1 + Self.wobbleAmplitude * sin(wobbleAngle),
                            height: 1 + Self.wobbleAmplitude * sin(wobbleAngle + .pi / 2))
        
        return Frame(center: CGPoint(x: x, y: y), scale: scale, angle: angle,
                     opacity: Double(max(0, min(fadeIn, fadeOut))), wobble: wobble)
    }
}

/// A small seeded generator, so a bubble's path follows from its reaction's id alone.
private nonisolated struct SplitMix64 {
    private var state: UInt64
    
    init(seed: UInt64) {
        state = seed
    }
    
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    
    /// Uniform in 0..<1.
    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}

// MARK: - Previews

struct ElementCallReactionsOverlay_Previews: PreviewProvider, TestablePreview {
    static let bubbles = [
        ElementCallReactionBubble(id: 1, emoji: "👏", senderName: "Carol"),
        ElementCallReactionBubble(id: 2, emoji: "🎉", senderName: "Wolfeschlegelsteinhausenbergerdorff"),
        ElementCallReactionBubble(id: 3, emoji: "🐶", senderName: "You"),
        ElementCallReactionBubble(id: 4, emoji: "💡", senderName: "Bob")
    ]
    
    /// Each bubble frozen at a different moment of its flight, since the overlay's own are live.
    static func frozen(in size: CGSize) -> some View {
        ZStack {
            ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, bubble in
                ElementCallReactionBubbleView(bubble: bubble,
                                              frame: ElementCallReactionBubbleMotion(seed: bubble.id)
                                                  .frame(at: .milliseconds(300 + 800 * index), in: size))
            }
        }
        .frame(width: size.width, height: size.height)
    }
    
    static var previews: some View {
        GeometryReader { geometry in
            frozen(in: geometry.size)
        }
        // The call's own canvas, which the bubble's flat fill stands out from as it does from video.
        .background(ElementCallStyle.stock.theme.bgCanvasDefault)
        .environment(\.colorScheme, .dark)
        .previewDisplayName("Bubbles in flight")
    }
}
