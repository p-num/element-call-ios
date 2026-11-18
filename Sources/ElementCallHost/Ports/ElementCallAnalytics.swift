//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// Where the call's analytics go (044). The component sends nothing over the network itself; it
/// hands every event to this receiver, and the host forwards it.
///
/// The host forwards each event under ``ElementCallAnalyticsEvent/name`` with
/// ``ElementCallAnalyticsEvent/properties`` unchanged, so both platforms land in the same graphs,
/// and only with the user's consent to analytics.
///
/// Called on the main actor, synchronously, at the moment the event happens, and never later: an
/// event with no receiver is dropped, not kept. The end of a call reaches it before the call is torn
/// down, as long as the call is ended through the controller: call
/// ``ElementCallController/hangUp()`` before discarding a controller with a call in it, on logout as
/// anywhere else. A controller discarded mid-call reports no end.
public nonisolated protocol ElementCallAnalyticsProtocol: Sendable {
    func track(_ event: ElementCallAnalyticsEvent)
}

/// One analytics event. Typed for a host or a test that wants the cause, and spelled for the forward
/// by ``name`` and ``properties``, so no host writes its own mapping to strings.
public nonisolated enum ElementCallAnalyticsEvent: Sendable, Equatable {
    /// A start or a join was accepted, before anything is joined (R6).
    case callJoinAttempted(attemptID: String, callKind: CallKind)
    /// How the attempt turned out: exactly one per attempt (R7).
    case callJoinOutcome(attemptID: String, callKind: CallKind, outcome: Outcome)
    /// Why it failed, once per failure (R15).
    case callFailure(attemptID: String, callKind: CallKind, failure: ElementCallAnalyticsFailure)
    /// A connected call ended: exactly one per connected attempt (R11). `participantsMax` counts
    /// ourselves (R26).
    case callParticipationEnded(attemptID: String, callKind: CallKind, endReason: EndReason,
                                duration: Duration, participantsMax: Int)
    
    public enum Outcome: Sendable, Equatable {
        /// Our own media is up and our microphone is published (R8).
        case connected
        case failed
        /// The microphone permission is refused (R10).
        case permissionRefused
        /// Ended before it connected without a failure (R9). `endReason` when the call ended from
        /// the other side, nil when the user or the host ended it (R24).
        case abandoned(endReason: EndReason?)
    }
    
    /// R12.
    public enum EndReason: String, Sendable {
        case left, othersLeft, declined, unanswered, ringNotSent, empty, slotClosed, connectionLost
    }
    
    /// R25. `dm` when the room is a direct-message room, `group` otherwise.
    public enum CallKind: String, Sendable {
        case dm, group
    }
    
    /// "CallJoinAttempted", "CallJoinOutcome", "CallFailure" or "CallParticipationEnded".
    public var name: String {
        switch self {
        case .callJoinAttempted: "CallJoinAttempted"
        case .callJoinOutcome: "CallJoinOutcome"
        case .callFailure: "CallFailure"
        case .callParticipationEnded: "CallParticipationEnded"
        }
    }
    
    /// Every property the spec names, under its spelling: the three constants, `attemptId` and
    /// `callKind` on every event (R3–R5, R19, R25), and the event's own. Values are closed: an
    /// enum's spelling, a constant, the attempt's UUID, a count, a duration or a Matrix error code.
    public var properties: [String: ElementCallAnalyticsValue] {
        var properties: [String: ElementCallAnalyticsValue] = [
            "callImplementation": .string("native"),
            "callPlatform": .string("ios"),
            // The component's, never the host app's `Bundle.main` version (R5).
            "callComponentVersion": .string(ElementCallVersion.current),
            "attemptId": .string(attemptID),
            "callKind": .string(callKind.rawValue)
        ]
        switch self {
        case .callJoinAttempted:
            break
        case .callJoinOutcome(_, _, let outcome):
            properties["outcome"] = .string(outcome.name)
            if case .abandoned(let endReason?) = outcome {
                properties["endReason"] = .string(endReason.rawValue)
            }
        case .callFailure(_, _, let failure):
            properties["cause"] = .string(failure.cause.rawValue)
            switch failure.phase {
            case .joining(let stage, let step):
                properties["phase"] = .string("joining")
                properties["stage"] = .string(stage.rawValue)
                properties["step"] = .string(step.rawValue)
            case .inCall:
                properties["phase"] = .string("inCall")
            }
            if let errorCode = failure.errorCode {
                properties["errcode"] = .string(errorCode)
            }
        case .callParticipationEnded(_, _, let endReason, let duration, let participantsMax):
            properties["endReason"] = .string(endReason.rawValue)
            properties["durationMs"] = .int(duration.wholeMilliseconds)
            properties["participantsMax"] = .int(participantsMax)
        }
        return properties
    }
    
    /// The attempt every event of one join carries (R19).
    public var attemptID: String {
        switch self {
        case .callJoinAttempted(let attemptID, _), .callJoinOutcome(let attemptID, _, _),
             .callFailure(let attemptID, _, _), .callParticipationEnded(let attemptID, _, _, _, _):
            attemptID
        }
    }
    
    public var callKind: CallKind {
        switch self {
        case .callJoinAttempted(_, let callKind), .callJoinOutcome(_, let callKind, _),
             .callFailure(_, let callKind, _), .callParticipationEnded(_, let callKind, _, _, _):
            callKind
        }
    }
}

