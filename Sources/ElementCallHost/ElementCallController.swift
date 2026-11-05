//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import ElementCallKit
import Foundation
import MatrixRtc
import Observation
import SwiftUI

public nonisolated enum ElementCallConnection: Equatable, Sendable {
    case idle
    case joining
    case connectingMedia
    /// A DM call ringing `callee`, a user ID; not connected until they answer.
    case calling(callee: String, ring: MatrixRTCRingPhase)
    case connected
    case ended(MatrixRTCEndReason)
    /// The call could not start or could not be kept. Final, like ``ended(_:)``, but the screen stays
    /// up showing why until the user closes it (034 R27).
    case failed(ElementCallFailure)
}

/// Why a call failed, typed so both platforms say the same thing for the same cause (034 R27).
public nonisolated enum ElementCallFailure: Equatable, Sendable {
    /// Our own media server was lost and not back within the core's budget, refused us, or was
    /// never reached.
    case connectionLost(MatrixRTCConnectionLossReason)
    /// The homeserver did not let the join complete in time.
    case joinTimedOut
    /// The homeserver refused the join for good.
    case joinRefused
    /// Anything else that stopped the call from starting: the room not opening, the microphone not
    /// publishing. Developer text, shown as it is, which is what every failure was before 034.
    case other(String)
}

package nonisolated extension ElementCallFailure {
    /// The failure screen's title.
    var title: String {
        switch self {
        case .connectionLost(.budget): L10n.failureConnectionLostTitle
        case .connectionLost(.refused), .connectionLost(.neverConnected): L10n.failureConnectionFailedTitle
        case .joinTimedOut, .joinRefused: L10n.failureJoinFailedTitle
        case .other: L10n.callFailed
        }
    }
    
    /// The sentence beneath the title.
    var text: String {
        switch self {
        case .connectionLost(.budget): L10n.failureConnectionLost
        case .connectionLost(.refused): L10n.failureConnectionRefused
        case .connectionLost(.neverConnected): L10n.failureConnectionNeverEstablished
        case .joinTimedOut: L10n.failureJoinTimedOut
        case .joinRefused: L10n.failureJoinRefused
        case .other(let message): message
        }
    }
}

/// A receipt for the most recent local departure attempt, not closure of the shared call.
public nonisolated struct ElementCallDeparture: Equatable, Sendable {
    public let roomID: String
    public let result: MatrixRTCLeaveResult
    
    public init(roomID: String, result: MatrixRTCLeaveResult) {
        self.roomID = roomID
        self.result = result
    }
}

/// What the host has to do about a change in the call, beyond drawing it.
public nonisolated enum ElementCallControllerAction: Sendable {
    /// The user asked to shrink the call. The host decides where it goes.
    case minimizeRequested
    /// The user asked to come back to the full-screen call, from the bar or the system window.
    case restoreRequested
    /// The call is over and its screen should go away. After a failure this comes only once the
    /// user has closed the screen, which shows why the call failed until then (034 R27).
    case ended
    /// A Picture in Picture window opened, possibly because the app was backgrounded rather than
    /// because anyone asked. Whatever the host put in the minimized slot should come down.
    case pictureInPictureStarted
    /// Minimizing cannot use a system window, so the host needs its own minimized presentation.
    case pictureInPictureUnavailable
}

/// Owns the call above the UI, so the call is a fact about the app rather than about the screen
/// showing it: the full-screen view and a minimized bar are two renderings of one thing.
///
/// One per user session, built by the host and kept for the session's life. There is nothing to
/// start: the core subscribes to a room, and to the media keys sent for it, when a call opens it.
/// Mutations are funnelled through the main actor so the UI only ever sees whole snapshots.
@Observable
@MainActor
public final class ElementCallController {
    public private(set) var callData: ElementCallData?
    public private(set) var connection: ElementCallConnection = .idle
    public private(set) var connectedAt: Date?
    public private(set) var isLoudspeaker = false
    /// Everywhere the call can come out of, external hardware first. Only the speaker and the
    /// receiver means the control bar shows a toggle; anything more and it offers a menu.
    public private(set) var audioOutputs: [CallAudioOutput] = []
    /// Which of ``audioOutputs`` the call is coming out of, or nil before the session has a route.
    public private(set) var audioOutput: CallAudioOutput?
    public private(set) var isMaximized = true
    public private(set) var isTileStatsVisible = false
    /// The user's choice for reactions, from ``preferences``; set with ``setReactionsPreference(_:)``.
    public private(set) var reactionsPreference: ElementCallReactionsPreference
    /// How loud the call's sound effects play, from ``preferences``; set with
    /// ``setSoundEffectsVolume(_:)``.
    public private(set) var soundEffectsVolume: Float
    
    /// The room the current call is in, for as long as there is one.
    public private(set) var room: (any ElementCallRoomContextProtocol)?
    
    /// The last failure worth telling the user about; the screen shows it once and clears it.
    public var errorMessage: String?
    
    /// Whether our homeserver answers, from the start of a call until it ends (034 C4).
    ///
    /// Unreachable if either source says so: the client's, which is the only one while there is
    /// no media yet and the controls are already live, or the copy in the media session's
    /// interruptions record. In a real call the two agree a hop apart, and taking the worse keeps
    /// that hop from re-enabling the hand. A scripted call has no client, so its record is all it
    /// has.
    public var signalling: MatrixRTCSignallingHealth {
        if !followedSignalling.isReachable {
            return followedSignalling
        }
        return call?.interruptions.signalling ?? .reachable
    }
    
    /// The service interruptions list, which the stage's indicator and the minimized bar both show
    /// (034 R13, R35, R37). Empty until some cause has lasted ``interruptionHold``, and emptied
    /// the moment none is left.
    public private(set) var interruptions: [ElementCallInterruption] = []
    
    /// How long a cause has to last before the list shows it. The indicator is an alarm for the
    /// whole call: a blip shorter than this is nothing the user can act on, an indicator that
    /// comes up at every one is soon ignored, and a screen reader announces each coming and going
    /// (R40). Once up the list follows the causes without a wait, and the tiles never wait for it:
    /// what a tile shows is about that tile.
    public static let interruptionHold: Duration = .milliseconds(2500)
    
