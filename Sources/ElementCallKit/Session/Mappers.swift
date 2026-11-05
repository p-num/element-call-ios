//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc

nonisolated extension MatrixRTCStreamKind {
    init(_ kind: FfiStreamKind) {
        switch kind {
        case .microphone: self = .microphone
        case .camera: self = .camera
        case .screenShare: self = .screenShare
        case .screenShareAudio: self = .screenShareAudio
        case .data: self = .data
        }
    }
    
    var ffi: FfiStreamKind {
        switch self {
        case .microphone: .microphone
        case .camera: .camera
        case .screenShare: .screenShare
        case .screenShareAudio: .screenShareAudio
        case .data: .data
        }
    }
}

nonisolated extension MatrixRTCMembershipFormat {
    var ffi: FfiMembershipFormat {
        switch self {
        case .msc: .msc
        case .roomState: .roomState
        }
    }
}

nonisolated extension MatrixRTCCallKind {
    var ffi: FfiCallKind {
        switch self {
        case .group(let notify):
            .group(notify: notify.map { FfiGroupNotify(intent: $0.rawValue, lifetimeMs: nil, mentionUserIds: [], mentionRoom: true) })
        case .direct(let ring):
            .direct(ring: ring.map { FfiRingConfig(lifetimeMs: nil, intent: $0.rawValue) })
        }
    }
}

nonisolated extension MatrixRTCCallStatus {
    init(_ status: FfiCallStatus) {
        switch status {
        case .connecting:
            self = .connecting
        case .calling(let callee, let ring, let media):
            self = .calling(callee: callee, ring: .init(ring), media: .init(media))
        case .connected(let since, let degraded):
            self = .connected(since: Date(milliseconds: since), isDegraded: degraded)
        case .ended(let reason):
            self = .ended(.init(reason))
        }
    }
}

nonisolated extension MatrixRTCRingPhase {
    init(_ phase: FfiRingPhase) {
        switch phase {
        case .sending:
            self = .sending
        case .ringing(let sentAt, let lifetime):
            self = .ringing(sentAt: Date(milliseconds: sentAt), lifetime: .milliseconds(lifetime))
        }
    }
}

nonisolated extension MatrixRTCMediaPhase {
    init(_ phase: FfiMediaPhase) {
        switch phase {
        case .connecting: self = .connecting
        case .connected(let degraded): self = .connected(isDegraded: degraded)
        }
    }
}

nonisolated extension MatrixRTCEndReason {
    init(_ end: FfiCallEnd) {
        switch end {
        case .left: self = .left
        case .declined: self = .declined
        case .unanswered: self = .unanswered
        case .ringNotSent: self = .ringNotSent
        case .othersLeft: self = .othersLeft
        case .empty: self = .empty
        case .slotClosed: self = .slotClosed
        case .connectionClosed(let reason, let message): self = .connectionClosed(reason: .init(reason), message: message)
        }
    }
}

nonisolated extension MatrixRTCConnectionLossReason {
    init(_ reason: FfiConnectionLossReason) {
        switch reason {
        case .budget: self = .budget
        case .refused: self = .refused
        case .neverConnected: self = .neverConnected
        }
    }
    
    var ffi: FfiConnectionLossReason {
        switch self {
        case .budget: .budget
        case .refused: .refused
        case .neverConnected: .neverConnected
        }
    }
}

nonisolated extension MatrixRTCSignallingHealth {
    init(_ health: FfiSignallingHealth) {
        switch health {
        case .reachable: self = .reachable
        case .unreachable(let since): self = .unreachable(since: Date(milliseconds: since))
        }
    }
    
    var ffi: FfiSignallingHealth {
        switch self {
        case .reachable: .reachable
        case .unreachable(let since): .unreachable(sinceMs: since.millisecondsSince1970)
        }
    }
}

