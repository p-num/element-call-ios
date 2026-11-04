//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import SwiftUI

/// Everything the harness can show, and the catalogue's rows.
///
/// **The list is shared with Android.** `element-call-feature-hq/harness/fixtures.md` is the source
/// of truth: the same key opens the same people in the same arrangement in Android's sample, so two
/// phones side by side show one call. A key, roster or flag that differs from that file is a review
/// finding, here or there. The raw values are that file's keys, snake_case as both launch commands
/// spell them.
///
/// The connected ones are shapes of the *layout* rather than features: what a test or a person
/// poking at it needs is a grid, a grid that scrolls under a spotlight, a one-to-one call, and a
/// screen share, because those are the arrangements a tile can be full screen *from*.
///
/// The connecting ones are the states the stage never reaches. No fixture can express them —
/// `ElementCallPreviewFixtures.connected(...)` only ever builds a connected call — so they come from
/// a real view model over a fake controller instead. That difference is not cosmetic: a view model
/// routes minimize and hang up through ``ElementCallController``, so those rows exercise the genuine
/// host contract while the connected rows can only report the tap. See ``ElementCallExampleHost``.
enum ElementCallExampleFixture: String, CaseIterable {
    case oneToOne = "one_to_one"
    case group
    case listenMode = "listen_mode"
    case screenShare = "screen_share"
    case shareOnLongGrid = "share_on_long_grid"
    case twoShares = "two_shares"
    case video
    case twoHundred = "two_hundred"
    case muted
    case minimizedVoice = "minimized_voice"
    case minimizedVideo = "minimized_video"
    case alone
    case oneToOneLandscape = "one_to_one_landscape"
    case smallThree = "small_three"
    case smallFour = "small_four"
    case smallFive = "small_five"
    case oneToOneSpeaking = "one_to_one_speaking"
    case joining
    case connectingMedia = "connecting_media"
    case failed
    case ended
    case ringingPickup = "ringing_pickup"
    case ringingVoicePickup = "ringing_voice_pickup"
    case ringingDeclined = "ringing_declined"
    case ringingUnanswered = "ringing_unanswered"
    
    /// `-fixture <key>` opens a fixture and `-scenario <name>` a scenario file, mirroring Android's
    /// `--es fixture` and `--es scenario` so one recipe reads the same on both.
    static let launchArgument = "-fixture"
    static let scenarioLaunchArgument = "-scenario"
    
    /// Named `Category` rather than `Section` so it does not collide with SwiftUI's `Section` at
    /// the catalogue's use site, where both would be in scope.
    enum Category: String, CaseIterable {
        case connected = "Connected"
        case connecting = "Connecting"
        case ringing = "Ringing"
    }
    
    var category: Category {
        switch self {
        case .joining, .connectingMedia, .failed, .ended: .connecting
        case .ringingPickup, .ringingVoicePickup, .ringingDeclined, .ringingUnanswered: .ringing
        default: .connected
        }
    }
    
    static func fixtures(in category: Category) -> [ElementCallExampleFixture] {
        allCases.filter { $0.category == category }
    }
    
    var title: String {
        switch self {
        case .oneToOne: "One to one"
        case .group: "Group"
        case .listenMode: "Listen mode"
        case .screenShare: "Screen share"
        case .shareOnLongGrid: "Sharer on a long grid"
        case .twoShares: "Two screen shares"
        case .video: "Moving video"
        case .twoHundred: "Two hundred"
        case .muted: "Everyone muted"
        case .minimizedVoice: "Minimized voice call"
        case .minimizedVideo: "Minimized video call"
        case .alone: "Alone"
        case .oneToOneLandscape: "One to one, landscape camera"
        case .smallThree: "Small call of three"
        case .smallFour: "Small call of four"
        case .smallFive: "Small call of five"
        case .oneToOneSpeaking: "One to one, speaking"
        case .ringingPickup: "Ringing, then picked up"
        case .ringingVoicePickup: "Ringing a voice call, then picked up"
        case .ringingDeclined: "Ringing, then declined"
        case .ringingUnanswered: "Ringing, unanswered"
        case .joining: "Joining"
        case .connectingMedia: "Connecting media"
        case .failed: "Failed"
        case .ended: "Ended"
        }
    }
    