    /// What the hold is timed on; a test's manual clock.
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored private var interruptionsTask: Task<Void, Never>?
    @ObservationIgnored private(set) var interruptionHoldTask: Task<Void, Never>?
    
    private var followedSignalling: MatrixRTCSignallingHealth = .reachable
    
    /// Our membership in the room's call, from the join until the call ends.
    public private(set) var rtcCall: MatrixRTCCall? {
        // Before it makes a sound: the user's volume is the call's from its first effect (037 R22).
        didSet {
            rtcCall?.setSoundEffectsVolume(soundEffectsVolume)
        }
    }
    
    /// Retained through reset for host delivery; cleared when a new call starts.
    public private(set) var lastDeparture: ElementCallDeparture?
    public private(set) var call: MatrixRTCMediaSession?
    
    /// The user's media intent while there is no call to hold it. The control bar is on screen from
    /// `.joining` onwards -- it is drawn whenever the screen is maximized, with no gate on the
    /// connection -- so a tap on mute or camera arrives before `call` does. Those taps used to be
    /// dropped: the button snapped back on the next refresh and the microphone went up unmuted.
    private var pendingMicrophoneMuted = false
    private var pendingCameraEnabled = false
    private var isMediaPublicationReady = false
    private var cameraPermissionRequestID = UUID()
    
    /// Computed rather than mirrored, so the call is the single truth the moment it exists and the
    /// two cannot drift -- `applySystemMute(_:)` writes to the call directly.
    public var isMicrophoneMuted: Bool {
        call?.isMicrophoneMuted ?? pendingMicrophoneMuted
    }
    
    public var isCameraEnabled: Bool {
        call?.isCameraEnabled ?? pendingCameraEnabled
    }
    
    /// The system window for a minimized call, audio ones included — an audio call shows the
    /// avatar placeholder. Internal because the host drives it through ``requestMinimize()`` and
    /// ``restore()`` rather than directly.
    let pictureInPicture = ElementCallPictureInPictureController()
    
    public var actions: AnyPublisher<ElementCallControllerAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    /// Anyone in the call has video to show.
    ///
    /// No longer decides whether minimizing uses the window — every call does — but it still
    /// decides whether *backgrounding* the app opens one by itself, unless the host opted audio
    /// calls in through ``ElementCallOptions/isAutomaticPictureInPictureForAudioCallsEnabled``.
    public var hasVideo: Bool {
        call?.hasVideo ?? false
    }
    
    /// The tile the stage gives its largest slot, written by the screen through
    /// ``setSpotlightTile(_:)``. The Picture in Picture window continues this tile's picture.
    ///
    /// **Stored, and written by the screen rather than computed here**, because the screen's rule
    /// has memory the controller has no business holding: which hero the user swiped to, and who
    /// spoke last while nobody is speaking. Computing "the hero, else the head of the ranking" here
    /// — what this used to do — was the spotlight rule the layout spec names as wrong (003 R3): a
    /// call small enough to see everyone has no spotlight at all.
    ///
    /// Nil between calls, and nil whenever every tile is the same size; the window's candidate
    /// then falls back to the first tile with video (003 R68).
    public private(set) var spotlightTileID: MatrixRTCTileID?
    /// The window shows ``spotlightTileID`` or its placeholder, never somebody else instead. See
    /// `MatrixRTCMediaSession.pictureInPictureCandidate(spotlight:isExact:)`.
    public private(set) var isSpotlightTileExact = false
    
    /// Equality-guarded on purpose: the window re-reads its source inside observation tracking, so
    /// an unguarded write on every roster would re-attach its stream once a second for nothing.
    public func setSpotlightTile(_ tileID: MatrixRTCTileID?, isExact: Bool = false) {
        if tileID != spotlightTileID {
            spotlightTileID = tileID
        }
        if isExact != isSpotlightTileExact {
            isSpotlightTileExact = isExact
        }
    }
    
    public var isInCall: Bool {
        switch connection {
        case .joining, .connectingMedia, .calling, .connected: true
        default: false
        }
    }
    
    /// Public so the view module can seed its style environment and read the developer-mode flag.
    public let style: ElementCallStyle
    public let options: ElementCallOptions
    
    @ObservationIgnored private let preferences: any ElementCallPreferencesStoreProtocol
    private let rtcClient: MatrixRTCClient
    /// The room the call is in, open from before the join until after the leave.
    private var rtcRoom: MatrixRTCRoom?
    private let system: any ElementCallSystemProvidingProtocol
    private let logger: (any ElementCallLoggingProtocol)?
    private let actionsSubject = PassthroughSubject<ElementCallControllerAction, Never>()
    private var eventsTask: Task<Void, Never>?
    private var membershipTask: Task<Void, Never>?
    private var isEndingCall = false
    private var isTeardownPending = false
    /// Pre-media work has no session identity yet; a restart in the same room is still a new call.
    private(set) var callGeneration = UUID()
    private var statusTask: Task<Void, Never>?
    private var signallingTask: Task<Void, Never>?
    private var routeObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    
    /// `backend` is the call's Matrix port, implemented by the host over its SDK client. This package
    /// carries no SDK of its own, so it never constrains which SDK version a host is on; the example
    /// app's `SDKMatrixBackend` is the reference to copy.
    public init(backend: any ElementCallMatrixBackendProtocol,
                system: any ElementCallSystemProvidingProtocol,
                options: ElementCallOptions = .init(),
                style: ElementCallStyle = .stock,
                logger: (any ElementCallLoggingProtocol)? = nil,
                preferences: any ElementCallPreferencesStoreProtocol = ElementCallUserDefaultsPreferencesStore()) {
        rtcClient = MatrixRTCClient(backend: backend)
        self.system = system
        self.options = options
        self.preferences = preferences
        reactionsPreference = preferences.reactions
        soundEffectsVolume = preferences.soundEffectsVolume
        self.style = style
        self.logger = logger
        pictureInPicture.logger = logger
        
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { self?.refreshAudioRoute(reason: reason) }
        }
        