nonisolated extension MatrixRTCInterruptions {
    init(_ record: FfiInterruptions) {
        self.init(signalling: .init(record.signalling),
                  isOwnMembershipLapsed: record.ownMembershipLapsed,
                  ownMedia: .init(record.ownMedia),
                  membersReconnecting: record.membersReconnecting,
                  membersUnreachable: record.membersUnreachable,
                  unableToDecrypt: record.unableToDecrypt,
                  unmappable: record.unmappable)
    }
    
    var ffi: FfiInterruptions {
        FfiInterruptions(signalling: signalling.ffi,
                         ownMembershipLapsed: isOwnMembershipLapsed,
                         ownMedia: ownMedia.ffi,
                         membersReconnecting: membersReconnecting,
                         membersUnreachable: membersUnreachable,
                         unableToDecrypt: unableToDecrypt,
                         unmappable: unmappable)
    }
}

nonisolated extension MatrixRTCConnectionState {
    init(_ state: FfiConnectionState) {
        switch state {
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reconnecting: self = .reconnecting
        case .unreachable: self = .unreachable
        }
    }
    
    var ffi: FfiConnectionState {
        switch self {
        case .connecting: .connecting
        case .connected: .connected
        case .reconnecting: .reconnecting
        case .unreachable: .unreachable
        }
    }
}

nonisolated extension MatrixRTCUnableToDecrypt {
    init(_ reason: FfiUnableToDecrypt) {
        switch reason {
        case .missingKey: self = .missingKey
        case .badKey: self = .badKey
        case .notEncrypted: self = .notEncrypted
        }
    }
}

