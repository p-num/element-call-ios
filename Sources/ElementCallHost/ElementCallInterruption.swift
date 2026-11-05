//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// One entry of the service interruptions list: what the user is told, grouped by whose side the
/// trouble is on (034 R13, R23, R29). Three at most, in this order, however many causes the core
/// reports; the tiles and the controls carry the detail.
public nonisolated enum ElementCallInterruption: Hashable, Sendable {
    /// Our homeserver does not answer. `isMembershipLapsed` once the others have dropped us (R17).
    ///
    /// Nothing says when someone is on the call whose membership has not reached us (R16's
    /// "unverifiable participant", the record's `unmappable`): they get no tile and, having no
    /// membership, none of our keys, so they can neither be seen nor hear us, and there is nothing
    /// for the user to do. They appear as an ordinary join when the server returns.
    case ownServer(isMembershipLapsed: Bool)
    /// Our own media server is being reconnected (R23).
    case ownMedia
    /// Our connection to somebody else's media is down (R29). Not a member we cannot decrypt: a
    /// missing key is that member's trouble, from causes we cannot tell apart from here, and only
    /// their tile says so (open question Q8).
    case othersMedia
    
    /// The core's causes mapped to entries (R38). `signalling` is passed apart from the record
    /// because it is the only cause that exists before media does (C4): a join made during an
    /// outage has a server entry and no record yet.
    ///
    /// These are the causes as they stand; what the screen shows is
    /// ``ElementCallController/interruptions``, which holds them back for a moment first.
    static func entries(signalling: MatrixRTCSignallingHealth,
                        record: MatrixRTCInterruptions?) -> [ElementCallInterruption] {
        var entries: [ElementCallInterruption] = []
        let record = record ?? .none
        // A lapse with signalling back is the moment before the republish lands, and still true.
        if !signalling.isReachable || record.isOwnMembershipLapsed {
            entries.append(.ownServer(isMembershipLapsed: record.isOwnMembershipLapsed))
        }
        // Connecting is the start of the call, which the screen already says (C11).
        if record.ownMedia == .reconnecting || record.ownMedia == .unreachable {
            entries.append(.ownMedia)
        }
        if !record.membersReconnecting.isEmpty || !record.membersUnreachable.isEmpty {
            entries.append(.othersMedia)
        }
        return entries
    }
}
