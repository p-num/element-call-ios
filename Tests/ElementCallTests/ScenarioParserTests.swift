//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation
import Testing

/// The scenario grammar, as `scenarios/README.md` in feature-hq states it. The corpus is vendored
/// under `Scenarios/`; hq is the source of truth and a copy that differs is a review finding.
nonisolated struct ScenarioParserTests {
    static func corpus() throws -> [URL] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "txt", subdirectory: "Scenarios") ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    static func load(_ url: URL) throws -> MatrixRTCScenario {
        try MatrixRTCScenario.parse(String(contentsOf: url, encoding: .utf8), name: url.deletingPathExtension().lastPathComponent)
    }
    
    @Test
    func everyVendoredScenarioParses() throws {
        let corpus = try Self.corpus()
        #expect(corpus.count == 7)
        for url in corpus {
            let scenario = try Self.load(url)
            #expect(!scenario.frames.isEmpty, "\(scenario.name) has no frames")
            #expect(scenario.frames.first?.event == MatrixRTCScenario.defaultViewport, "\(scenario.name) does not open with the default viewport")
        }
    }
    
    @Test
    func aTokenCarriesItsNameKindAndFlags() throws {
        let scenario = try MatrixRTCScenario.parse("0s A#* B!^ Cv Dm E", name: "t")
        guard case .roster(let tokens) = scenario.frames.first?.event else {
            Issue.record("not a roster")
            return
        }
        #expect(tokens.map(\.name) == ["A", "B", "C", "D", "E"])
        #expect(tokens[0].kind == .screenShare && tokens[0].isHero)
        #expect(tokens[1].isSpeaking && tokens[1].hasHandRaised && tokens[1].kind == .person)
        #expect(tokens[2].hasVideo)
        #expect(tokens[3].isMicrophoneMuted)
        #expect(tokens[4] == MatrixRTCScenario.Token(name: "E"))
        #expect(tokens[0].tileID == MatrixRTCTileID(memberID: "@A:example.com:DEVICE", kind: .screenShare))
        #expect(tokens[0].userID == "@a:example.com")
    }
    
    /// A roster with nothing after the time is being alone (001_small_calls opens with it).
    @Test
    func anEmptyRosterIsBeingAlone() throws {
        let scenario = try MatrixRTCScenario.parse("0s", name: "t")
        #expect(scenario.frames.first?.event == .roster([]))
    }
    
    @Test
    func everyActionParses() throws {
        let text = """
        0s    viewport 393x734 bottom 34 top 59
        0.5s  scroll 600
        1s    rotate landscape
        1500ms fullscreen B
        2s    fullscreen none
        2s    swipe-hero next
        3s    minimize
        4s    restore
        5s    me vm
        6s    detail-only A#* B
        7s    tick   // a comment
        """
        let events = try MatrixRTCScenario.parse(text, name: "t").frames.map(\.event)
        #expect(events == [.viewport(size: CGSize(width: 393, height: 734), topInset: 59, bottomInset: 34),
                           .scroll(600),
                           .rotate(.landscape),
                           .fullscreen(MatrixRTCTileID(memberID: "@B:example.com:DEVICE")),
                           .fullscreen(nil),
                           .swipeHero(.next),
                           .minimize,
                           .restore,
                           .me(hasVideo: true, isMicrophoneMuted: true),
                           .detailOnly([MatrixRTCTileID(memberID: "@A:example.com:DEVICE", kind: .screenShare), MatrixRTCTileID(memberID: "@B:example.com:DEVICE")]),
                           .tick])
        let times = try MatrixRTCScenario.parse(text, name: "t").frames.map(\.time)
        #expect(times[1] == .milliseconds(500) && times[3] == .milliseconds(1500))
    }
    
    /// A malformed line names its own line number, so a typo in a scenario fails on the line and
    /// not somewhere in a dump about nothing.
    @Test
    func aMalformedLineNamesItself() {
        #expect(throws: MatrixRTCScenario.ParseError(scenario: "t", line: 4, message: "times must not decrease")) {
            try MatrixRTCScenario.parse("0s A\n\n1s B\n0.5s C", name: "t")
        }
        #expect(throws: MatrixRTCScenario.ParseError.self) {
            try MatrixRTCScenario.parse("0s A$", name: "t")
        }
        #expect(throws: MatrixRTCScenario.ParseError.self, "a lowercase name is a flag, not a member") {
            try MatrixRTCScenario.parse("0s bob", name: "t")
        }
        #expect(throws: MatrixRTCScenario.ParseError.self) {
            try MatrixRTCScenario.parse("0s scroll", name: "t")
        }
        #expect(throws: MatrixRTCScenario.ParseError.self) {
            try MatrixRTCScenario.parse("soon A", name: "t")
        }
    }
}
