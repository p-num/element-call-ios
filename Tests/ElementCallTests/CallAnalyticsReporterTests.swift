//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallHost
@testable import ElementCallKit
import Foundation
import MatrixRtc
import Testing

/// The analytics' state machine alone, with no call: every sequence of the moments the controller
/// reports, on a manual clock (044).
@Suite("Call analytics reporter")
@MainActor
struct CallAnalyticsReporterTests {
    typealias Event = ElementCallAnalyticsEvent
    typealias Failure = ElementCallAnalyticsFailure
    
    // MARK: - One outcome, one end (R7, R11, R14)
    
    /// Every interleaving of the moments after an attempt gives exactly one outcome, and an end only
    /// after `connected`.
    @Test
    func everyInterleavingGivesOneOutcomeAndAnEndOnlyAfterConnected() {
        let moments: [(String, (ElementCallAnalyticsReporter) -> Void)] = [
            ("media", { $0.mediaConnected(memberCount: 2) }),
            ("microphone", { $0.microphonePublished(memberCount: 2) }),
            ("hang up", { $0.hungUp() }),
            ("declined", { $0.ended(.declined) }),
            ("left", { $0.ended(.left) }),
            ("lost", { $0.ended(.connectionClosed(reason: .budget, message: "gone")) }),
            ("failed", { $0.failed(.other, stage: .homeserver, step: .unknown) }),
            ("refused", { $0.permissionRefused() }),
            ("participants", { $0.participants(4) })
        ]
        // Every ordered sequence of three distinct moments, and every pair repeated.
        var sequences: [[Int]] = []
        for first in moments.indices {
            for second in moments.indices {
                sequences.append([first, second, first, second])
                for third in moments.indices where third != first && third != second && first != second {
                    sequences.append([first, second, third])
                }
            }
        }
        for sequence in sequences {
            let fixture = Fixture()
            fixture.reporter.attempted(callKind: .group)
            for index in sequence {
                moments[index].1(fixture.reporter)
            }
            let names = sequence.map { moments[$0].0 }
            let events = fixture.analytics.events
            let outcomes = events.compactMap(\.outcome)
            let ends = events.filter { $0.name == "CallParticipationEnded" }
            #expect(outcomes.count <= 1, "\(names)")
            #expect(ends.count <= 1, "\(names)")
            if !ends.isEmpty {
                #expect(outcomes == [.connected], "\(names)")
            }
            // Finishing it settles it: an outcome always, whatever came first.
            fixture.reporter.hungUp()
            let finalOutcomes = fixture.analytics.events.compactMap(\.outcome)
            #expect(finalOutcomes.count == 1, "\(names)")
            let finalEnds = fixture.analytics.events.filter { $0.name == "CallParticipationEnded" }.count
            #expect(finalEnds == (finalOutcomes == [.connected] ? 1 : 0), "\(names)")
        }
    }
    
