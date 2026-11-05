//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCall
import SwiftUI

/// The example app's stand-in for a host: it owns where the call is, which is the one job a host has
/// that the package deliberately does not do for it.
///
/// This exists because the harness used to be a *view* harness — it drew a call screen and nothing
/// else, so minimize and hang up did nothing and the handover a real host has to implement was
/// invisible here. There is now somewhere to go back to, so they mean something.
@MainActor
@Observable
final class ElementCallExampleHost {
    /// A connected fixture has no call behind it, so its screen runs on a context whose taps are
    /// applied to the view state; a connecting one has a real view model over a fake controller,
    /// which routes minimize and hang up through ``ElementCallController`` exactly as a shipping
    /// screen does. Keeping the two apart here means neither has to pretend to be the other.
    enum Presentation {
        case harness(ElementCallScreenContext)
        case live(ElementCallScreenViewModel)
        /// A real view model over a fake controller carrying a scripted call: the shipping screen,
        /// with the rosters coming from a scenario file rather than a backend.
        case scripted(ElementCallScreenViewModel, ElementCallExampleScenarioPlayback)
    }
    
    struct Session {
        /// Nil for a scenario.
        let fixture: ElementCallExampleFixture?
        let presentation: Presentation
        /// What the minimized bar is drawn from. For a `live` session it is the very controller the
        /// screen runs on; for a `harness` one there is no controller behind the screen at all, so
        /// this is one made to stand beside it.
        let controller: ElementCallController
    }
    
    private(set) var session: Session?
    /// A scenario that did not parse, named with its line, shown on the catalogue rather than
    /// printed: the package's lint forbids `print`, and a notice on screen is what a person and a
    /// failure screenshot can both read.
    private(set) var notice: String?
    /// The catalogue row last opened, so the list can come back to it: it is unmounted while a call
    /// is up, and a new list starts at the top.
    private(set) var lastOpenedRow: String?
    private var cancellables = Set<AnyCancellable>()
    /// Only for a harness session. A live one is asked, below.
    private var isHarnessMinimized = false
    /// The lab's logged-in SDK session, kept across calls until logged out: it owns the sync, and
    /// rejoining reuses it.
    private var lab: SDKLabSession?
    /// The lab account kept on this phone, for the lab tab; nil once logged out.
    private(set) var labAccount: String? = SDKLabSession.Saved.load()?.userID
    /// The kept session's call format, shown on the Lab tab.
    private(set) var labFormat: MatrixRTCMembershipFormat? = SDKLabSession.Saved.load()?.membershipFormat
    private var labTask: Task<Void, Never>?
    /// The sync-state observer behind the connectivity report; cancelled with the call.
    private var labConnectivity: AnyCancellable?
    
    /// A live session does not get a second copy of this: `isMaximized` is the controller's own bit
    /// and the same one `ElementCallView` unmounts its tiles on, so it is read rather than
    /// mirrored. A harness session has no controller behind its screen and cannot write
    /// `viewState` — that setter is fileprivate so only the package moves it — so the example owns
    /// the bit there. It costs nothing, because the call screen is unmounted while minimized and
    /// `viewState.isMaximized` is only consulted by a screen that is on the tree.
    var isMinimized: Bool {
        guard let session else { return false }
        switch session.presentation {
        case .harness: return isHarnessMinimized
        case .live, .scripted: return !session.controller.isMaximized
        }
    }
    
    func open(_ scenario: ElementCallExampleScenario) {
        lastOpenedRow = ElementCallExampleCatalogue.rowID(scenario)
        cancellables.removeAll()
        isHarnessMinimized = false
        notice = nil
        do {
            let playback = try ElementCallExampleScenarioPlayback(scenario: scenario.load())
            let controller = ElementCallController.fake(connection: .connected,
                                                        room: ElementCallFakeRoom(displayName: scenario.name),
                                                        connectedAt: .now,
                                                        call: playback.player.call)
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            let viewModel = ElementCallScreenViewModel(controller: controller)
            playback.attach(context: viewModel.context, controller: controller)
            session = Session(fixture: nil,
                              presentation: .scripted(viewModel, playback),
                              controller: controller)
            Task {
                await playback.start()
                playback.play()
            }
        } catch {
            notice = "Scenario \(scenario.name) failed to load: \(error)"
        }
    }
    
