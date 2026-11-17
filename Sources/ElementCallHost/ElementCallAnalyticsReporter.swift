//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// One state machine per join attempt, driven by the controller at the moments the 044 rules name
/// and at no others (R20). It owns no task and no timer.
///
/// Every method is idempotent per attempt: once the outcome has gone out nothing makes a second one,
/// and once the attempt is finished every later call is a no-op. The controller can reach its end
/// path twice for one call (a failure, then a status `.ended` already queued), so this is what holds
/// R7, R11 and R14, not the call sites.
///
/// It runs whether or not the host gave a receiver; an event with nowhere to go is dropped on the
/// spot, never kept (R2).
@MainActor
final class ElementCallAnalyticsReporter {
    typealias Event = ElementCallAnalyticsEvent
    typealias Failure = ElementCallAnalyticsFailure
    
    /// How a join that never connected stopped, for the controller's failure funnel. Required there,
    /// with no default, so every failure site classifies itself (R16).
    enum JoinFailure: Equatable {
        case failed(Failure.Cause, Failure.Stage, Failure.Step, errorCode: String? = nil)
        /// Not a failure (R10).
        case permissionRefused
        
        /// The table in the iOS plan's §5 for an error the join threw (R16, R21, R23). `unknown`
        /// wherever the core does not say which step failed.
        static func forJoinError(_ error: any Error) -> JoinFailure {
            switch error {
            case MatrixRTCError.joinTimedOut:
                .failed(.joinTimedOut, .homeserver, .unknown)
            case MatrixRTCError.joinRefused(let errorCode, _):
                .failed(.joinRefused, .homeserver, .unknown, errorCode: errorCode)
            case MatrixRTCError.slotClosed:
                // The core's slot check sits in the membership send, before anything goes out.
                .failed(.slotClosed, .homeserver, .membership)
            case MatrixRTCError.noLiveKitTransport:
                .failed(.noMediaServer, .homeserver, .transportDiscovery)
            case MatrixRTCError.tokenEndpointUnsupported:
                .failed(.tokenEndpointUnsupported, .media, .mediaToken)
            default:
                .failed(.other, .homeserver, .unknown)
            }
        }
    }
    
    private struct Attempt {
        /// A random (v4) UUID, derived from nothing about the user, the room or the device (R19).
        let id = UUID().uuidString
        /// Fixed at the attempt, the join's own DM decision (R25, C10).
        let callKind: Event.CallKind
        /// R8's first half: our own media up, ringing or not.
        var isMediaConnected = false
        /// R8's second half: our microphone published, which finishes the join's setting up.
        var isMicrophonePublished = false
        /// Started at R8's moment, on the controller's clock (R11).
        var connectedFor: (() -> Duration)?
        /// R26, ourselves included. Meaningful once connected.
        var participantsMax = 1
        var isOutcomeReported = false
        
        var isConnected: Bool {
            connectedFor != nil
        }
    }
    
    private let analytics: (any ElementCallAnalyticsProtocol)?
    private let logger: (any ElementCallLoggingProtocol)?
    /// The duration's clock; the controller keeps it its own.
    var clock: any Clock<Duration> = ContinuousClock()
    /// Nil between attempts, and once the attempt has finished: ended (R11) or stopped before it
    /// connected.
    private var attempt: Attempt?
    
    init(analytics: (any ElementCallAnalyticsProtocol)?, logger: (any ElementCallLoggingProtocol)?) {
        self.analytics = analytics
        self.logger = logger
    }
    
    // MARK: - Moments
    
    /// A start or join was accepted, before anything is joined (R6).
    func attempted(callKind: Event.CallKind) {
        let attempt = Attempt(callKind: callKind)
        self.attempt = attempt
        track(.callJoinAttempted(attemptID: attempt.id, callKind: callKind))
    }
    
    /// Our own media is up: a status of `.calling` with media connected, or `.connected`. Either
    /// order with ``microphonePublished(memberCount:)``; the second connects (C5).
    /// `memberCount` is the core's membership count, ourselves included, seeding R26.
    func mediaConnected(memberCount: Int) {
        guard attempt != nil else { return }
        attempt?.isMediaConnected = true
        connectIfReady(memberCount: memberCount)
    }
    
    /// Our microphone published, muted or not. See ``mediaConnected(memberCount:)``.
    func microphonePublished(memberCount: Int) {
        guard attempt != nil else { return }
        attempt?.isMicrophonePublished = true
        connectIfReady(memberCount: memberCount)
    }
    
    /// The call's size after someone joined or left, ourselves included. Only raises the maximum,
    /// and only between connected and the end (R26).
    func participants(_ count: Int) {
        guard let attempt, attempt.isConnected else { return }
        self.attempt?.participantsMax = max(attempt.participantsMax, count)
    }
    
    /// The microphone is refused, before anything was joined (R10).
    func permissionRefused() {
        guard let attempt, !attempt.isOutcomeReported else { return }
        outcome(.permissionRefused)
        self.attempt = nil
    }
    
    /// The user or the host ended the call: `abandoned` with no reason before connected (R9, R24),
    /// a `left` end after (R11).
    func hungUp() {
        guard let attempt else { return }
        if attempt.isConnected {
            end(.left)
        } else if !attempt.isOutcomeReported {
            outcome(.abandoned(endReason: nil))
            self.attempt = nil
        }
    }
    
