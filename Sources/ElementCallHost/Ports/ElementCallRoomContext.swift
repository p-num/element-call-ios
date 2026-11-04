//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import Foundation

/// What we need to know about a member to put them on a tile.
public nonisolated struct ElementCallMemberProfile: Sendable, Hashable {
    public let userID: String
    public let displayName: String?
    public let avatarURL: URL?
    
    public init(userID: String, displayName: String?, avatarURL: URL?) {
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// The room a call is happening in, supplied by the host for the duration of that call.
///
/// Each of these carries a current value as well as a stream of changes, because the call screen has
/// to draw a name on its first frame and a freshly opened room may not have one yet.
@MainActor
public protocol ElementCallRoomContextProtocol: AnyObject {
    var roomID: String { get }
    
    var displayName: String { get }
    var displayNamePublisher: AnyPublisher<String, Never> { get }
    
    var isDirect: Bool { get }
    var isDirectPublisher: AnyPublisher<Bool, Never> { get }
    
    /// User ID to profile. Sparse is fine: a tile falls back to the user ID.
    var memberProfiles: [String: ElementCallMemberProfile] { get }
    var memberProfilesPublisher: AnyPublisher<[String: ElementCallMemberProfile], Never> { get }
}

/// What a call was started for; fixed at start time. Whether the room is a direct chat and what it is
/// called are read from the ``ElementCallRoomContextProtocol`` instead, because both can change mid-call.
public nonisolated struct ElementCallData: Sendable, Equatable {
    public let isAudioCall: Bool
    /// Whether the user chose to call, as opposed to answering a ring or joining a call in progress.
    /// It decides whether a direct chat rings, so it comes from what the user did, never from the
    /// room having no call yet: answering a ring just after the caller gave up finds no call, and
    /// would ring them back rather than end (030 R33).
    public let isStartingCall: Bool
    
    public init(isAudioCall: Bool, isStartingCall: Bool) {
        self.isAudioCall = isAudioCall
        self.isStartingCall = isStartingCall
    }
}