    func open(_ fixture: ElementCallExampleFixture) {
        lastOpenedRow = ElementCallExampleCatalogue.rowID(fixture)
        cancellables.removeAll()
        isHarnessMinimized = false
        
        switch fixture.kind {
        case .connected(var state):
            // A headset cannot be paired with the simulator, so the menu the audio button becomes
            // with one is reached by asking for it.
            if ProcessInfo.processInfo.arguments.contains("-headset") {
                state.audioOutputs = ElementCallPreviewFixtures.headsetAudioOutputs
                state.audioOutput = state.audioOutputs.first
            }
            // Built from the view state rather than defaulted, so the name on the bar and the name
            // in the top bar cannot drift apart. They agree today only by coincidence: the fake
            // room and `ElementCallPreviewFixtures.connected` happen to pick the same string.
            let room = ElementCallFakeRoom(displayName: state.roomName, isDirect: state.isDirect)
            let controller = makeController(connection: .connected, room: room)
            let context = ElementCallScreenContext.harness(state: state) { [weak self] action in
                self?.handle(action)
            }
            session = Session(fixture: fixture, presentation: .harness(context), controller: controller)
            isHarnessMinimized = fixture.opensMinimized
            
        case .ringing(let ringing):
            openRinging(ringing, fixture: fixture)
            
        case .played(let scenario):
            openPlayed(scenario, fixture: fixture)
            
        case .outage(let outage):
            openOutage(outage, fixture: fixture)
            
        case .reactions(let reactions):
            openReactions(reactions, fixture: fixture)
            
        case .connecting(let connection):
            let controller = makeController(connection: connection, room: ElementCallFakeRoom())
            // The real host contract, and the only place in this repository it is exercised: the
            // screen calls `requestMinimize()`, the fake has no Picture in Picture window to open
            // because binding one needs a live call, so the controller reports
            // `pictureInPictureUnavailable` and we put up the bar — which is exactly what the
            // package's documentation tells a host to do.
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            session = Session(fixture: fixture,
                              presentation: .live(ElementCallScreenViewModel(controller: controller)),
                              controller: controller)
        }
    }
    
    func restore() {
        guard let session else { return }
        switch session.presentation {
        case .harness: isHarnessMinimized = false
        case .live, .scripted: session.controller.restore()
        }
    }
    
    /// Deliberately does not tear down `cancellables`: for a live fixture this is called *from*
    /// that subscription's own delivery, and dropping the session is enough — the controller goes
    /// with it and takes its publisher along, leaving the subscription inert. `open` clears them.
    /// A real call in the lab (`element-call-feature-hq/harness/lab.md`): the one path in this app
    /// that logs in, over the reference `SDKMatrixBackend`, on the shipping screen. Nothing of the
    /// harness is involved: no fixture, no test pattern, the phone's own camera and microphone.
    /// The session in hand is reused for the same account and room; otherwise it is stopped and
    /// `SDKLabSession.login` decides between the kept session and a new login.
    func open(_ join: ElementCallExampleLabJoin) {
        startLab(notice: "Lab: logging in as \(join.user) on \(join.homeserver)…", certificateURL: join.certificateURL) { current, logger in
            if let current, current.isFor(homeserver: join.homeserver, user: join.user, roomID: join.roomID, format: join.format) {
                return current
            }
            await current?.stop()
            return try await SDKLabSession.login(homeserver: join.homeserver,
                                                 username: join.user,
                                                 password: join.password,
                                                 roomID: join.roomID,
                                                 recoveryKey: join.recoveryKey,
                                                 format: join.format,
                                                 logger: logger)
        }
    }
    
    /// Back into the lab call with the kept session: no code, the same device.
    func rejoinLab() {
        let homeserver = SDKLabSession.Saved.load()?.homeserver
        startLab(notice: "Lab: rejoining as \(labAccount ?? "")…",
                 certificateURL: homeserver.flatMap { ElementCallExampleLabJoin.certificateURL(homeserver: $0) }) { current, logger in
            if let current {
                return current
            }
            return try await SDKLabSession.restoreSaved(logger: logger)
        }
    }
    
    /// Logs the lab device out on the server and forgets it.
    func logOutLab() {
        endCall()
        let current = lab
        lab = nil
        labAccount = nil
        labFormat = nil
        labTask = Task {
            let logger = ElementCallExampleLabLogger()
            if let current {
                await current.logOut(logger: logger)
            } else if let saved = SDKLabSession.Saved.load() {
                await SDKLabSession.logOut(saved, logger: logger)
            }
        }
    }
    