    /// What this row is *for*. The knowledge was already in the comments on each case below; a
    /// catalogue is where it stops being invisible to anyone who is not reading this file.
    var detail: String {
        switch self {
        case .oneToOne: "A direct call, our camera on, so the tile draws its flip button."
        case .group: "Eight people, nobody a hero: a grid, no spotlight."
        case .listenMode: "Twenty-four people: listen mode spotlights the speaker over a grid that scrolls."
        case .screenShare: "A remote share holding the spotlight, the sharer's camera in the grid."
        case .shareOnLongGrid: "A sharer's camera scrolls away from their screen."
        case .twoShares: "Two heroes stacked in the spotlight; swipe it sideways to switch."
        case .video: "Real frames, some portrait and some landscape."
        case .twoHundred: "Two hundred people, most with a camera: what a scroll costs at scale."
        case .muted: "A direct call with every microphone off."
        case .minimizedVoice: "A direct voice call, opened minimized to the bar."
        case .minimizedVideo: "A direct video call, opened minimized to the bar."
        case .alone: "Only us, our own tile floating in its corner."
        case .oneToOneLandscape: "Carol sends landscape: shown whole on a portrait stage."
        case .smallThree: "Three stacked rows, ours first; one row in landscape."
        case .smallFour: "Two by two, Carol speaking; Dan's camera off. Three hands up, ours included."
        case .smallFive: "Two rows of two and one centred; two rows in landscape."
        case .oneToOneSpeaking: "A voice call: the sound waves come and go round Bob's avatar as he speaks."
        case .ringingPickup: "The ringing screen and ringback; Bob answers with video at 6 s."
        case .ringingVoicePickup: "A voice call ringing; Bob answers without video at 6 s."
        case .ringingDeclined: "Bob declines at 6 s: the screen closes and the decline sound plays out."
        case .ringingUnanswered: "The ring runs out at 6 s: the screen closes and the timeout sound plays out."
        case .joining: "Before there is a call to render."
        case .connectingMedia: "Joined, waiting on media."
        case .failed: "The error the screen shows once and clears."
        case .ended: "After hanging up, before the screen goes away."
        }
    }
    
    /// Android draws the video call as its floating tile and the voice call as its bar; iOS has
    /// only the bar here, because the system window needs a live call (see `ElementCallExampleHost`).
    var opensMinimized: Bool {
        self == .minimizedVoice || self == .minimizedVideo
    }
    
    /// A connected row is a view state written by hand; a connecting row is a connection for a fake
    /// controller to sit in. Modelled as a sum rather than branched on at each use site, because the
    /// two need different objects behind them all the way up to the root view.
    enum Kind {
        case connected(ElementCallScreenViewState)
        case connecting(ElementCallConnection)
        /// A direct call to Bob played on a scripted call: the real controller, screen and sounds.
        case ringing(ElementCallExampleRinging)
        /// A direct call whose tiles change over time, played from an inline scenario.
        case played(scenario: String)
    }
    
