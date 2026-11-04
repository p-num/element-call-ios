//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import Foundation

/// A ringing fixture's timeline (`harness/fixtures.md`, "Ringing"): the status a scripted call
/// reports, and the tiles a scripted media session shows beside it.
///
/// The scenario is stepped from here, at the status's moments, rather than played: playback caps
/// every wait at three seconds, so Bob's picture arrived three seconds before the pickup and the
/// ringback went on under it. A real pickup comes from one place, the core, with the tile a hop
/// behind the status, and so does this one.
struct ElementCallExampleRinging {
    enum Outcome {
        case pickUp, declined, unanswered
    }
    
    let isAudioCall: Bool
    let outcome: Outcome
    
    static let callee = "@bob:example.com"
    /// Alice, as in every fixture, and as the scripted call names us.
    static let localMemberID = "@alice:example.com:DEVICE"
    static let ringOut = Duration.milliseconds(500)
    static let outcomeAt = Duration.seconds(6)
    
    /// Our own tile from the start, camera on for a video call; Bob's from the pickup, with video
    /// for a video call. `BOB` rather than the corpus's single letters, which would be
    /// `@b:example.com` and not the callee.
    var scenario: String {
        var lines = [isAudioCall ? "0s" : "0s me v"]
        if outcome == .pickUp {
            lines.append("6s \(isAudioCall ? "BOB" : "BOBv")")
        }
        return lines.joined(separator: "\n")
    }
    
    /// Plays the status until the outcome. A hang-up before then ends the call through its own
    /// leave, and what is reported after that is never read.
    @MainActor
    func play(on scripted: MatrixRTCScriptedCall, tiles playback: ElementCallExampleScenarioPlayback) async {
        // Our own tile, at 0 s.
        await playback.step()
        try? await Task.sleep(for: Self.ringOut)
        guard !Task.isCancelled else { return }
        scripted.report(.calling(callee: Self.callee,
                                 ring: .ringing(sentAt: .now, lifetime: Self.outcomeAt - Self.ringOut),
                                 media: .connected(isDegraded: false)))
        try? await Task.sleep(for: Self.outcomeAt - Self.ringOut)
        guard !Task.isCancelled else { return }
        switch outcome {
        case .pickUp:
            scripted.report(.connected(since: .now, isDegraded: false))
            // Bob's tile, at 6 s.
            await playback.step()
        case .declined: scripted.report(.ended(.declined))
        case .unanswered: scripted.report(.ended(.unanswered))
        }
    }
}