    private func startLab(notice: String,
                          certificateURL: URL?,
                          session makeSession: @escaping (SDKLabSession?, ElementCallExampleLabLogger) async throws -> SDKLabSession) {
        lastOpenedRow = nil
        cancellables.removeAll()
        isHarnessMinimized = false
        let current = lab
        endCall()
        self.notice = notice
        labTask = Task { [weak self] in
            let logger = ElementCallExampleLabLogger()
            await ElementCallExampleLabTrust.install(from: certificateURL)
            do {
                let lab = try await Self.retrying(logger: logger) { try await makeSession(current, logger) }
                guard let self, !Task.isCancelled else { return }
                self.lab = lab
                labAccount = SDKLabSession.Saved.load()?.userID
                labFormat = lab.format
                let room = SDKLabRoomContext(room: lab.room)
                await room.load()
                let controller = ElementCallController(backend: lab.backend,
                                                       system: ElementCallExampleLabSystem(),
                                                       options: ElementCallOptions(membershipFormat: lab.format),
                                                       logger: logger)
                controller.actions
                    .sink { [weak self] action in self?.handle(action) }
                    .store(in: &cancellables)
                // The host's connectivity report (034 R11), from the SDK's sync state.
                labConnectivity = lab.observeConnectivity { [weak controller] isOnline in
                    Task { @MainActor in
                        logger.log(.info, "lab: the sync is \(isOnline ? "running again" : "offline"); reporting it")
                        controller?.reportConnectivity(isOnline: isOnline)
                    }
                }
                self.notice = nil
                session = Session(fixture: nil,
                                  presentation: .live(ElementCallScreenViewModel(controller: controller)),
                                  controller: controller)
                // Joining the call the lab already has, quietly: starting one would ring the room.
                controller.startCall(ElementCallData(isAudioCall: false, isStartingCall: false), room: room)
            } catch {
                self?.labAccount = SDKLabSession.Saved.load()?.userID
                self?.labFormat = SDKLabSession.Saved.load()?.membershipFormat
                self?.notice = "Lab: \(error.localizedDescription)"
            }
        }
    }
    