public nonisolated extension ElementCallAnalyticsEvent.Outcome {
    /// The spec's spelling, without the end reason.
    var name: String {
        switch self {
        case .connected: "connected"
        case .failed: "failed"
        case .permissionRefused: "permissionRefused"
        case .abandoned: "abandoned"
        }
    }
}

/// What a failure says, and nothing else: no message, no server text (R16, R17). Built only inside
/// the package, so nothing can put text in it.
public nonisolated struct ElementCallAnalyticsFailure: Sendable, Equatable {
    /// R16.
    public enum Cause: String, Sendable, CaseIterable {
        case joinTimedOut, joinRefused, slotClosed, noMediaServer, tokenEndpointUnsupported,
             connectionLostNeverConnected, connectionLostRefused, connectionLostBudget,
             microphoneFailed, other
    }
    
    /// R22: which server to look at.
    public enum Stage: String, Sendable {
        case homeserver, media
    }
    
    /// R23: `unknown` until the core says which step failed.
    public enum Step: String, Sendable {
        case transportDiscovery, membership, mediaToken, mediaConnection, unknown
    }
    
    /// R15: before our own media first connected, or after.
    public enum Phase: Sendable, Equatable {
        case joining(Stage, Step)
        case inCall
    }
    
    public let cause: Cause
    public let phase: Phase
    /// `joinRefused` only, and only a value with the shape of a Matrix error code (R21).
    public let errorCode: String?
    
    /// `errorCode` is the homeserver's, unfiltered: it is kept only on `joinRefused`, and only when it
    /// has the shape of a code.
    package init(cause: Cause, phase: Phase, errorCode: String? = nil) {
        self.cause = cause
        self.phase = phase
        self.errorCode = cause == .joinRefused ? errorCode.flatMap(Self.validErrorCode) : nil
    }
    
    /// R21: capital letters, digits, `_` and `.`, starting with a letter, at most 64 characters.
    /// The shape of `M_FORBIDDEN` and of a namespaced code; anything else is no code at all.
    package static func validErrorCode(_ errorCode: String) -> String? {
        guard (1...64).contains(errorCode.utf8.count),
              let first = errorCode.utf8.first, (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first),
              errorCode.utf8.allSatisfy({ byte in
                  (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                      || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
              }) else {
            return nil
        }
        return errorCode
    }
}

/// A property's value: text from a closed set, or a number.
public nonisolated enum ElementCallAnalyticsValue: Sendable, Equatable {
    case string(String)
    case int(Int)
}

private nonisolated extension Duration {
    /// Truncated, never rounded up past what elapsed.
    var wholeMilliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
