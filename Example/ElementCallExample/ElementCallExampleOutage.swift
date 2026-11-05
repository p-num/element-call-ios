//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import Foundation

extension Duration {
    /// Whole seconds, for a timeline's label.
    var seconds: Int64 {
        components.seconds
    }
}

/// An outage fixture's timeline (`harness/fixtures.md`, "Outages"): the interruptions record the
/// core would publish, moment by moment, on a group call whose tiles follow it.
///
/// What it scripts is the core's *output*, the record and the tiles, not the outage itself: the
/// core does not run here, so its retries and recovery cannot (034 C16, open question H5). What it
/// shows is everything the UI does with that output: the indicator, the list, the tiles' avatar and
/// spinner, the disabled controls, and the failed screen when our media server runs out of time.
struct ElementCallExampleOutage {
    enum Step {
        case interruptions(MatrixRTCInterruptions)
        /// The core gives up on our media server and ends the call.
        case connectionLost(MatrixRTCConnectionLossReason)
    }
    
    let timeline: [(at: Duration, step: Step)]
    
    static let localMemberID = "@alice:example.com:DEVICE"
    static let people = ["Carol", "Bob", "Dan", "Erin", "Frank"]
    
    /// Everyone's camera on but Dan's, as in `video`, so a tile that loses its media visibly goes
    /// from a picture to an avatar.
    static let scenario = "0s me v\n0s " + people.map { $0.uppercased() + ($0 == "Dan" ? "" : "v") }.joined(separator: " ")
    
    /// As the scenario names them: a token's member ID keeps the case it is written in, and the
    /// scenario writes these in capitals so they are people rather than the corpus's single letters.
    static func memberID(_ name: String) -> String {
        "@\(name.uppercased()):example.com:DEVICE"
    }
    
    /// Plays the timeline from the moment the call is up. A hang-up cancels it.
    @MainActor
    func play(on scripted: MatrixRTCScriptedCall, tiles playback: ElementCallExampleScenarioPlayback) async {
        await playback.step()
        await playback.step()
        var elapsed = Duration.zero
        var last: String?
        for (index, (at, step)) in timeline.enumerated() {
            playback.timeline = (index, timeline.count, [last, "next at \(at.seconds) s"].compactMap(\.self).joined(separator: " · "))
            // The call's own timers run on the scenario's manual clock, which nothing else moves
            // here, so it is moved with the wall clock. Left at zero, Erin stayed within the key
            // grace for good and her late key never showed; moved only at each step, the grace
            // that ends between two steps ended at the second.
            while elapsed < at {
                let tick = min(at - elapsed, .milliseconds(250))
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled else { return }
                elapsed += tick
                playback.player.clock.advance(to: elapsed)
                await playback.player.settle()
            }
            switch step {
            case .interruptions(let record):
                playback.player.session.push(interruptions: record)
            case .connectionLost(let reason):
                scripted.report(.ended(.connectionClosed(reason: reason, message: "scripted")))
            }
            last = "\(at.seconds) s: \(Self.describe(step))"
            playback.timeline = (index + 1, timeline.count, last ?? "")
        }
    }
    
    /// What a step did, in the fixture table's words, for the scrubber.
    private static func describe(_ step: Step) -> String {
        guard case .interruptions(let record) = step else {
            if case .connectionLost(let reason) = step {
                return "connection lost (\(reason))"
            }
            return ""
        }
        func names(_ memberIDs: [String]) -> String {
            memberIDs.map { $0.dropFirst().prefix { $0 != ":" }.capitalized }.joined(separator: ", ")
        }
        var causes: [String] = []
        if !record.signalling.isReachable {
            causes.append("signalling unreachable")
        }
        if record.isOwnMembershipLapsed {
            causes.append("membership lapsed")
        }
        if record.ownMedia != .connected {
            causes.append("our media \(record.ownMedia == .connecting ? "connecting" : "reconnecting")")
        }
        if !record.membersReconnecting.isEmpty {
            causes.append("\(names(record.membersReconnecting)) reconnecting")
        }
        if !record.unableToDecrypt.isEmpty {
            causes.append("\(names(record.unableToDecrypt)) unable to decrypt")
        }
        return causes.isEmpty ? "nothing interrupted" : causes.joined(separator: ", ")
    }
    
    // MARK: - The fixtures
    
    private static let outage = MatrixRTCSignallingHealth.unreachable(since: .now)
    
    static let homeserver30s = ElementCallExampleOutage(timeline: [
        (.seconds(5), .interruptions(.init(signalling: outage))),
        (.seconds(35), .interruptions(.none))
    ])
    
    static let homeserverLapse = ElementCallExampleOutage(timeline: [
        (.seconds(5), .interruptions(.init(signalling: outage))),
        (.seconds(15), .interruptions(.init(signalling: outage, isOwnMembershipLapsed: true))),
        // Back, but the others still cannot see us until the republish lands.
        (.seconds(45), .interruptions(.init(isOwnMembershipLapsed: true))),
        (.seconds(48), .interruptions(.none))
    ])
    
    static let ownSFURecovers40s = ElementCallExampleOutage(timeline: [
        (.seconds(5), .interruptions(.init(ownMedia: .reconnecting))),
        (.seconds(45), .interruptions(.none))
    ])
    
    /// The core's budget is a minute; the fixture is about the end, not the wait, so it is short.
    static let ownSFUBudget = ElementCallExampleOutage(timeline: [
        (.seconds(5), .interruptions(.init(ownMedia: .reconnecting))),
        (.seconds(15), .connectionLost(.budget))
    ])
    
    static let peerSFU1m = ElementCallExampleOutage(timeline: [
        (.seconds(5), .interruptions(.init(membersReconnecting: [memberID("Carol"), memberID("Bob")]))),
        (.seconds(65), .interruptions(.none))
    ])
    
    static let keyUndeliveredThenDelivered = ElementCallExampleOutage(timeline: [
        (.seconds(5), .interruptions(.init(unableToDecrypt: [memberID("Erin")]))),
        (.seconds(12), .interruptions(.none))
    ])
    
    /// The last step only keeps the clock moving past the moment her keys count as missing: the
    /// call's timers run on the scenario's clock, which stops with the timeline.
    static let keyMissing = ElementCallExampleOutage(timeline: [
        (.seconds(5), .interruptions(.init(unableToDecrypt: [memberID("Erin")]))),
        (.seconds(60), .interruptions(.init(unableToDecrypt: [memberID("Erin")])))
    ])
}