        pictureInPicture.actions
            .sink { [weak self] action in
                guard let self else { return }
                switch action {
                case .started:
                    actionsSubject.send(.pictureInPictureStarted)
                case .restoreRequested:
                    actionsSubject.send(.restoreRequested)
                case .failed:
                    actionsSubject.send(.pictureInPictureUnavailable)
                case .closed:
                    // Closing the window is how you leave a call from Picture in Picture, which is
                    // what FaceTime does too.
                    hangUp()
                }
            }
            .store(in: &cancellables)
        
        system.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .audioSessionActivated:
                    audioSessionDidActivate()
                case .audioSessionDeactivated:
                    audioSessionDidDeactivate()
                case .microphoneMuteChanged(let isMuted):
                    applySystemMute(isMuted)
                case .endCallRequested(let roomID):
                    guard roomID == room?.roomID else { return }
                    hangUp()
                }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Lifecycle
    
    isolated deinit {
        eventsTask?.cancel()
        membershipTask?.cancel()
    }
    
    public func startCall(_ callData: ElementCallData, room: any ElementCallRoomContextProtocol) {
        guard !isInCall, !isEndingCall, !isTeardownPending else {
            log(.warning, "already in a call, ignoring start for \(room.roomID)")
            return
        }
        runTask?.cancel()
        callGeneration = UUID()
        let generation = callGeneration
        isMediaPublicationReady = false
        lastDeparture = nil
        isHoldingFailure = false
        self.callData = callData
        self.room = room
        connection = .joining
        isMaximized = true
        // The starting point for the controls, which are live from here on. A tap before the call
        // exists overwrites these, and `publishMedia` joins with whatever they end up saying.
        pendingMicrophoneMuted = false
        pendingCameraEnabled = !callData.isAudioCall
        
        // The system window has to show something when the member on screen has their camera off.
        // Built here rather than in the view layer because everything it needs, the host's avatars
        // and the room's profiles, is already to hand.
        pictureInPicture.placeholderProvider = { [weak self] memberID in
            guard let self else { return AnyView(Color.black) }
            return AnyView(ElementCallPictureInPicturePlaceholder(profile: memberID.flatMap { self.profile(forMemberID: $0) },
                                                                  fallbackName: room.displayName,
                                                                  style: style))
        }
        
        followSignalling()
        followInterruptions()
        runTask = Task { await runCall(callData, room: room, generation: generation) }
    }
    
    /// From the host's Matrix client: it has gone offline, or a request has succeeded since it was.
    /// Report the transition out of offline only, never sync merely starting (034 C3). Optional:
    /// without it the core goes by its own sends, which notice an outage at the next one.
    public func reportConnectivity(isOnline: Bool) {
        rtcClient.reportConnectivity(isOnline: isOnline)
    }
    
    /// On a failed call, which has already ended, this is the user closing the screen that says why.
    public func hangUp() {
        if isHoldingFailure {
            isHoldingFailure = false
            actionsSubject.send(.ended)
            return
        }
        let generation = callGeneration
        Task {
            guard callGeneration == generation else { return }
            await endCall(.left)
        }
    }
    
    /// The view where the system anchors the Picture in Picture shrink animation. The host places it
    /// in the full-screen call layout; AVKit needs it on screen for the window to start by itself
    /// when the app is backgrounded.
    public var pictureInPictureSourceView: UIView {
        pictureInPicture.sourceView
    }
    
    /// Shrinks the call, and says how. Any call with the system window available uses it; every
    /// other case reports ``ElementCallControllerAction/pictureInPictureUnavailable`` so the host
    /// puts up its own minimized presentation, usually a bar.
    ///
    /// Audio calls go to the window too. They used to be excluded on `hasVideo`, which meant that
    /// with every camera off the collapse button silently did nothing — the window shows the
    /// avatar placeholder, which was already built and wired but unreachable. The bar remains the
    /// fallback for the cases that are genuinely not about video: the host disabling the window,
    /// a device that cannot do it, or a screen share holding it.
    public func requestMinimize() {
        isMaximized = false
        actionsSubject.send(.minimizeRequested)
        if options.isPictureInPictureEnabled, pictureInPicture.isPossible {
            pictureInPicture.start()
        } else {
            actionsSubject.send(.pictureInPictureUnavailable)
        }
    }
    
    /// Back to full screen, from the bar or from the system window.
    public func restore() {
        pictureInPicture.stop()
        isMaximized = true
    }
    
    func setMaximized(_ maximized: Bool) {
        isMaximized = maximized
    }
    
    /// Kept for the next call too, and applied at once to this one: to the reactions that arrive
    /// from now on, leaving those already showing or sounding to finish (037 R14, R15).
    public func setReactionsPreference(_ preference: ElementCallReactionsPreference) {
        guard preference != reactionsPreference else { return }
        reactionsPreference = preference
        preferences.reactions = preference
        call?.reactionsMode = preference.mode
        log(.info, "reactions \(preference.rawValue)")
    }
    
    /// Kept for the next call too, and applied at once, to effects already playing as well (037 R22).
    public func setSoundEffectsVolume(_ volume: Float) {
        let volume = min(max(volume, 0), 1)
        guard volume != soundEffectsVolume else { return }
        soundEffectsVolume = volume
        preferences.soundEffectsVolume = volume
        rtcCall?.setSoundEffectsVolume(volume)
    }
    
    /// One short effect at the current volume, for when the user lets go of the slider (037 R24).
    public func playSoundEffectsVolumeSample() {
        log(.info, "sound effects volume \(Int((soundEffectsVolume * 100).rounded())) %")
        rtcCall?.playSoundEffectsVolumeSample()
    }
    
    public func toggleTileStats() {
        guard options.isDeveloperModeEnabled else { return }
        isTileStatsVisible.toggle()
        log(.info, "tile stats \(isTileStatsVisible ? "shown" : "hidden")")
    }
    
    // MARK: - Media controls
    
    /// From the UI: mutes the call and tells the system, whose echo comes back through
    /// ``applySystemMute(_:)``.
    public func setMicrophoneMuted(_ muted: Bool) {
        pendingMicrophoneMuted = muted
        let generation = callGeneration
        Task {
            guard isCurrentCall(generation) else { return }
            await call?.setMicrophoneMuted(muted)
        }
        // Only the system needs a room. The intent above is recorded either way, or a mute made
        // before the call connects is lost.
        if let roomID = room?.roomID {
            system.setMicrophoneEnabled(!muted, roomID: roomID)
        }
    }
    
    /// From the system call UI, including our own transaction echoing back. Idempotent, which is what
    /// makes our own echo a no-op.
    ///
    /// Guarded on the intent rather than on the call, so that muting from the system UI while we are
    /// still joining survives the join the same way muting from our own controls does.
    func applySystemMute(_ muted: Bool) {
        guard isMicrophoneMuted != muted else { return }
        pendingMicrophoneMuted = muted
        let generation = callGeneration
        Task {
            guard isCurrentCall(generation) else { return }
            await call?.setMicrophoneMuted(muted)
        }
    }
    
    public func setCameraEnabled(_ enabled: Bool) {
        let generation = callGeneration
        Task { await setCameraEnabled(enabled, generation: generation) }
    }
    
    func setCameraEnabled(_ enabled: Bool, generation: UUID, cameraAccess: (() async -> Bool)? = nil) async {
        guard isCurrentCall(generation) else { return }
        cameraPermissionRequestID = UUID()
        let requestID = cameraPermissionRequestID
        if enabled {
            let hasAccess: Bool
            if let cameraAccess {
                hasAccess = await cameraAccess()
            } else {
                hasAccess = await requestCameraAccess()
            }
            guard hasAccess else { return }
        }
        guard isCurrentCall(generation), cameraPermissionRequestID == requestID else { return }
        // A permission reply may arrive after a new media session for this same call is installed.
        pendingCameraEnabled = enabled
        if let call {
            await applyCameraEnabled(enabled, on: call)
        }
    }
    
    public func switchCamera() {
        do {
            try call?.switchCamera()
        } catch {
            log(.warning, "could not switch camera: \(error)")
        }
    }
    
    /// ReplayKit refuses to capture, with -5803, while the app holds a Picture in Picture controller,
    /// so the window is given up for the duration of a share and comes back when it ends. A call
    /// minimized meanwhile uses the bar.
    public func setScreenShareEnabled(_ enabled: Bool) {
        // Only starting is gated. Stopping stays available unconditionally so a share already in
        // flight can always be ended, whatever the option says.
        guard options.isScreenSharingEnabled || !enabled else { return }
        Task {
            guard let call else { return }
            if enabled {
                pictureInPicture.unbind()
            }
            do {
                try await call.setScreenShareEnabled(enabled)
            } catch {
                log(.warning, "could not \(enabled ? "start" : "stop") the screen share: \(error)")
                if enabled {
                    errorMessage = "Screen sharing could not start. \(Self.describe(error))"
                }
            }
            if !call.isScreenSharing {
                bindPictureInPictureIfEnabled(call)
            }
        }
    }
    
    // MARK: - Raised hand
    
    /// Read from our tile, which shows the hand the user asked for from the moment they ask: the
    /// core moves it before its first send and keeps sending until the hand lands, through an
    /// outage if need be, and puts it back where it last landed if the homeserver refuses (034 C12,
    /// 009 R5 as sharpened by 034). So nothing here needs undoing either way.
    public var isHandRaised: Bool {
        call?.ownTile?.handRaisedAt != nil
    }
    
    /// A no-op before the join, which has no membership to put a hand on.
    ///
    /// Never gated on a request in flight, as it was while a request lasted one send: one can now
    /// be suspended for as long as the homeserver is away, and a second tap is how the user takes
    /// it back. The core resolves the first quietly and sends the reversal instead.
    public func setHandRaised(_ raised: Bool) {
        guard let rtcCall else { return }
        Task {
            // Throws only for a permanent refusal; the end of the call resolves a request quietly.
            do {
                if raised {
                    try await rtcCall.raiseHand()
                } else {
                    try await rtcCall.lowerHand()
                }
            } catch {
                log(.warning, "could not \(raised ? "raise" : "lower") the hand: \(error)")
                errorMessage = raised ? L10n.handRaiseFailed : L10n.handLowerFailed
            }
        }
    }
    
    private func bindPictureInPictureIfEnabled(_ call: MatrixRTCMediaSession) {
        guard options.isPictureInPictureEnabled, !pictureInPicture.isBound else { return }
        pictureInPicture.automaticStartIncludesAudioCalls = options.isAutomaticPictureInPictureForAudioCallsEnabled
        pictureInPicture.bind(call: call) { [weak self] in (self?.spotlightTileID, self?.isSpotlightTileExact ?? false) }
    }
    
    public func setLoudspeaker(_ enabled: Bool) {
        do {
            try CallAudioSessionConfigurator.setLoudspeaker(enabled)
        } catch {
            log(.warning, "could not switch the audio output: \(error)")
        }
        refreshAudioRoute()
    }
    
    public func selectAudioOutput(_ output: CallAudioOutput) {
        do {
            try CallAudioSessionConfigurator.selectAudioOutput(output)
        } catch {
            log(.warning, "could not switch the audio output to \(output.kind): \(error)")
        }
        refreshAudioRoute()
    }
    
    /// Re-reads the route. Logged only when the system changed it, with the ports as the session
    /// names them: that is how a CarPlay route gets diagnosed, from a host's logs after a drive.
    private func refreshAudioRoute(reason: AVAudioSession.RouteChangeReason? = nil) {
        let route = CallAudioSessionConfigurator.audioOutputs(hasReceiver: UIDevice.current.userInterfaceIdiom == .phone)
        audioOutputs = route.outputs
        audioOutput = route.current
        isLoudspeaker = CallAudioSessionConfigurator.isLoudspeaker
        if let reason {
            log(.info, "audio route changed (\(reason.rawValue)): \(CallAudioSessionConfigurator.routeDescription), offering \(route.outputs.map { "\($0.kind)" }), current \(route.current.map { "\($0.kind)" } ?? "none")")
        }
        updateProximityMonitoring()
    }
    
    /// A call on the earpiece is held to the ear, so the screen goes dark and ignores touches there,
    /// or a cheek hangs up or mutes. Element X's web call screen does the same. Not on any other
    /// output, where the phone is looked at.
    static func isProximityMonitored(isInCall: Bool, output: CallAudioOutput?) -> Bool {
        isInCall && output?.kind == .receiver
    }
    
    /// Only on a change: the sensor's state is the device's, and other code may own it between
    /// calls.
    private func updateProximityMonitoring() {
        let isMonitored = Self.isProximityMonitored(isInCall: isInCall, output: audioOutput)
        guard UIDevice.current.isProximityMonitoringEnabled != isMonitored else { return }
        UIDevice.current.isProximityMonitoringEnabled = isMonitored
        log(.info, "proximity monitoring \(isMonitored ? "on" : "off")")
    }
    
    // MARK: - System audio session
    
    private var isAudioSessionActive = false
    
    /// The system activated the audio session. It may happen before or after media connects, so the
    /// engine starts from whichever comes second.
    func audioSessionDidActivate() {
        isAudioSessionActive = true
        startAudioIfReady()
    }
    
    func audioSessionDidDeactivate() {
        isAudioSessionActive = false
        rtcCall?.stopAudio()
    }
    
    /// A video call is looked at, not held to an ear, so it starts on the loudspeaker. A headset
    /// still wins over both built-in outputs when one is connected.
    private func startAudioIfReady() {
        guard isAudioSessionActive, let rtcCall else { return }
        rtcCall.startAudio()
        if let callData, !callData.isAudioCall, CallAudioSessionConfigurator.isBuiltInReceiver {
            setLoudspeaker(true)
        }
        refreshAudioRoute()
    }
    
    // MARK: - Private
    
    /// The join in flight, cancelled by ``endCall(leave:)``. Joining takes seconds and a hang-up can
    /// land anywhere inside it; without this the join carried on, published camera and microphone
    /// into a session nobody owned any more, and the app kept both open with no screen left to stop
    /// them.
    ///
    /// A step that throws after the cancel is not a failure, so every catch in the join checks for
    /// the cancel before failing. The cancel is usually why it threw: the wait for the room gives up
    /// on it with `roomNotReady`, and a join or a media connection still in flight has the room or
    /// the call torn down under it by `endCall`. By then `endCall` has ended the call, so failing it
    /// turned `.ended(.left)` into `.failed` and ended the call a second time, and that was the next
    /// call if the host had started one on `.ended`. Nothing needs tearing down there either: a step
    /// that threw made nothing, and `endCall` released what the steps before it made.
    private var runTask: Task<Void, Never>?
    
    private func isCurrentCall(_ generation: UUID) -> Bool {
        !Task.isCancelled && callGeneration == generation && !isEndingCall && isInCall
    }
    
    private func runCall(_ callData: ElementCallData, room: any ElementCallRoomContextProtocol, generation: UUID) async {
        guard isCurrentCall(generation) else { return }
        log(.info, "joining \(room.roomID)")
        guard let rtcCall = await joinCall(for: callData, room: room, generation: generation) else { return }
        guard !Task.isCancelled, self.rtcCall === rtcCall, !isEndingCall, isInCall else { return }
        
        follow(rtcCall, roomID: room.roomID)
        // From the join rather than from media: the ring goes out now, and its ringback with it.
        activateAudio()
        
        let call: MatrixRTCMediaSession
        do {
            call = try await rtcCall.connectMedia(isSFUFallbackEnabled: options.isSFUFallbackEnabled)
        } catch {
            guard !Task.isCancelled, self.rtcCall === rtcCall else { return }
            fail(style.strings.callMediaFailed, diagnostic: "Media failed: \(error)", generation: generation)
            return
        }
        // Before anything else: from here on the session is handling the core's events.
        call.participantCapForJoinLeaveSounds = options.participantCapForJoinLeaveSounds
        call.reactionsMode = reactionsPreference.mode
        guard !Task.isCancelled, self.rtcCall === rtcCall, !isEndingCall, isInCall else {
            await abandon(rtcCall: rtcCall, call: call, roomID: room.roomID)
            return
        }
        installMediaSession(call)
        
        await publishMedia(on: call, rtcCall: rtcCall, room: room)
    }
    
    /// Claims the system call, opens the room and joins its call, which puts our membership out.
    func joinCall(for callData: ElementCallData,
                  room: any ElementCallRoomContextProtocol,
                  generation: UUID) async -> MatrixRTCCall? {
        guard isCurrentCall(generation) else { return nil }
        // Claim the system call *before* our membership goes out: the incoming-call watcher reads
        // our own membership as "answered elsewhere" and would end the ringing call under us.
        // For an outgoing call this requests the start action; the system activates the audio session
        // either way and reports it back through the events publisher.
        do {
            try CallAudioSessionConfigurator.configure()
        } catch {
            log(.warning, "could not configure the audio session: \(error)")
        }
        await system.startCall(roomID: room.roomID, displayName: room.displayName, isVideo: !callData.isAudioCall)
        guard isCurrentCall(generation) else { return nil }
        
        // Room state unless the host asks otherwise: a join in the other formats fails in a room with
        // no open MSC4143 slot, and nothing here opens one.
        let format = options.membershipFormat
        log(.info, "joining with membership format \(format)")
        
        let rtcRoom: MatrixRTCRoom
        do {
            rtcRoom = try await rtcClient.room(roomID: room.roomID, format: format)
        } catch {
            guard isCurrentCall(generation) else {
                log(.info, "join of \(room.roomID) was cancelled, ignoring: \(error)")
                return nil
            }
            fail(style.strings.callPreparationFailed, diagnostic: "Could not open the room: \(error)", generation: generation)
            return nil
        }
        guard isCurrentCall(generation) else {
            await rtcRoom.shutdown()
            return nil
        }
        self.rtcRoom = rtcRoom
        
        let rtcCall: MatrixRTCCall
        do {
            rtcCall = try await rtcRoom.joinCall(intent: callData.isAudioCall ? .audio : .video, kind: Self.kind(for: callData, isDirect: room.isDirect))
        } catch {
            if isCurrentCall(generation) {
                switch error as? MatrixRTCError {
                case .joinTimedOut:
                    fail(.joinTimedOut, generation: generation)
                case .joinRefused(let errorCode, let reason):
                    fail(.joinRefused, diagnostic: "Join refused: \(errorCode ?? "no code") \(reason)", generation: generation)
                default:
                    fail(style.strings.callJoinFailed, diagnostic: "Join failed: \(error)", generation: generation)
                }
            } else {
                await rtcRoom.shutdown()
            }
            return nil
        }
        guard isCurrentCall(generation) else {
            await rtcCall.leave()
            await rtcRoom.shutdown()
            return nil
        }
        self.rtcCall = rtcCall
        return rtcCall
    }
    
    /// Microphone, then camera for a video call. The call counts as connected once the microphone is up.
    func publishMedia(on call: MatrixRTCMediaSession,
                      rtcCall: MatrixRTCCall,
                      room: any ElementCallRoomContextProtocol,
                      prepareAudio: (() -> Void)? = nil,
                      cameraAccess: (() async -> Bool)? = nil) async {
        guard !Task.isCancelled, self.call === call, !call.hasEnded, !isEndingCall,
              isInCall else { return }
        if let prepareAudio {
            prepareAudio()
        } else {
            activateAudio()
        }
        
        // `pendingMicrophoneMuted`, not `isMicrophoneMuted`: `self.call` is assigned before this runs,
        // so the accessor would already be answering from the fresh call -- unmuted -- and would
        // discard a mute made while joining. The same goes for the camera below.
        do {
            try await call.publishMicrophone(muted: pendingMicrophoneMuted)
        } catch {
            guard !Task.isCancelled, self.call === call, !call.hasEnded, !isEndingCall else { return }
            fail(style.strings.microphoneStartFailed, diagnostic: "Microphone failed: \(error)", generation: callGeneration)
            return
        }
        guard !Task.isCancelled, self.call === call, !call.hasEnded, !isEndingCall else {
            await abandon(rtcCall: rtcCall, call: call, roomID: room.roomID)
            return
        }
        log(.info, "connected as \(call.localMemberID)")
        
        completeMediaStartup(on: call, roomID: room.roomID)
        if pendingCameraEnabled {
            // Camera permission and capture must not hold an otherwise connected audio call open.
            let hasAccess: Bool
            if let cameraAccess {
                hasAccess = await cameraAccess()
            } else {
                hasAccess = await requestCameraAccess()
            }
            guard hasAccess, pendingCameraEnabled, !Task.isCancelled, self.call === call,
                  !call.hasEnded, !isEndingCall, isInCall else { return }
            await applyCameraEnabled(true, on: call)
        }
    }
    
    private func activateAudio() {
        // Where nothing else owns the session, we do: the simulator, and an iOS app on macOS,
        // where the host's system-call port is inert because CallKit is unavailable. Runtime
        // rather than `#if`, because an iOS-on-Mac binary is indistinguishable from an iOS one at
        // compile time.
        if CallAudioSessionConfigurator.isSelfActivating {
            do {
                try CallAudioSessionConfigurator.activate()
                isAudioSessionActive = true
            } catch {
                log(.error, "could not activate the audio session: \(error)")
            }
        }
        // The system usually activated the session while we were still joining.
        startAudioIfReady()
    }
    
    func installMediaSession(_ call: MatrixRTCMediaSession) {
        isMediaPublicationReady = false
        self.call = call
        observeMediaSession(call)
        bindPictureInPictureIfEnabled(call)
    }
    
    func observeMediaSession(_ call: MatrixRTCMediaSession) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await event in call.events {
                guard !Task.isCancelled, let self, self.call === call else { return }
                handle(event, from: call)
            }
        }
    }
    
    func completeMediaStartup(on call: MatrixRTCMediaSession, roomID: String) {
        guard !Task.isCancelled, self.call === call, !call.hasEnded, !isEndingCall,
              isInCall, room?.roomID == roomID else { return }
        isMediaPublicationReady = true
        updateOwnMediaConnection(on: call, roomID: roomID)
    }
    
    func handle(_ event: MatrixRTCCallEvent, from call: MatrixRTCMediaSession) {
        guard !Task.isCancelled, self.call === call, !isEndingCall, isInCall else { return }
        switch event {
        case .ownMediaConnectionDegraded:
            guard let roomID = room?.roomID else { return }
            updateOwnMediaConnection(on: call, roomID: roomID)
        default:
            // Aggregate degradation includes remote transports; it is not our connection state.
            break
        }
    }
    
    private func updateOwnMediaConnection(on call: MatrixRTCMediaSession, roomID: String) {
        guard !Task.isCancelled, self.call === call, !call.hasEnded, !isEndingCall,
              isInCall, room?.roomID == roomID else { return }
        // Read current health: buffered obsolete events must not replay an outage after recovery.
        if call.isOwnMediaDegraded {
            guard connection == .connected else { return }
            connection = .connectingMedia
            system.reportDisconnected(roomID: roomID)
        } else {
            guard isMediaPublicationReady, connection == .connectingMedia,
                  case .connected = rtcCall?.status else { return }
            connection = .connected
            if connectedAt == nil {
                connectedAt = .now
            }
            refreshAudioRoute()
            system.reportConnected(roomID: roomID)
        }
    }
    
    func applyCameraEnabled(_ enabled: Bool, on call: MatrixRTCMediaSession) async {
        guard !Task.isCancelled, self.call === call, !call.hasEnded, !isEndingCall, isInCall else { return }
        do {
            try await call.setCameraEnabled(enabled)
        } catch {
            guard !Task.isCancelled, self.call === call, !call.hasEnded, !isEndingCall, isInCall else { return }
            log(.warning, "could not \(enabled ? "enable" : "disable") the camera: \(error)")
            errorMessage = "The camera could not \(enabled ? "start" : "stop"). \(Self.describe(error))"
        }
    }
    
    /// The connection follows the core from the join on.
    func followSignalling() {
        signallingTask?.cancel()
        let updates = rtcClient.signallingUpdates()
        signallingTask = Task { [weak self] in
            for await health in updates {
                guard let self, !Task.isCancelled else { return }
                if health != followedSignalling {
                    log(.info, "signalling \(health)")
                    followedSignalling = health
                }
            }
        }
    }
    
    func followInterruptions() {
        interruptionsTask?.cancel()
        interruptionsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        self.hold(self.currentInterruptions)
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private var currentInterruptions: [ElementCallInterruption] {
        ElementCallInterruption.entries(signalling: signalling, record: call?.interruptions)
    }
    
    /// Publishes `entries` once something has been interrupted for the hold, and at once while
    /// the list is already up or when nothing is.
    private func hold(_ entries: [ElementCallInterruption]) {
        if entries.isEmpty {
            interruptionHoldTask?.cancel()
            interruptionHoldTask = nil
            if !interruptions.isEmpty {
                interruptions = []
            }
        } else if !interruptions.isEmpty {
            if entries != interruptions {
                interruptions = entries
            }
        } else if interruptionHoldTask == nil {
            interruptionHoldTask = clock.schedule(after: Self.interruptionHold) { [weak self] in
                guard let self else { return }
                interruptionHoldTask = nil
                interruptions = currentInterruptions
            }
        }
    }
    
    /// The connection follows the core from the join on.
    func follow(_ rtcCall: MatrixRTCCall, roomID: String) {
        let generation = callGeneration
        apply(rtcCall.status, roomID: roomID)
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in rtcCall.statusUpdates {
                guard !Task.isCancelled, let self, self.rtcCall === rtcCall, callGeneration == generation else { return }
                apply(status, roomID: roomID)
            }
        }
    }
    
    /// A failure is ours and is kept.
    private func apply(_ status: MatrixRTCCallStatus, roomID: String) {
        guard isInCall, !isEndingCall, room?.roomID == roomID else { return }
        switch status {
        case .connecting:
            connection = .connectingMedia
        case .calling(let callee, let ring, _):
            connection = .calling(callee: callee, ring: ring)
        case .connected(let since, _):
            if let call, call.isOwnMediaDegraded {
                return
            }
            connection = .connected
            // Once: `since` holds through a reconnect, and so does the system's call.
            if connectedAt == nil {
                connectedAt = since
                system.reportConnected(roomID: roomID)
            }
        case .ended(let reason):
            // From a different task than the status reader: teardown cancels that task.
            let generation = callGeneration
            let endedCall = rtcCall
            Task { [weak self] in
                guard let self, callGeneration == generation, rtcCall === endedCall else { return }
                await endCall(reason)
            }
        }
    }
    
    /// How the system hears the end of the call: the other side's doing for a decline and a departure
    /// (030 R32), and the call's own for what went wrong.
    static func systemReason(for reason: MatrixRTCEndReason) -> ElementCallEndReason {
        switch reason {
        case .left: .local
        case .declined, .othersLeft, .empty, .slotClosed: .remoteEnded
        case .unanswered: .unanswered
        case .ringNotSent, .connectionClosed: .failed
        }
    }
    
    /// A direct chat rings, a group call is an invitation rather than a summons. Either only when
    /// *starting* a call; joining one someone else started happens quietly.
    static func kind(for callData: ElementCallData, isDirect: Bool) -> MatrixRTCCallKind {
        let intent: MatrixRTCCallIntent? = callData.isStartingCall ? (callData.isAudioCall ? .audio : .video) : nil
        return isDirect ? .direct(ring: intent) : .group(notify: intent)
    }
    
    private static func describe(_ error: Error) -> String {
        if case MatrixRTCError.media(let message) = error {
            return message
        }
        return "\(error)"
    }
    
    private func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
    
    /// The host's profile for whoever is on a tile. A member ID identifies a device rather than a
    /// person, so it goes through the participant list to find the user first. Falls back to a
    /// bare profile, because a member can be in the call before their room membership has loaded.
    public func profile(forMemberID memberID: String) -> ElementCallMemberProfile? {
        guard let call else { return nil }
        // The tile roster's references carry the user id for exactly this; our own tile is beside it.
        let userID = call.tiles.order.first { $0.id.memberID == memberID }?.userID
            ?? (call.ownTile?.memberID == memberID ? call.ownTile?.userID : nil)
            ?? call.participants.first { $0.memberID == memberID }?.userID
        guard let userID else { return nil }
        return room?.memberProfiles[userID]
            ?? ElementCallMemberProfile(userID: userID, displayName: nil, avatarURL: nil)
    }
    
    /// Forwards the caller's position rather than its own, or every line in this file would be
    /// attributed to the line below.
    private func log(_ level: ElementCallLogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        logger?.log(level, message, file: file, line: line)
    }
    
    func fail(_ message: String, diagnostic: String? = nil, generation: UUID) {
        fail(.other(message), diagnostic: diagnostic ?? message, generation: generation)
    }
    
    private func fail(_ failure: ElementCallFailure, diagnostic: String? = nil, generation: UUID) {
        guard isCurrentCall(generation) else { return }
        log(.error, diagnostic ?? "call failed: \(failure)")
        isTeardownPending = true
        connection = .failed(failure)
        Task {
            guard callGeneration == generation else { return }
            await endCall(.left)
        }
    }
    
    /// A failure has ended the call and its screen stays up to say why, until ``hangUp()`` closes
    /// it. Held here rather than left to the host because every host would otherwise dismiss on
    /// ``ElementCallControllerAction/ended`` as before, and the reason would flash and go.
    private var isHoldingFailure = false
    
    /// Tears down what a join produced after the call was ended under it. Leaving is idempotent, so a
    /// call that already left costs nothing to leave again.
    private func abandon(rtcCall: MatrixRTCCall, call: MatrixRTCMediaSession? = nil, roomID: String) async {
        log(.info, "join of \(roomID) was cancelled, releasing what it set up")
        await call?.disconnect()
        await rtcCall.leave()
        // A cancelled join can finish after a replacement starts; only its own room may close.
        if self.rtcCall === rtcCall {
            await shutDownRoom()
        }
        await rtcCall.releaseAudio()
        if self.call === call {
            self.call = nil
        }
        if self.rtcCall === rtcCall {
            self.rtcCall = nil
        }
    }
    
    /// Last, after the leave: the leave goes out through the room.
    private func shutDownRoom() async {
        let rtcRoom = rtcRoom
        self.rtcRoom = nil
        await rtcRoom?.shutdown()
    }
    
    private func endCall(_ reason: MatrixRTCEndReason) async {
        guard !isEndingCall, let roomID = room?.roomID else { return }
        isEndingCall = true
        isTeardownPending = false
        isMediaPublicationReady = false
        log(.info, "ending call in \(roomID) : \(reason)")
        runTask?.cancel()
        runTask = nil
        eventsTask?.cancel()
        eventsTask = nil
        membershipTask?.cancel()
        membershipTask = nil
        statusTask?.cancel()
        statusTask = nil
        signallingTask?.cancel()
        signallingTask = nil
        followedSignalling = .reachable
        interruptionsTask?.cancel()
        interruptionsTask = nil
        interruptionHoldTask?.cancel()
        interruptionHoldTask = nil
        interruptions = []
        pictureInPicture.unbind()
        
        let endedCall = rtcCall
        // Read before the connection is overwritten below: a failure we showed is a failure to the
        // system too, whatever the leave that followed it.
        let systemReason: ElementCallEndReason = if case .failed = connection {
            .failed
        } else {
            Self.systemReason(for: reason)
        }
        await call?.disconnect()
        if let rtcCall {
            if reason == .left {
                let result = await rtcCall.leave()
                lastDeparture = .init(roomID: roomID, result: result)
            } else {
                await rtcCall.mediaSession?.disconnect()
            }
        }
        await shutDownRoom()
        call = nil
        rtcCall = nil
        spotlightTileID = nil
        isSpotlightTileExact = false
        
        if case .connectionClosed(let loss, let message) = reason {
            log(.error, "connection lost (\(loss)): \(message)")
            connection = .failed(.connectionLost(loss))
        } else if case .failed = connection {
            // Keep the failure visible until the screen is dismissed.
        } else {
            connection = .ended(reason)
        }
        connectedAt = nil
        updateProximityMonitoring()
        // The screen closes now (030 R13), and the audio after it: a decline's or a timeout's sound
        // plays to its end first (R25), and the system call ends with it, since ending that is
        // what takes the audio session away. A failure keeps it up instead, brought back from a
        // minimized call if need be, since the reason is on the call screen (034 R27).
        let endedGeneration = callGeneration
        isEndingCall = false
        if case .failed(.other) = connection {
            actionsSubject.send(.ended)
        } else if case .failed = connection {
            isHoldingFailure = true
            if !isMaximized {
                restore()
                actionsSubject.send(.restoreRequested)
            }
        } else {
            actionsSubject.send(.ended)
        }
        if let endedCall {
            await endedCall.releaseAudio()
        }
        // A replacement in a different room has its own system call. Before media is joined,
        // there is no audio suspension between notifying the host and ending the system call.
        if endedCall == nil || callGeneration == endedGeneration || room?.roomID != roomID {
            system.endCall(roomID: roomID, reason: systemReason)
        }
        guard callGeneration == endedGeneration else { return }
        // Paired with the activation in `activateAudio` through the same predicate, so the two
        // cannot disagree about which platforms they apply to and leave the session up. Not under
        // a call started while the sound played out, which has the session now.
        if CallAudioSessionConfigurator.isSelfActivating, !isInCall {
            CallAudioSessionConfigurator.deactivate()
            // Only where we own the session. On device CallKit owns it and reports the
            // deactivation through `didDeactivate`; clearing the flag here instead would mean a
            // second call starting before that arrives never sees an activation of its own, and
            // `startAudioIfReady` would refuse to start audio for a call that is otherwise fine.
            isAudioSessionActive = false
        }
    }
    
    /// Back to idle once the screen has gone; a new call can start.
    public func reset() {
        guard !isInCall, !isTeardownPending else { return }
        isMediaPublicationReady = false
        isHoldingFailure = false
        callData = nil
        room = nil
        connection = .idle
    }
    
    /// Previews and tests only: shows a state without joining anything.
    /// `connectedAt` is defaulted because only a joined call normally has one, and it is offered at
    /// all so the minimized bar's duration timer is reachable without one: it is the single branch
    /// of that view no preview, snapshot or harness could otherwise draw.
    func setPreviewState(callData: ElementCallData,
                         room: any ElementCallRoomContextProtocol,
                         connection: ElementCallConnection,
                         connectedAt: Date? = nil,
                         call: MatrixRTCMediaSession? = nil,
                         rtcCall: MatrixRTCCall? = nil) {
        callGeneration = UUID()
        isTeardownPending = false
        self.callData = callData
        self.room = room
        self.connection = connection
        isMediaPublicationReady = connection == .connected
        self.connectedAt = connectedAt
        self.call = call
        self.rtcCall = rtcCall
        call?.reactionsMode = reactionsPreference.mode
        // The same seed `startCall` makes, so a preview of a connecting call draws the controls a
        // real one would: the camera reads as on for a video call from the moment it is joining,
        // which is what it will join with.
        pendingCameraEnabled = !callData.isAudioCall
    }
}

private extension Clock where Duration == Swift.Duration {
    /// Runs `body` on the main actor once `duration` has passed on this clock, unless cancelled
    /// first. The deadline is taken now, so a manual clock advanced before the task first runs
    /// still fires it.
    func schedule(after duration: Duration, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        let deadline = now.advanced(by: duration)
        return Task { @MainActor in
            try? await sleep(until: deadline, tolerance: nil)
            guard !Task.isCancelled else { return }
            body()
        }
    }
}
