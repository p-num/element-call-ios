//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import Foundation

/// The `reactions` fixture's loop (`harness/fixtures.md`): reactions arriving as the core would
/// announce them, on a call whose session is scripted, so they take the real path to the screen
/// and to the speaker (spec 037).
///
/// `-reactionInterval <seconds>` replaces the loop with a steady stream at that pace, from each
/// person in turn, for tuning the motion or for a stress run (`0.05` fills the screen's thirty).
struct ElementCallExampleReactions {
    static let localMemberID = "@alice:example.com:DEVICE"
    /// The long name is the point of the last one: it has to be shortened in the middle (037 R4).
    static let people = ["Carol", "Bob", "Dan", "Wolfeschlegelsteinhausenbergerdorff"]
    
    static let scenario = "0s me v\n0s " + people.map { $0.uppercased() + ($0 == "Dan" ? "" : "v") }.joined(separator: " ")
    
    /// Web's catalogue, in its order, bell included.
    static let catalogue = [("thumbsup", "👍"), ("party", "🎉"), ("clapping", "👏"), ("dog", "🐶"), ("cat", "🐱"),
                            ("lightbulb", "💡"), ("crickets", "🦗"), ("thumbsdown", "👎"), ("dizzy", "😵‍💫"), ("ok", "👌"),
                            ("heart", "🥰"), ("laugh", "😄"), ("deer", "🦌"), ("rock", "🤘"), ("wave", "👋"),
                            ("drum", "🥁"), ("bell", "🛎️")]
    
    static let loopLength: Duration = .seconds(22)
    
    struct Arrival {
        let at: Duration
        let memberID: String
        let name: String
        let emoji: String
    }
    
    static func memberID(_ name: String) -> String {
        "@\(name.uppercased()):example.com:DEVICE"
    }
    
    /// One loop: one a second for fifteen seconds, everyone in turn, ourselves included; a quiet
    /// gap so everyone is past the core's three seconds; then four claps at the same instant.
    static func loop(startingAt catalogueIndex: Int) -> [Arrival] {
        let senders = people.map(memberID) + [localMemberID]
        var reactions = (0..<15).map { second in
            let (name, emoji) = catalogue[(catalogueIndex + second) % catalogue.count]
            return Arrival(at: .seconds(second), memberID: senders[second % senders.count], name: name, emoji: emoji)
        }
        reactions += people.map { Arrival(at: .seconds(18), memberID: memberID($0), name: "clapping", emoji: "👏") }
        return reactions
    }
    
    static var interval: Duration? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-reactionInterval"),
              arguments.indices.contains(index + 1),
              let seconds = Double(arguments[index + 1]), seconds > 0 else { return nil }
        return .seconds(seconds)
    }
    
    /// Plays until the call is hung up. The call's own timers, the spread and the four seconds, run
    /// on the scenario's manual clock, so it is moved with the wall clock in small steps: in quarter
    /// seconds, as the outages move it, every spread would land on one of four moments.
    @MainActor
    func play(tiles playback: ElementCallExampleScenarioPlayback) async {
        await playback.step()
        await playback.step()
        var elapsed = Duration.zero
        var next = 0
        var loopStart = Duration.zero
        var pending = Self.interval == nil ? Self.loop(startingAt: 0) : []
        let senders = Self.people.map(Self.memberID) + [Self.localMemberID]
        while !Task.isCancelled {
            if let interval = Self.interval {
                let (name, emoji) = Self.catalogue[next % Self.catalogue.count]
                push(name: name, emoji: emoji, from: senders[next % senders.count], on: playback)
                next += 1
                await advance(by: interval, from: &elapsed, playback: playback)
                continue
            }
            for reaction in pending {
                await advance(by: loopStart + reaction.at - elapsed, from: &elapsed, playback: playback)
                guard !Task.isCancelled else { return }
                push(name: reaction.name, emoji: reaction.emoji, from: reaction.memberID, on: playback)
            }
            loopStart += Self.loopLength
            next += 15
            pending = Self.loop(startingAt: next)
            await advance(by: loopStart - elapsed, from: &elapsed, playback: playback)
        }
    }
    
    @MainActor
    private func push(name: String, emoji: String, from memberID: String, on playback: ElementCallExampleScenarioPlayback) {
        playback.player.session.push(event: .reaction(memberId: memberID, emoji: emoji, name: name, sound: reactionSoundFor(name: name)))
        playback.timeline = (0, 0, "\(emoji) \(name) from \(memberID.dropFirst().prefix { $0 != ":" }.capitalized)")
    }
    
    @MainActor
    private func advance(by duration: Duration, from elapsed: inout Duration, playback: ElementCallExampleScenarioPlayback) async {
        let target = elapsed + max(duration, .zero)
        while elapsed < target, !Task.isCancelled {
            let tick = min(target - elapsed, .milliseconds(20))
            try? await Task.sleep(for: tick)
            elapsed += tick
            playback.player.clock.advance(to: elapsed)
        }
    }
}