    /// Repeats add nothing, which is R14's guarantee whatever path reaches the reporter again.
    @Test
    func repeatedMomentsAddNothing() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        for _ in 0..<3 {
            fixture.reporter.mediaConnected(memberCount: 1)
            fixture.reporter.microphonePublished(memberCount: 1)
        }
        for _ in 0..<3 {
            fixture.reporter.ended(.othersLeft)
            fixture.reporter.failed(.other, stage: .homeserver, step: .unknown)
            fixture.reporter.hungUp()
        }
        #expect(fixture.analytics.events.map(\.name) == ["CallJoinAttempted", "CallJoinOutcome", "CallParticipationEnded"])
        #expect(fixture.analytics.events.last?.endReason == .othersLeft)
    }
    
    // MARK: - Connected (R8, C5)
    
    @Test(arguments: [true, false])
    func connectedGoesOutAtTheSecondOfMediaAndMicrophone(mediaFirst: Bool) {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        if mediaFirst {
            fixture.reporter.mediaConnected(memberCount: 1)
        } else {
            fixture.reporter.microphonePublished(memberCount: 1)
        }
        #expect(fixture.analytics.events.compactMap(\.outcome).isEmpty)
        if mediaFirst {
            fixture.reporter.microphonePublished(memberCount: 1)
        } else {
            fixture.reporter.mediaConnected(memberCount: 1)
        }
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.connected])
    }
    
    /// R11: from R8's moment, on the controller's clock, in whole milliseconds.
    @Test
    func theDurationRunsFromConnectedToTheEnd() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .dm)
        fixture.reporter.mediaConnected(memberCount: 1)
        fixture.clock.advance(by: .seconds(5))
        fixture.reporter.microphonePublished(memberCount: 1)
        fixture.clock.advance(by: .milliseconds(42123))
        fixture.reporter.ended(.unanswered)
        
        let end = fixture.analytics.events.last
        #expect(end?.properties["durationMs"] == .int(42123))
        #expect(end?.endReason == .unanswered)
    }
    
    /// R20: a long call reports nothing by itself.
    @Test
    func timePassingReportsNothing() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.mediaConnected(memberCount: 1)
        fixture.reporter.microphonePublished(memberCount: 1)
        let count = fixture.analytics.events.count
        fixture.clock.advance(by: .seconds(600))
        #expect(fixture.analytics.events.count == count)
    }
    
    // MARK: - The microphone (R8, R16, C6)
    
    @Test
    func aMicrophoneThatFailsAfterMediaIsAJoinFailure() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.mediaConnected(memberCount: 1)
        fixture.reporter.failed(.microphoneFailed, stage: .media, step: .mediaConnection)
        fixture.reporter.ended(.left)
        
        #expect(fixture.analytics.events.map(\.name) == ["CallJoinAttempted", "CallJoinOutcome", "CallFailure"])
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.failed])
        #expect(fixture.analytics.events.compactMap(\.failure)
            == [Failure(cause: .microphoneFailed, phase: .joining(.media, .mediaConnection))])
    }
    
    // MARK: - Abandoned and ends from the core (R9, R12, R24, C8)
    
    @Test
    func aHangUpBeforeConnectedIsAbandonedWithNoReason() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.mediaConnected(memberCount: 1)
        fixture.reporter.hungUp()
        
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.abandoned(endReason: nil)])
        #expect(fixture.analytics.events.last?.properties["endReason"] == nil)
        #expect(fixture.analytics.events.compactMap(\.failure).isEmpty)
    }
    
    @Test(arguments: [(MatrixRTCEndReason.declined, Event.EndReason.declined),
                      (.unanswered, .unanswered),
                      (.ringNotSent, .ringNotSent),
                      (.othersLeft, .othersLeft),
                      (.empty, .empty),
                      (.slotClosed, .slotClosed)])
    func anEndFromTheOtherSideBeforeConnectedIsAbandonedWithItsReason(reason: MatrixRTCEndReason, expected: Event.EndReason) {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .dm)
        fixture.reporter.ended(reason)
        
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.abandoned(endReason: expected)])
        #expect(fixture.analytics.events.last?.properties["endReason"] == .string(expected.rawValue))
        #expect(fixture.analytics.events.compactMap(\.failure).isEmpty)
    }
    
    /// The core leaves plainly only for our own leave or close: our side (C8).
    @Test
    func aPlainLeaveBeforeConnectedIsOurs() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.ended(.left)
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.abandoned(endReason: nil)])
    }
    
    @Test(arguments: [(MatrixRTCEndReason.left, Event.EndReason.left),
                      (.declined, .declined),
                      (.unanswered, .unanswered),
                      (.ringNotSent, .ringNotSent),
                      (.othersLeft, .othersLeft),
                      (.empty, .empty),
                      (.slotClosed, .slotClosed)])
    func anEndAfterConnectedMapsOneToOne(reason: MatrixRTCEndReason, expected: Event.EndReason) {
        let fixture = Fixture()
        fixture.connect()
        fixture.reporter.ended(reason)
        
        #expect(fixture.analytics.events.last?.endReason == expected)
        #expect(fixture.analytics.events.compactMap(\.failure).isEmpty)
    }
    
    // MARK: - Connection lost (R15, C7)
    
    @Test(arguments: [(MatrixRTCConnectionLossReason.budget, Failure.Cause.connectionLostBudget, Failure.Step.unknown),
                      (.refused, .connectionLostRefused, .unknown),
                      (.neverConnected, .connectionLostNeverConnected, .unknown),
                      (.tokenEndpointUnsupported, .tokenEndpointUnsupported, .mediaToken)])
    func aConnectionClosedBeforeConnectedIsAJoinFailure(loss: MatrixRTCConnectionLossReason,
                                                        cause: Failure.Cause,
                                                        step: Failure.Step) {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.mediaConnected(memberCount: 1)
        fixture.reporter.ended(.connectionClosed(reason: loss, message: "secret server text"))
        
        #expect(fixture.analytics.events.map(\.name) == ["CallJoinAttempted", "CallJoinOutcome", "CallFailure"])
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.failed])
        #expect(fixture.analytics.events.compactMap(\.failure) == [Failure(cause: cause, phase: .joining(.media, step))])
    }
    
    /// C4: the in-call failure, then the end.
    @Test
    func aConnectionClosedAfterConnectedIsAnInCallFailureThenAnEnd() {
        let fixture = Fixture()
        fixture.connect()
        fixture.reporter.ended(.connectionClosed(reason: .refused, message: "secret server text"))
        
        let events = fixture.analytics.events
        #expect(events.map(\.name) == ["CallJoinAttempted", "CallJoinOutcome", "CallFailure", "CallParticipationEnded"])
        #expect(events.compactMap(\.failure) == [Failure(cause: .connectionLostRefused, phase: .inCall)])
        #expect(events.last?.endReason == .connectionLost)
    }
    
    // MARK: - The core's end over a racing hang-up (C8)
    
    /// Once the core's end is in, a hang-up adds nothing: the decline stays a decline.
    @Test
    func theCoresEndBeforeConnectedWinsOverAHangUp() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .dm)
        fixture.reporter.mediaConnected(memberCount: 1)
        fixture.reporter.ended(.declined)
        fixture.reporter.hungUp()
        
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.abandoned(endReason: .declined)])
        #expect(fixture.analytics.events.count == 2)
    }
    
    @Test
    func theCoresEndAfterConnectedWinsOverAHangUp() {
        let fixture = Fixture()
        fixture.connect(callKind: .dm)
        fixture.reporter.ended(.othersLeft)
        fixture.reporter.hungUp()
        
        #expect(fixture.analytics.events.filter { $0.name == "CallParticipationEnded" }.map(\.endReason) == [.othersLeft])
    }
    
    // MARK: - Permission (R10)
    
    @Test
    func aRefusedMicrophoneIsNotAFailure() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.joinFailed(.permissionRefused)
        fixture.reporter.ended(.left)
        
        #expect(fixture.analytics.events.compactMap(\.outcome) == [.permissionRefused])
        #expect(fixture.analytics.events.compactMap(\.failure).isEmpty)
    }
    
    // MARK: - Linking (R19, R25)
    
    @Test
    func everyEventOfAnAttemptSharesARandomID() throws {
        let fixture = Fixture()
        fixture.connect()
        fixture.reporter.ended(.connectionClosed(reason: .budget, message: ""))
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.hungUp()
        
        let events = fixture.analytics.events
        let first = Set(events.prefix(4).map(\.attemptID))
        let second = Set(events.suffix(2).map(\.attemptID))
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first != second)
        for id in first.union(second) {
            let uuid = try #require(UUID(uuidString: id))
            // Version 4: random.
            #expect(uuid.uuid.6 >> 4 == 4)
        }
        #expect(events.allSatisfy { $0.properties["attemptId"] == .string($0.attemptID) })
    }
    
    @Test(arguments: [Event.CallKind.dm, .group])
    func everyEventCarriesTheAttemptsCallKind(callKind: Event.CallKind) {
        let fixture = Fixture()
        fixture.connect(callKind: callKind)
        fixture.reporter.ended(.connectionClosed(reason: .budget, message: ""))
        
        #expect(fixture.analytics.events.count == 4)
        #expect(fixture.analytics.events.allSatisfy { $0.callKind == callKind })
        #expect(fixture.analytics.events.allSatisfy { $0.properties["callKind"] == .string(callKind.rawValue) })
    }
    
    // MARK: - participantsMax (R26, C10)
    
    @Test
    func participantsMaxIsSeededAtConnectedAndOnlyRaised() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.participants(9) // Before connected: not counted.
        fixture.reporter.mediaConnected(memberCount: 3)
        fixture.reporter.microphonePublished(memberCount: 3)
        fixture.reporter.participants(5)
        fixture.reporter.participants(2)
        fixture.reporter.hungUp()
        fixture.reporter.participants(12) // After the end: nothing to count into.
        
        #expect(fixture.analytics.events.last?.properties["participantsMax"] == .int(5))
    }
    
    /// A DM that rang out with nobody joining, and a seed the core reports as empty.
    @Test
    func participantsMaxIsNeverBelowOne() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .dm)
        fixture.reporter.mediaConnected(memberCount: 0)
        fixture.reporter.microphonePublished(memberCount: 0)
        fixture.reporter.ended(.unanswered)
        
        #expect(fixture.analytics.events.last?.properties["participantsMax"] == .int(1))
    }
    
    // MARK: - Properties (R3–R5, R21–R26)
    
    @Test
    func eachEventHasExactlyTheSpecsKeys() {
        let common: Set = ["callImplementation", "callPlatform", "callComponentVersion", "attemptId", "callKind"]
        let id = "00000000-0000-4000-8000-000000000000"
        let cases: [(Event, Set<String>)] = [
            (.callJoinAttempted(attemptID: id, callKind: .dm), common),
            (.callJoinOutcome(attemptID: id, callKind: .dm, outcome: .connected), common.union(["outcome"])),
            (.callJoinOutcome(attemptID: id, callKind: .dm, outcome: .abandoned(endReason: nil)), common.union(["outcome"])),
            (.callJoinOutcome(attemptID: id, callKind: .dm, outcome: .abandoned(endReason: .declined)), common.union(["outcome", "endReason"])),
            (.callFailure(attemptID: id, callKind: .dm, failure: Failure(cause: .joinRefused, phase: .joining(.homeserver, .unknown), errorCode: "M_FORBIDDEN")),
             common.union(["cause", "phase", "stage", "step", "errcode"])),
            (.callFailure(attemptID: id, callKind: .dm, failure: Failure(cause: .joinTimedOut, phase: .joining(.homeserver, .unknown), errorCode: "M_FORBIDDEN")),
             common.union(["cause", "phase", "stage", "step"])),
            (.callFailure(attemptID: id, callKind: .dm, failure: Failure(cause: .connectionLostBudget, phase: .inCall)),
             common.union(["cause", "phase"])),
            (.callParticipationEnded(attemptID: id, callKind: .dm, endReason: .left, duration: .seconds(1), participantsMax: 2),
             common.union(["endReason", "durationMs", "participantsMax"]))
        ]
        for (event, keys) in cases {
            #expect(Set(event.properties.keys) == keys, "\(event)")
            #expect(event.properties["callImplementation"] == .string("native"))
            #expect(event.properties["callPlatform"] == .string("ios"))
            #expect(event.properties["callComponentVersion"] == .string(ElementCallVersion.current))
        }
    }
    
    @Test
    func namesAndSpellingsAreTheSpecs() {
        let id = "id"
        #expect(Event.callJoinAttempted(attemptID: id, callKind: .dm).name == "CallJoinAttempted")
        #expect(Event.callJoinOutcome(attemptID: id, callKind: .dm, outcome: .permissionRefused).properties["outcome"] == .string("permissionRefused"))
        let failure = Event.callFailure(attemptID: id, callKind: .group,
                                        failure: Failure(cause: .noMediaServer, phase: .joining(.homeserver, .transportDiscovery)))
        #expect(failure.name == "CallFailure")
        #expect(failure.properties["phase"] == .string("joining"))
        #expect(failure.properties["cause"] == .string("noMediaServer"))
        #expect(failure.properties["stage"] == .string("homeserver"))
        #expect(failure.properties["step"] == .string("transportDiscovery"))
        #expect(Event.callFailure(attemptID: id, callKind: .group, failure: Failure(cause: .other, phase: .inCall)).properties["phase"] == .string("inCall"))
        #expect(Event.callParticipationEnded(attemptID: id, callKind: .dm, endReason: .othersLeft, duration: .zero, participantsMax: 1).name
            == "CallParticipationEnded")
    }
    
    // MARK: - errcode (R21, C9)
    
    @Test(arguments: ["M_FORBIDDEN", "M_LIMIT_EXCEEDED", "IO.ELEMENT.SOME_CODE", "A", String(repeating: "A", count: 64)])
    func aWellFormedErrorCodeIsReported(errorCode: String) {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.failed(.joinRefused, stage: .homeserver, step: .unknown, errorCode: errorCode)
        #expect(fixture.analytics.events.last?.properties["errcode"] == .string(errorCode))
    }
    
    @Test(arguments: ["m_forbidden", "_M_FORBIDDEN", "1M_FORBIDDEN", String(repeating: "A", count: 65),
                      "You are not allowed in this room", "", "M_FORBİDDEN", "M-FORBIDDEN"])
    func anyOtherErrorCodeIsReportedAsNone(errorCode: String) {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.failed(.joinRefused, stage: .homeserver, step: .unknown, errorCode: errorCode)
        let failure = fixture.analytics.events.last
        #expect(failure?.name == "CallFailure")
        #expect(failure?.properties["errcode"] == nil)
        #expect(failure?.failure?.errorCode == nil)
        #expect(fixture.logger.messages.contains { $0.contains("errcode") })
    }
    
    @Test
    func anErrorCodeIsOnlyOnJoinRefused() {
        let fixture = Fixture()
        fixture.reporter.attempted(callKind: .group)
        fixture.reporter.failed(.joinTimedOut, stage: .homeserver, step: .unknown, errorCode: "M_FORBIDDEN")
        #expect(fixture.analytics.events.last?.properties["errcode"] == nil)
    }
    
    // MARK: - The join error table (R16, R23)
    
    @Test(arguments: [
        (MatrixRTCError.joinTimedOut, ElementCallAnalyticsReporter.JoinFailure.failed(.joinTimedOut, .homeserver, .unknown)),
        (.joinRefused(errorCode: "M_FORBIDDEN", reason: "nope"), .failed(.joinRefused, .homeserver, .unknown, errorCode: "M_FORBIDDEN")),
        (.joinRefused(errorCode: nil, reason: "nope"), .failed(.joinRefused, .homeserver, .unknown)),
        (.slotClosed("closed"), .failed(.slotClosed, .homeserver, .membership)),
        (.noLiveKitTransport(transportType: "livekit"), .failed(.noMediaServer, .homeserver, .transportDiscovery)),
        (.tokenEndpointUnsupported, .failed(.tokenEndpointUnsupported, .media, .mediaToken)),
        (.roomNotReady(roomID: "!room:example.org"), .failed(.other, .homeserver, .unknown)),
        (.ffi("whatever"), .failed(.other, .homeserver, .unknown)),
        (.media("whatever"), .failed(.other, .homeserver, .unknown))
    ])
    func eachJoinErrorHasItsCauseStageAndStep(error: MatrixRTCError, expected: ElementCallAnalyticsReporter.JoinFailure) {
        #expect(ElementCallAnalyticsReporter.JoinFailure.forJoinError(error) == expected)
    }
    
    /// The Kit keeps each join error the core types, so the table above can name it (C7).
    @Test(arguments: [
        (MatrixRtcFfiError.JoinTimedOut, "joinTimedOut"),
        (.JoinRefused(errcode: "M_FORBIDDEN", reason: "nope"), #"joinRefused(errorCode: Optional("M_FORBIDDEN"), reason: "nope")"#),
        (.SlotClosed("closed"), #"slotClosed("closed")"#),
        (.NoLiveKitTransport(transportType: "livekit"), #"noLiveKitTransport(transportType: "livekit")"#),
        (.TokenEndpointUnsupported, "tokenEndpointUnsupported"),
        (.Backend("down"), #"ffi("Backend(\"down\")")"#)
    ])
    func theKitKeepsEachJoinErrorTyped(error: MatrixRtcFfiError, expected: String) {
        #expect(expected == "\(MatrixRTCRoom.joinError(for: error, roomID: "!room:example.org"))")
    }
    
    // MARK: - No receiver (R2)
    
    @Test
    func withNoReceiverNothingIsKept() {
        let reporter = ElementCallAnalyticsReporter(analytics: nil, logger: nil)
        reporter.attempted(callKind: .group)
        reporter.mediaConnected(memberCount: 1)
        reporter.microphonePublished(memberCount: 1)
        // A receiver arriving later has no way in: the port is given at `init` only.
        reporter.hungUp()
        reporter.hungUp()
    }
    
    // MARK: - Helpers
    
    private final class Fixture {
        let analytics = ElementCallFakeAnalytics()
        let logger = ElementCallFakeLogger()
        let clock = MatrixRTCManualClock()
        let reporter: ElementCallAnalyticsReporter
        
        init() {
            reporter = ElementCallAnalyticsReporter(analytics: analytics, logger: logger)
            reporter.clock = clock
        }
        
        func connect(callKind: Event.CallKind = .group) {
            reporter.attempted(callKind: callKind)
            reporter.mediaConnected(memberCount: 1)
            reporter.microphonePublished(memberCount: 1)
        }
    }
}

extension ElementCallAnalyticsEvent {
    var outcome: Outcome? {
        if case .callJoinOutcome(_, _, let outcome) = self {
            outcome
        } else {
            nil
        }
    }
    
    var failure: ElementCallAnalyticsFailure? {
        if case .callFailure(_, _, let failure) = self {
            failure
        } else {
            nil
        }
    }
    
    var endReason: EndReason? {
        if case .callParticipationEnded(_, _, let endReason, _, _) = self {
            endReason
        } else {
            nil
        }
    }
}