    /// Built from the same fixtures the snapshots use, so a failure here and a failure there are
    /// talking about the same people. Every tile with video draws the test pattern.
    @MainActor
    var kind: Kind {
        typealias Fixtures = ElementCallPreviewFixtures
        let crowd = (1...16).map { Fixtures.tile("Member\($0)") }
        let me = Fixtures.tile("Alice", isLocal: true, hasVideo: true)
        switch self {
        case .oneToOne:
            // Our camera on, so the tile draws its flip button: the one control inside a tile, and
            // so the one thing that can prove a tap still reaches a button rather than the gesture
            // wrapped around it. Bob's camera is on too, so his tile draws the pattern. His hand is
            // up and must not show: a one-to-one call draws no hands (009 R33).
            return Self.connected([Fixtures.tile("Alice", isLocal: true, hasVideo: true), Fixtures.tile("Bob", hasVideo: true, handPosition: 1)],
                                  isDirect: true)
        case .group:
            return Self.connected(Fixtures.group)
        case .listenMode:
            // Enough people that the grid scrolls, and enough remote members for listen mode: going
            // full screen from a scrolled grid and coming back to the same offset is the thing
            // worth checking. Carol's hand is up, so the spotlight shows it in her name pill (009 R6);
            // she is already first, where the core ranks a raised hand.
            let group = Fixtures.group.map { $0.id == Fixtures.carol.id ? Fixtures.tile("Carol", isSpeaking: true, handPosition: 1) : $0 }
            return Self.connected(group + crowd)
        case .screenShare:
            // Frank on **two** tiles: his screen is the hero and takes the spotlight, and his camera
            // is still in the strip beside everyone else's. That pairing is the whole of what
            // changed, and it is the one arrangement in which a member-keyed accessibility
            // identifier, released set or `ForEach` identity is wrong rather than merely redundant.
            return Self.connected([Fixtures.alice, Fixtures.share("Frank"), Fixtures.tile("Frank", hasVideo: true), Fixtures.bob])
        case .shareOnLongGrid:
            // The sharer's own camera pushed a long scroll away from their screen. Releasing by
            // member took the hero down with it a few seconds after a scroll, and only a running
            // app shows that: the spotlight simply goes black.
            return Self.connected([Fixtures.alice, Fixtures.share("Frank")] + crowd + [Fixtures.tile("Frank", hasVideo: true)])
        case .twoShares:
            return Self.connected(Fixtures.twoSharesGroup)
        case .video:
            // Bob and Erin are the portrait cameras, the rest landscape and ours the stage's shape:
            // see `TestPatternVideo`.
            // Dan has his camera off, because a stage where every tile is a picture is not the one
            // anybody is in: an avatar is a plain SwiftUI view that resizes on its own, and it is
            // worth being able to see the two side by side through the same move.
            // Dan comes second so he lands in the first row.
            let tiles = ["Alice", "Dan", "Carol", "Bob", "Erin", "Frank"].enumerated().map { index, name in
                Fixtures.tile(name, isLocal: index == 0, hasVideo: name != "Dan")
            }
            return Self.connected(tiles)
        case .twoHundred:
            // What Android measured its scroll against, and what a phone fast enough to hide the
            // cost never shows by hand: a band of about thirty composed tiles, most of them drawing
            // pictures, crossing row edges on nearly every frame of a fling. One in five has the
            // camera off, as in a real call of this size. Carol speaking puts listen mode's
            // spotlight over the grid. Measure it in a Release build: see `ScrollPerformanceUITests`.
            let extras = (1...192).map { Fixtures.tile("Member\($0)", hasVideo: $0 % 5 != 0) }
            let group = [Fixtures.tile("Alice", isLocal: true, hasVideo: true),
                         Fixtures.tile("Carol", hasVideo: true, isSpeaking: true)]
                + ["Bob", "Dan", "Erin", "Frank", "Grace", "Heidi"].map { Fixtures.tile($0, hasVideo: true) }
            return Self.connected(group + extras)
        case .muted:
            return Self.connected([Fixtures.tile("Alice", isLocal: true, isMuted: true), Fixtures.bob], isDirect: true)
        case .minimizedVoice:
            return Self.connected([Fixtures.alice, Fixtures.tile("Bob")], isDirect: true)
        case .minimizedVideo:
            return Self.connected([Fixtures.alice, Fixtures.tile("Bob", hasVideo: true)], isDirect: true)
        // Spec 019's small calls, one per arrangement. Remote tiles are listed in rank order, which
        // in a fixture is also the order they arrived in.
        case .alone:
            return Self.connected([me])
        case .oneToOneLandscape:
            return Self.connected([me, Fixtures.tile("Carol", hasVideo: true)], isDirect: true)
        case .smallThree:
            return Self.connected([me, Fixtures.tile("Carol", hasVideo: true), Fixtures.tile("Bob", hasVideo: true)])
        case .smallFour:
            // Three hands, one of each kind (009 R6, R9): ours, Carol's under her speaking border,
            // and Dan's on his avatar.
            return Self.connected([Fixtures.tile("Alice", isLocal: true, hasVideo: true, handPosition: 3),
                                   Fixtures.tile("Carol", hasVideo: true, isSpeaking: true, handPosition: 1),
                                   Fixtures.tile("Bob", hasVideo: true),
                                   Fixtures.tile("Dan", handPosition: 2)])
        case .smallFive:
            return Self.connected([me] + [("Carol", true), ("Bob", true), ("Dan", false), ("Erin", true)].map { Fixtures.tile($0, hasVideo: $1) })
        case .oneToOneSpeaking:
            // Speaking for 2 s in every 3, for half a minute. `BOB` is `@bob:example.com`.
            let frames = stride(from: 0, to: 30, by: 3).flatMap { second in ["\(second)s BOB", "\(second + 1)s BOB!"] }
            return .played(scenario: frames.joined(separator: "\n"))
        case .ringingPickup:
            return .ringing(ElementCallExampleRinging(isAudioCall: false, outcome: .pickUp))
        case .ringingVoicePickup:
            return .ringing(ElementCallExampleRinging(isAudioCall: true, outcome: .pickUp))
        case .ringingDeclined:
            return .ringing(ElementCallExampleRinging(isAudioCall: false, outcome: .declined))
        case .ringingUnanswered:
            return .ringing(ElementCallExampleRinging(isAudioCall: false, outcome: .unanswered))
        case .joining:
            return .connecting(.joining)
        case .connectingMedia:
            return .connecting(.connectingMedia)
        case .failed:
            return .connecting(.failed("Homeserver offers no LiveKit transport"))
        case .ended:
            return .connecting(.ended(.left))
        }
    }
    