    /// The first request to the laptop's address fails while iOS asks for the local-network
    /// permission, so one failure is given a few seconds and a second go.
    private static func retrying<T>(logger: ElementCallExampleLabLogger, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            logger.log(.warning, "lab: first attempt failed (\(error.localizedDescription)); retrying in 4 s")
            try await Task.sleep(for: .seconds(4))
            return try await body()
        }
    }
    
    func endCall() {
        isHarnessMinimized = false
        ringingTask?.cancel()
        ringingTask = nil
        labTask?.cancel()
        labTask = nil
        labConnectivity?.cancel()
        labConnectivity = nil
        // `lab` stays: rejoining reuses it, and only logging out drops it.
        if case .scripted(_, let playback)? = session?.presentation {
            Task { await playback.stop() }
        }
        session = nil
    }
    
    // MARK: - Private
    
    /// A direct call with Bob whose tiles a scenario plays, on the real screen, as a scenario row is.
    private func openPlayed(_ text: String, fixture: ElementCallExampleFixture) {
        do {
            let playback = try ElementCallExampleScenarioPlayback(scenario: MatrixRTCScenario.parse(text, name: fixture.rawValue),
                                                                  localMemberID: ElementCallExampleRinging.localMemberID)
            let room = ElementCallFakeRoom(displayName: "Bob",
                                           isDirect: true,
                                           memberProfiles: [ElementCallExampleRinging.callee: ElementCallMemberProfile(userID: ElementCallExampleRinging.callee,
                                                                                                                       displayName: "Bob",
                                                                                                                       avatarURL: nil)])
            let controller = ElementCallController.fake(connection: .connected, room: room, isAudioCall: true, connectedAt: .now, call: playback.player.call)
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            let viewModel = ElementCallScreenViewModel(controller: controller)
            playback.attach(context: viewModel.context, controller: controller)
            session = Session(fixture: fixture, presentation: .scripted(viewModel, playback), controller: controller)
            Task {
                await playback.start()
                playback.play()
            }
        } catch {
            notice = "Fixture \(fixture.rawValue) failed to load: \(error)"
        }
    }
    
    /// Running only while a ringing or an outage fixture is up.
    private var ringingTask: Task<Void, Never>?
    
    /// The real controller following a scripted call, beside a scripted media session for the
    /// tiles, both started at once so the pickup lands on both together.
    private func openRinging(_ ringing: ElementCallExampleRinging, fixture: ElementCallExampleFixture) {
        do {
            let playback = try ElementCallExampleScenarioPlayback(scenario: MatrixRTCScenario.parse(ringing.scenario, name: fixture.rawValue),
                                                                  localMemberID: ElementCallExampleRinging.localMemberID)
            let room = ElementCallFakeRoom(displayName: "Bob",
                                           isDirect: true,
                                           memberProfiles: [ElementCallExampleRinging.callee: ElementCallMemberProfile(userID: ElementCallExampleRinging.callee,
                                                                                                                       displayName: "Bob",
                                                                                                                       avatarURL: nil)])
            let scripted = MatrixRTCScriptedCall(roomID: room.roomID,
                                                 status: .calling(callee: ElementCallExampleRinging.callee, ring: .sending, media: .connecting))
            let controller = ElementCallController.fake(following: scripted.call,
                                                        room: room,
                                                        isAudioCall: ringing.isAudioCall,
                                                        call: playback.player.call)
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            let viewModel = ElementCallScreenViewModel(controller: controller)
            playback.attach(context: viewModel.context, controller: controller)
            session = Session(fixture: fixture, presentation: .scripted(viewModel, playback), controller: controller)
            ringingTask = Task {
                await playback.start()
                await ringing.play(on: scripted, tiles: playback)
            }
        } catch {
            notice = "Fixture \(fixture.rawValue) failed to load: \(error)"
        }
    }
    
    /// The real controller following a scripted call that is connected from the start, so a
    /// connection lost at the end of the timeline fails the call as a real one does.
    private func openOutage(_ outage: ElementCallExampleOutage, fixture: ElementCallExampleFixture) {
        do {
            let playback = try ElementCallExampleScenarioPlayback(scenario: MatrixRTCScenario.parse(ElementCallExampleOutage.scenario, name: fixture.rawValue),
                                                                  localMemberID: ElementCallExampleOutage.localMemberID)
            let profiles = Dictionary(uniqueKeysWithValues: ElementCallExampleOutage.people.map { name in
                let userID = "@\(name.lowercased()):example.com"
                return (userID, ElementCallMemberProfile(userID: userID, displayName: name, avatarURL: nil))
            })
            let room = ElementCallFakeRoom(displayName: fixture.title, memberProfiles: profiles)
            let scripted = MatrixRTCScriptedCall(roomID: room.roomID, status: .connected(since: .now, isDegraded: false))
            let controller = ElementCallController.fake(following: scripted.call,
                                                        room: room,
                                                        isAudioCall: false,
                                                        call: playback.player.call)
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            let viewModel = ElementCallScreenViewModel(controller: controller)
            playback.attach(context: viewModel.context, controller: controller)
            session = Session(fixture: fixture, presentation: .scripted(viewModel, playback), controller: controller)
            ringingTask = Task {
                await playback.start()
                await outage.play(on: scripted, tiles: playback)
            }
        } catch {
            notice = "Fixture \(fixture.rawValue) failed to load: \(error)"
        }
    }
    
    /// A scripted call connected from the start, as an outage's is, whose session the reactions are
    /// pushed into; it lends its audio to the tiles' call, so they are heard.
    private func openReactions(_ reactions: ElementCallExampleReactions, fixture: ElementCallExampleFixture) {
        do {
            let profiles = Dictionary(uniqueKeysWithValues: ElementCallExampleReactions.people.map { name in
                let userID = "@\(name.lowercased()):example.com"
                return (userID, ElementCallMemberProfile(userID: userID, displayName: name, avatarURL: nil))
            })
            let room = ElementCallFakeRoom(displayName: fixture.title, memberProfiles: profiles)
            let scripted = MatrixRTCScriptedCall(roomID: room.roomID, status: .connected(since: .now, isDegraded: false))
            let playback = try ElementCallExampleScenarioPlayback(scenario: MatrixRTCScenario.parse(ElementCallExampleReactions.scenario, name: fixture.rawValue),
                                                                  localMemberID: ElementCallExampleReactions.localMemberID,
                                                                  audioOf: scripted.call)
            let controller = ElementCallController.fake(following: scripted.call,
                                                        room: room,
                                                        isAudioCall: false,
                                                        call: playback.player.call)
            controller.actions
                .sink { [weak self] action in self?.handle(action) }
                .store(in: &cancellables)
            let viewModel = ElementCallScreenViewModel(controller: controller)
            playback.attach(context: viewModel.context, controller: controller)
            session = Session(fixture: fixture, presentation: .scripted(viewModel, playback), controller: controller)
            ringingTask = Task {
                await playback.start()
                await reactions.play(tiles: playback)
            }
        } catch {
            notice = "Fixture \(fixture.rawValue) failed to load: \(error)"
        }
    }
    
    /// `connectedAt` so the bar draws its duration timer. Nothing else can give it one — only a
    /// joined call sets it otherwise — and the timer is half of what makes the bar look like an
    /// ongoing call rather than a button.
    private func makeController(connection: ElementCallConnection,
                                room: ElementCallFakeRoom) -> ElementCallController {
        .fake(connection: connection, room: room, connectedAt: .now)
    }
    
    /// From a harness context, which can only report these rather than perform them.
    private func handle(_ action: ElementCallScreenViewAction) {
        switch action {
        case .minimize:
            isHarnessMinimized = true
        case .hangUp, .dismiss:
            endCall()
        default:
            // Everything reversible is applied to the view state by the context itself.
            break
        }
    }
    
    /// From a real controller, on a connecting fixture.
    private func handle(_ action: ElementCallControllerAction) {
        switch action {
        case .ended:
            endCall()
        case .minimizeRequested, .restoreRequested, .pictureInPictureStarted, .pictureInPictureUnavailable:
            // The controller has already moved `isMaximized`, which `isMinimized` reads, so the bar
            // comes and goes without anything else happening here. A host with its own chrome to
            // rearrange would have more to do.
            break
        }
    }
}
