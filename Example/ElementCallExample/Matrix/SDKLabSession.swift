//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCall
import Foundation
import MatrixRustSDK

/// A logged-in Rust SDK session for the lab (`element-call-feature-hq/harness/lab.md`): a password
/// login, the sync running, and the one room the call is in. The only place the example app makes a
/// `Client`; the reference backend over it is `SDKMatrixBackend`, unchanged.
///
/// The session is kept, store and all, until logged out: rejoining after a call, or after a
/// relaunch, is the same device, with no new device for the others to discover and no rescan.
/// Scanning the same account's code again reuses it; another account's code logs this one out first.
final nonisolated class SDKLabSession: Sendable {
    enum Error: Swift.Error, LocalizedError {
        case roomNotJoined(String)
        case noSession
        case recoveryKeyMissing(String)
        case recoveryKeyRejected(String)
        
        var errorDescription: String? {
            switch self {
            case .roomNotJoined(let roomID): "the account is not in \(roomID), or the sync has not delivered it"
            case .noSession: "the client has no user or device"
            case .recoveryKeyMissing(let user):
                "\(user) has recovery set up but the code carries no recovery key; rescan once the lab page shows one (it is never reset from here)"
            case .recoveryKeyRejected(let reason):
                "the code's recovery key does not open the account's secret storage (\(reason)); rerun `lab identities` on the laptop"
            }
        }
    }
    
    /// What is kept between launches to restore the session: where it logged in, and the SDK's
    /// session. The store it goes with is `storeDirectory`.
    struct Saved: Codable, Equatable {
        let homeserver: String
        let user: String
        let roomID: String
        let accessToken: String
        let refreshToken: String?
        let userID: String
        let deviceID: String
        let homeserverURL: String
        let oauthData: String?
        /// The lab's name for the call format (`current` or `state`); absent in a session kept
        /// before the lab had formats, which was room state.
        let format: String?
        
        var membershipFormat: MatrixRTCMembershipFormat {
            MatrixRTCMembershipFormat(labName: format)
        }
        
        /// The SDK's session, to restore.
        var session: Session {
            Session(accessToken: accessToken, refreshToken: refreshToken, userId: userID, deviceId: deviceID,
                    homeserverUrl: homeserverURL, oauthData: oauthData, slidingSyncVersion: .native)
        }
        
        func isAccount(homeserver: String, user: String) -> Bool {
            self.homeserver == homeserver && self.user == user
        }
        
        private static let defaultsKey = "lab.session"
        
        static func load() -> Saved? {
            UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        }
        
        func store() {
            UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
        }
        
        static func clear() {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            try? FileManager.default.removeItem(at: storeDirectory)
        }
    }
    
    /// The one session's store. A single directory: there is never more than one lab session.
    private static let storeDirectory = URL.applicationSupportDirectory.appending(path: "lab")
    
    let client: Client
    let backend: SDKMatrixBackend
    let room: Room
    let format: MatrixRTCMembershipFormat
    /// Held so the sync keeps running for as long as the session lives.
    private let syncService: SyncService
    
    private init(client: Client, backend: SDKMatrixBackend, room: Room, format: MatrixRTCMembershipFormat, syncService: SyncService) {
        self.client = client
        self.backend = backend
        self.room = room
        self.format = format
        self.syncService = syncService
    }
    
    /// Logs in for a scanned code. The kept session is reused when the code is for the same
    /// account (with the code's room, which a lab reset changes) and its token still works; a
    /// session for another account is logged out first.
    static func login(homeserver: String,
                      username: String,
                      password: String,
                      roomID: String,
                      recoveryKey: String?,
                      format: MatrixRTCMembershipFormat,
                      logger: (any ElementCallLoggingProtocol)?) async throws -> SDKLabSession {
        if let saved = Saved.load() {
            if saved.isAccount(homeserver: homeserver, user: username), await isValid(saved) {
                logger?.log(.info, "lab: reusing the kept session \(saved.userID) / \(saved.deviceID)")
                return try await restore(saved, roomID: roomID, format: format, logger: logger)
            }
            logger?.log(.info, "lab: the kept session \(saved.userID) is for another account or no longer valid; logging it out")
            await logOut(saved, logger: logger)
        }
        Saved.clear()
        
        logger?.log(.info, "lab: logging in as \(username) on \(homeserver)")
        let client = try await makeClient(homeserver: homeserver)
        try await client.login(username: username, password: password, initialDeviceName: "Element Call lab", deviceId: nil)
        let session = try client.session()
        Saved(homeserver: homeserver, user: username, roomID: roomID,
              accessToken: session.accessToken, refreshToken: session.refreshToken,
              userID: session.userId, deviceID: session.deviceId, homeserverURL: session.homeserverUrl,
              oauthData: session.oauthData, format: format.labName).store()
        
        let (syncService, room) = try await startSync(client: client, roomID: roomID)
        try await adoptIdentity(client: client, password: password, recoveryKey: recoveryKey, logger: logger)
        await sayHi(in: room, logger: logger)
        return try make(client: client, room: room, format: format, syncService: syncService, logger: logger)
    }
    
    /// The kept session, for rejoining after a relaunch without a code.
    static func restoreSaved(logger: (any ElementCallLoggingProtocol)?) async throws -> SDKLabSession {
        guard let saved = Saved.load() else { throw Error.noSession }
        return try await restore(saved, roomID: saved.roomID, format: saved.membershipFormat, logger: logger)
    }
    
    /// The account, room and format this session is for, to tell whether a scanned code can reuse it.
    func isFor(homeserver: String, user: String, roomID: String, format: MatrixRTCMembershipFormat) -> Bool {
        Saved.load()?.isAccount(homeserver: homeserver, user: user) == true && room.id() == roomID && self.format == format
    }
    
    /// Stops the sync, so another client can take the store.
    func stop() async {
        await syncService.stop()
    }
    
    /// Logs this device out on the server and forgets it, store and all.
    func logOut(logger: (any ElementCallLoggingProtocol)?) async {
        await syncService.stop()
        do {
            try await client.logout()
        } catch {
            logger?.log(.warning, "lab: logging out on the server failed (\(error.localizedDescription)); forgetting the session anyway")
        }
        Saved.clear()
        logger?.log(.info, "lab: logged out")
    }
    
    /// The kept session logged out without a live client: restored just to log it out. A token
    /// the server no longer knows (a lab reset) has nothing to log out, and is only forgotten.
    static func logOut(_ saved: Saved, logger: (any ElementCallLoggingProtocol)?) async {
        if await isValid(saved), let client = try? await makeClient(homeserver: saved.homeserver) {
            try? await client.restoreSession(session: saved.session)
            do {
                try await client.logout()
            } catch {
                logger?.log(.warning, "lab: logging \(saved.userID) out on the server failed (\(error.localizedDescription))")
            }
        }
        Saved.clear()
    }
    
    private static func restore(_ saved: Saved, roomID: String, format: MatrixRTCMembershipFormat,
                                logger: (any ElementCallLoggingProtocol)?) async throws -> SDKLabSession {
        let client = try await makeClient(homeserver: saved.homeserver)
        try await client.restoreSession(session: saved.session)
        if roomID != saved.roomID || format != saved.membershipFormat {
            Saved(homeserver: saved.homeserver, user: saved.user, roomID: roomID,
                  accessToken: saved.accessToken, refreshToken: saved.refreshToken,
                  userID: saved.userID, deviceID: saved.deviceID, homeserverURL: saved.homeserverURL,
                  oauthData: saved.oauthData, format: format.labName).store()
        }
        let (syncService, room) = try await startSync(client: client, roomID: roomID)
        return try make(client: client, room: room, format: format, syncService: syncService, logger: logger)
    }
    
    /// Whether the server still knows the kept token: `whoami` answers for the same device. A
    /// lab reset wipes the homeserver, and a restored client with a dead token would only find out
    /// in its sync. Any other failure (the laptop unreachable) is not an answer, so it is kept.
    private static func isValid(_ saved: Saved) async -> Bool {
        guard let url = URL(string: saved.homeserverURL)?.appending(path: "_matrix/client/v3/account/whoami") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(saved.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return true }
        guard status == 200 else { return false }
        let deviceID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["device_id"] as? String
        return deviceID == saved.deviceID
    }
    
    private static func makeClient(homeserver: String) async throws -> Client {
        let base = storeDirectory
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try await ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sessionPaths(dataPath: base.appending(path: "data").path(percentEncoded: false),
                          cachePath: base.appending(path: "cache").path(percentEncoded: false))
            .slidingSyncVersionBuilder(versionBuilder: .native)
            // A member's key is only accepted from a device its owner's identity signs (the
            // backend's "confirmed sender"), so the first device of an account sets the identity up.
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .build()
    }
    
    /// Starts the sync and waits for the room, which the seed script has every account in.
    private static func startSync(client: Client, roomID: String) async throws -> (SyncService, Room) {
        // Offline mode: on a network error the sync goes `.offline` and keeps retrying, instead of
        // ending in `.error` and staying there. The call then outlives a homeserver outage.
        let syncService = try await client.syncService().withOfflineMode().finish()
        await syncService.start()
        // The room list asks for one timeline event per room, so after a gap only the latest arrives
        // and a hand raised in between is lost. A room subscription asks for 20.
        try await syncService.roomListService().setRoomSubscriptions(roomIds: [roomID])
        for _ in 0..<60 {
            if let room = try? client.getRoom(roomId: roomID) {
                return (syncService, room)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        await syncService.stop()
        throw Error.roomNotJoined(roomID)
    }
    
    private static func make(client: Client, room: Room, format: MatrixRTCMembershipFormat, syncService: SyncService,
                             logger: (any ElementCallLoggingProtocol)?) throws -> SDKLabSession {
        guard let backend = SDKMatrixBackend(client: client, logger: logger) else { throw Error.noSession }
        logger?.log(.info, "lab: logged in as \(backend.userID) / \(backend.deviceID), room \(room.id()) synced, call format \(format)")
        return SDKLabSession(client: client, backend: backend, room: room, format: format, syncService: syncService)
    }
    
    /// A fresh device joining a state-membership call at once races its own key downloads: a
    /// member's media key can arrive from a device we have not fetched yet, and is refused. An
    /// encrypted "hi" first makes the SDK fetch every member's devices and share a room key with
    /// them, so both sides know each other before the call. Best effort: the join goes on without it.
    private static func sayHi(in room: Room, logger: (any ElementCallLoggingProtocol)?) async {
        do {
            _ = try await room.sendRaw(eventType: "m.room.message", content: #"{"msgtype":"m.text","body":"hi"}"#)
            logger?.log(.info, "lab: said hi in the room, so the members' devices are known before the call")
        } catch {
            logger?.log(.warning, "lab: could not say hi (\(error.localizedDescription)); joining anyway")
        }
    }
    
    /// The host's side of 034 R11: the Matrix client tells the call when the homeserver is gone
    /// and when it is back, so the call shows the outage at once rather than at its own next send's
    /// 30 s timeout. Only the transitions are reported, never the sync merely starting (034 C3).
    /// The cancellable keeps the observer alive; drop or cancel it with the call.
    func observeConnectivity(_ report: @escaping @Sendable (Bool) -> Void) -> AnyCancellable {
        let handle = syncService.state(listener: SyncStateReporter(report: report))
        return AnyCancellable { handle.cancel() }
    }
    
    /// Every login is a new device, and an account scanned before already has a cross-signing
    /// identity this device is not part of, so the other members would refuse its media key. With
    /// the account's recovery key (the lab seeds one per account and puts it in the code) the
    /// device joins that identity. Without one, the identity is reset to this device only if the
    /// account never had recovery: an account with recovery is never reset from here, since that
    /// deletes its backup and leaves the lab's recovery key opening nothing.
    private static func adoptIdentity(client: Client, password: String, recoveryKey: String?,
                                      logger: (any ElementCallLoggingProtocol)?) async throws {
        let encryption = client.encryption()
        var state = encryption.verificationState()
        for _ in 0..<20 where state == .unknown {
            try await Task.sleep(for: .milliseconds(500))
            state = encryption.verificationState()
        }
        guard state == .unverified else {
            logger?.log(.info, "lab: this device is \(state) by its identity")
            return
        }
        if let recoveryKey {
            logger?.log(.info, "lab: joining the account's identity with its recovery key")
            do {
                try await encryption.recover(recoveryKey: recoveryKey)
            } catch {
                throw Error.recoveryKeyRejected(error.localizedDescription)
            }
            for _ in 0..<20 where encryption.verificationState() != .verified {
                try await Task.sleep(for: .milliseconds(500))
            }
            logger?.log(.info, "lab: after recovery this device is \(encryption.verificationState()) by its identity")
            return
        }
        var recovery = encryption.recoveryState()
        for _ in 0..<20 where recovery == .unknown {
            try await Task.sleep(for: .milliseconds(500))
            recovery = encryption.recoveryState()
        }
        guard recovery == .disabled else {
            throw Error.recoveryKeyMissing((try? client.userId()) ?? "the account")
        }
        guard let handle = try await encryption.resetIdentity() else {
            logger?.log(.warning, "lab: the identity could not be reset; the others may refuse our key")
            return
        }
        logger?.log(.info, "lab: resetting the cross-signing identity to this device")
        switch handle.authType() {
        case .uiaa(let info):
            // The full id: the identifier is parsed as one, and a bare localpart is "missing sigil".
            let details = try AuthDataPasswordDetails(identifier: client.userId(), password: password, session: info.session)
            try await handle.reset(auth: .password(passwordDetails: details))
        case .oAuth:
            logger?.log(.warning, "lab: the homeserver wants OAuth for the reset, which the lab does not drive")
            await handle.cancel()
        }
    }
}

/// Maps the sync service's state to the two reports the call takes: offline on `.offline` or
/// `.error`, online on the `.running` that follows one. Anything else is not a transition.
private final class SyncStateReporter: SyncServiceStateObserver, @unchecked Sendable {
    private let report: @Sendable (Bool) -> Void
    private let lock = NSLock()
    private var isOffline = false
    
    init(report: @escaping @Sendable (Bool) -> Void) {
        self.report = report
    }
    
    func onUpdate(state: SyncServiceState) {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .offline, .error:
            guard !isOffline else { return }
            isOffline = true
            report(false)
        case .running:
            guard isOffline else { return }
            isOffline = false
            report(true)
        case .idle, .terminated:
            break
        }
    }
}

/// The call package's room port over an SDK `Room`, for the lab: name, directness and members read
/// once on load. The lab's room does not change mid-call, so the publishers only carry the load.
final class SDKLabRoomContext: ElementCallRoomContextProtocol {
    let roomID: String
    private let room: Room
    private let name: CurrentValueSubject<String, Never>
    private let direct = CurrentValueSubject<Bool, Never>(false)
    private let profiles = CurrentValueSubject<[String: ElementCallMemberProfile], Never>([:])
    
    init(room: Room) {
        self.room = room
        roomID = room.id()
        name = CurrentValueSubject(room.rawName() ?? room.id())
    }
    
    /// Reads what the port serves from the SDK. Called once, after the sync has the room.
    func load() async {
        if let displayName = room.displayName() {
            name.send(displayName)
        }
        await direct.send(room.isDirect())
        guard let iterator = try? await room.members() else { return }
        var members = [String: ElementCallMemberProfile]()
        while let chunk = iterator.nextChunk(chunkSize: 100), !chunk.isEmpty {
            for member in chunk {
                members[member.userId] = ElementCallMemberProfile(userID: member.userId,
                                                                  displayName: member.displayName,
                                                                  avatarURL: member.avatarUrl.flatMap(URL.init(string:)))
            }
        }
        profiles.send(members)
    }
    
    var displayName: String {
        name.value
    }
    
    var displayNamePublisher: AnyPublisher<String, Never> {
        name.removeDuplicates().eraseToAnyPublisher()
    }
    
    var isDirect: Bool {
        direct.value
    }
    
    var isDirectPublisher: AnyPublisher<Bool, Never> {
        direct.removeDuplicates().eraseToAnyPublisher()
    }
    
    var memberProfiles: [String: ElementCallMemberProfile] {
        profiles.value
    }
    
    var memberProfilesPublisher: AnyPublisher<[String: ElementCallMemberProfile], Never> {
        profiles.eraseToAnyPublisher()
    }
}

extension MatrixRTCMembershipFormat {
    /// The lab's name for a format, as the page writes it in the code: `current` or `state`, room
    /// state when absent.
    init(labName: String?) {
        self = labName == "current" ? .msc : .roomState
    }
    
    var labName: String {
        self == .msc ? "current" : "state"
    }
    
    /// How the Lab tab names the format, the same words as the lab page's banner.
    var labLabel: String {
        switch self {
        case .msc: "Current (sticky events)"
        case .roomState: "Room state (legacy)"
        }
    }
}