    /// The controls start where our own tile is, so the first tap on the camera or the microphone
    /// turns it the other way rather than lighting a button our tile already agreed with.
    @MainActor
    private static func connected(_ tiles: [ElementCallTile], isDirect: Bool = false) -> Kind {
        let own = tiles.first { $0.isLocal }
        var state = ElementCallPreviewFixtures.connected(tiles: tiles,
                                                         isDirect: isDirect,
                                                         isMicrophoneMuted: own?.isMicrophoneMuted ?? false)
        state.isCameraEnabled = own?.hasVideo ?? false
        state.isHandRaised = own?.hasHandRaised ?? false
        return .connected(state)
    }
}

/// What the app was asked to open on.
enum ElementCallExampleLaunchTarget {
    case catalogue
    case fixture(ElementCallExampleFixture)
    /// A scenario file by name, `-scenario 002_listen_mode`.
    case scenario(ElementCallExampleScenario)
    /// A flag was passed with something it does not name. Deliberately not folded into
    /// ``catalogue``: the old behaviour was to quietly substitute `.group`, so a misspelt fixture
    /// ran the strip tests against an eight-person stage and failed with "this tile is not
    /// hittable" — true, and about nothing. Named, it goes on screen, which means it goes into
    /// the failure screenshot.
    case unknown(flag: String, name: String)
    
    static func fromLaunchArguments() -> ElementCallExampleLaunchTarget {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: ElementCallExampleFixture.launchArgument) {
            let name = arguments[safe: index + 1] ?? ""
            return ElementCallExampleFixture(rawValue: name).map { .fixture($0) }
                ?? .unknown(flag: ElementCallExampleFixture.launchArgument, name: name)
        }
        if let index = arguments.firstIndex(of: ElementCallExampleFixture.scenarioLaunchArgument) {
            let name = arguments[safe: index + 1] ?? ""
            return ElementCallExampleScenario.named(name).map { .scenario($0) }
                ?? .unknown(flag: ElementCallExampleFixture.scenarioLaunchArgument, name: name)
        }
        return .catalogue
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