    /// A failure the controller caught. Before connected it is a join failure: the outcome `failed`,
    /// then its `CallFailure` (C4). Every failure the controller catches today comes before
    /// connected, since connected waits for the microphone (C6).
    func failed(_ cause: Failure.Cause, stage: Failure.Stage, step: Failure.Step, errorCode: String? = nil) {
        guard let attempt else { return }
        if attempt.isConnected {
            // Not reached today; kept honest rather than reported as a join failure. The end that
            // follows is reported by whatever ends the call.
            track(.callFailure(attemptID: attempt.id, callKind: attempt.callKind,
                               failure: Failure(cause: cause, phase: .inCall, errorCode: errorCode)))
            return
        }
        guard !attempt.isOutcomeReported else { return }
        if cause == .joinRefused, let errorCode, Failure.validErrorCode(errorCode) == nil {
            log(.warning, "the join's errcode is not a Matrix error code, reporting none")
        }
        outcome(.failed)
        track(.callFailure(attemptID: attempt.id, callKind: attempt.callKind,
                           failure: Failure(cause: cause, phase: .joining(stage, step), errorCode: errorCode)))
        self.attempt = nil
    }
    
    /// One of ``failed(_:stage:step:errorCode:)`` or ``permissionRefused()``.
    func joinFailed(_ failure: JoinFailure) {
        switch failure {
        case .failed(let cause, let stage, let step, let errorCode):
            failed(cause, stage: stage, step: step, errorCode: errorCode)
        case .permissionRefused:
            permissionRefused()
        }
    }
    
    /// The call ended, by the core or by our own leave (C8).
    func ended(_ reason: MatrixRTCEndReason) {
        guard let attempt else { return }
        if attempt.isConnected {
            if case .connectionClosed(let loss, _) = reason {
                track(.callFailure(attemptID: attempt.id, callKind: attempt.callKind,
                                   failure: Failure(cause: Self.cause(for: loss), phase: .inCall)))
            }
            end(Self.endReason(for: reason))
            return
        }
        guard !attempt.isOutcomeReported else { return }
        switch reason {
        case .connectionClosed(let loss, _):
            // Refused or never reached before our media was up: a join failure, whichever path it
            // came by (R15).
            let step: Failure.Step = loss == .tokenEndpointUnsupported ? .mediaToken : .unknown
            failed(Self.cause(for: loss), stage: .media, step: step)
        case .left:
            // The core leaves plainly only for our own leave or close: our side ended it (C8).
            outcome(.abandoned(endReason: nil))
            self.attempt = nil
        default:
            outcome(.abandoned(endReason: Self.endReason(for: reason)))
            self.attempt = nil
        }
    }
    
    /// Tests only: whether the attempt under way has published its microphone, which a test waits on
    /// rather than on a fixed sleep.
    var isMicrophonePublished: Bool {
        attempt?.isMicrophonePublished == true
    }
    
    /// Tests only: the attempt's `participantsMax` so far, nil outside a connected attempt.
    var participantsMax: Int? {
        attempt?.isConnected == true ? attempt?.participantsMax : nil
    }
    
    // MARK: - Mapping
    
    static func cause(for loss: MatrixRTCConnectionLossReason) -> Failure.Cause {
        switch loss {
        case .budget: .connectionLostBudget
        case .refused: .connectionLostRefused
        case .neverConnected: .connectionLostNeverConnected
        case .tokenEndpointUnsupported: .tokenEndpointUnsupported
        }
    }
    
    /// One to one (R12).
    static func endReason(for reason: MatrixRTCEndReason) -> Event.EndReason {
        switch reason {
        case .left: .left
        case .declined: .declined
        case .unanswered: .unanswered
        case .ringNotSent: .ringNotSent
        case .othersLeft: .othersLeft
        case .empty: .empty
        case .slotClosed: .slotClosed
        case .connectionClosed: .connectionLost
        }
    }
    
    // MARK: - Private
    
    private func connectIfReady(memberCount: Int) {
        guard let attempt, !attempt.isOutcomeReported,
              attempt.isMediaConnected, attempt.isMicrophonePublished else {
            return
        }
        let clock = clock
        let connectedFor = stopwatch(clock)
        self.attempt?.connectedFor = connectedFor
        // The participant events never cover the members already there when we arrived.
        self.attempt?.participantsMax = max(1, memberCount)
        outcome(.connected)
    }
    
    private func outcome(_ outcome: Event.Outcome) {
        guard let attempt else { return }
        self.attempt?.isOutcomeReported = true
        track(.callJoinOutcome(attemptID: attempt.id, callKind: attempt.callKind, outcome: outcome))
    }
    
    private func end(_ reason: Event.EndReason) {
        guard let attempt, let connectedFor = attempt.connectedFor else { return }
        self.attempt = nil
        track(.callParticipationEnded(attemptID: attempt.id, callKind: attempt.callKind, endReason: reason,
                                      duration: connectedFor(), participantsMax: attempt.participantsMax))
    }
    
    private func track(_ event: Event) {
        analytics?.track(event)
    }
    
    private func log(_ level: ElementCallLogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        logger?.log(level, message, file: file, line: line)
    }
}