private nonisolated extension Date {
    init(milliseconds: UInt64) {
        self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

nonisolated extension MatrixRTCMembership {
    init(_ membership: JoinedMembership) {
        self.init(memberID: membership.memberId,
                  userID: membership.sender,
                  deviceID: membership.senderDeviceId,
                  application: membership.application)
    }
}

nonisolated extension MatrixRTCParticipant {
    init(_ participant: FfiParticipant) {
        self.init(memberID: participant.memberId,
                  userID: participant.userId,
                  deviceID: participant.deviceId,
                  isLocal: participant.isLocal,
                  connection: .init(participant.connection),
                  unableToDecrypt: participant.unableToDecrypt.map(MatrixRTCUnableToDecrypt.init),
                  streams: participant.streams.map { .init(kind: .init($0.kind), isMuted: $0.muted) },
                  handRaisedAt: participant.handRaisedAtMs.map(Date.init(milliseconds:)))
    }
}

nonisolated extension MatrixRTCTileKind {
    init(_ kind: FfiTileKind) {
        switch kind {
        case .person: self = .person
        case .screenShare: self = .screenShare
        }
    }
    
    var ffi: FfiTileKind {
        switch self {
        case .person: .person
        case .screenShare: .screenShare
        }
    }
}

nonisolated extension MatrixRTCTileID {
    init(_ id: FfiTileId) {
        self.init(memberID: id.memberId, kind: .init(id.kind))
    }
}

nonisolated extension MatrixRTCTile {
    /// `isLocal` is ours to decide: the bindings' tile has no such field, because our own tile only
    /// ever arrives on the local-state surface and is never in the ranked list. Comparing the member
    /// rather than trusting the surface keeps the two answers from disagreeing.
    init(_ tile: FfiCallTile, localMemberID: String) {
        self.init(id: MatrixRTCTileID(memberID: tile.memberId, kind: .init(tile.kind)),
                  userID: tile.userId,
                  deviceID: tile.deviceId,
                  isLocal: tile.memberId == localMemberID,
                  isHero: tile.hero,
                  hasVideo: tile.hasVideo,
                  isMicrophoneMuted: tile.microphoneMuted,
                  isSpeaking: tile.speaking,
                  handRaisedAt: tile.handRaisedAtMs.map(Date.init(milliseconds:)),
                  handRaisedPosition: tile.handRaisedPosition.map(Int.init),
                  connection: .init(tile.connection),
                  unableToDecrypt: tile.unableToDecrypt.map(MatrixRTCUnableToDecrypt.init))
    }
}

nonisolated extension MatrixRTCTileRoster {
    init(_ roster: FfiTileRoster, localMemberID: String) {
        // Keyed by identity on the way in, so nothing downstream is tempted to join by position.
        // The two lists are the same length only while the detail window is the default one.
        var detail = [MatrixRTCTileID: MatrixRTCTile](minimumCapacity: roster.detail.count)
        for tile in roster.detail {
            let mapped = MatrixRTCTile(tile, localMemberID: localMemberID)
            detail[mapped.id] = mapped
        }
        self.init(order: roster.order.map { MatrixRTCTileRef(id: .init($0.id), userID: $0.userId, isHero: $0.hero) },
                  detail: detail)
    }
}

nonisolated extension MatrixRTCLocalState {
    init(_ state: FfiLocalState, localMemberID: String) {
        self.init(tile: MatrixRTCTile(state.tile, localMemberID: localMemberID),
                  isScreenSharing: state.isScreenSharing)
    }
}

nonisolated extension MatrixRTCReceiveStats {
    init(_ stats: FfiReceiveStats) {
        self.init(packetsReceived: stats.packetsReceived,
                  packetsLost: stats.packetsLost,
                  bytesReceived: stats.bytesReceived,
                  jitter: stats.jitter,
                  framesDecoded: stats.framesDecoded,
                  framesDropped: stats.framesDropped,
                  totalSamplesReceived: stats.totalSamplesReceived,
                  concealedSamples: stats.concealedSamples)
    }
}

nonisolated extension MatrixRTCFrameEncryptionState {
    init(_ state: FfiFrameEncryptionState) {
        switch state {
        case .ok: self = .ok
        case .missingKey: self = .missingKey
        case .decryptionFailed: self = .decryptionFailed
        case .encryptionFailed: self = .encryptionFailed
        case .internalError: self = .internalError
        }
    }
}

nonisolated extension MatrixRTCCallEvent {
    /// Nil for what is not surfaced.
    init?(_ event: FfiCallEvent) {
        switch event {
        case .participantJoined(let memberID, let userID, let participantCount):
            self = .participantJoined(memberID: memberID, userID: userID, participantCount: Int(participantCount))
        case .participantLeft(let memberID, let participantCount):
            self = .participantLeft(memberID: memberID, participantCount: Int(participantCount))
        case .streamStarted(let memberID, let kind):
            self = .streamStarted(memberID: memberID, kind: .init(kind))
        case .streamStopped(let memberID, let kind):
            self = .streamStopped(memberID: memberID, kind: .init(kind))
        case .streamMuted(let memberID, let kind):
            self = .streamMuted(memberID: memberID, kind: .init(kind))
        case .streamUnmuted(let memberID, let kind):
            self = .streamUnmuted(memberID: memberID, kind: .init(kind))
        case .keyImported(let memberID, let keyIndex):
            self = .keyImported(memberID: memberID, keyIndex: keyIndex)
        case .frameEncryptionState(let memberID, let state, _):
            self = .frameEncryptionState(memberID: memberID, state: .init(state))
        case .keyDiscarded(let memberID, let keyIndex, let senderUserID, let senderDeviceID, let reason):
            self = .keyDiscarded(memberID: memberID,
                                 reason: "index \(keyIndex.map(String.init) ?? "?") from \(senderUserID ?? "?")/\(senderDeviceID ?? "?"): \(reason)")
        case .handRaised(let memberID, let raisedAt):
            self = .handRaised(memberID: memberID, raisedAt: Date(milliseconds: raisedAt))
        case .handLowered(let memberID):
            self = .handLowered(memberID: memberID)
        case .reaction(let memberID, let emoji, let name, let sound):
            self = .reaction(memberID: memberID, emoji: emoji, name: name, sound: sound)
        case .unknownParticipant(let identity):
            // The transport knows an identity the membership projection doesn't (yet). What the UI
            // shows for it comes from the interruptions record, which lists it for as long as it
            // stays unmapped; this one-shot is diagnostics.
            MatrixRTCLog.debug("Unknown participant on the transport: \(identity)")
            return nil
        case .ownMediaConnectionState(let degraded):
            self = .ownMediaConnectionDegraded(degraded)
        }
    }
}
