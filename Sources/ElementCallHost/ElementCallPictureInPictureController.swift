//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVKit
import Combine
import ElementCallKit
import Observation
import SwiftUI

enum ElementCallPictureInPictureAction: Sendable {
    case started
    /// The user tapped the window to come back to the app.
    case restoreRequested
    /// The user closed the window: the call should end.
    case closed
    case failed
}

/// The system Picture in Picture window for a video call, showing the spotlight member through an
/// `AVSampleBufferDisplayLayer` (Metal must not draw while the app is inactive).
///
/// The source view is a stable `UIView` the call screen places behind its spotlight tile: AVKit needs it
/// on screen to start automatically when the app is backgrounded, and uses its frame for the shrink.
final class ElementCallPictureInPictureController: NSObject, AVPictureInPictureControllerDelegate {
    private enum StopReason {
        case restore, userClosed, programmatic
    }
    
    /// Place this view in the full-screen call layout; it is created once per controller.
    let sourceView = UIView()
    
    var actions: AnyPublisher<ElementCallPictureInPictureAction, Never> {
        actionsSubject.eraseToAnyPublisher()
    }
    
    private let actionsSubject = PassthroughSubject<ElementCallPictureInPictureAction, Never>()
    
    /// Set by the controller that owns this; nil until then, which only costs a few log lines.
    var logger: (any ElementCallLoggingProtocol)?
    
    /// Mirrors ``ElementCallOptions/isAutomaticPictureInPictureForAudioCallsEnabled``, set at bind.
    var automaticStartIncludesAudioCalls = false
    
    var isActive: Bool {
        pictureInPictureController?.isPictureInPictureActive ?? false
    }
    
    var isPossible: Bool {
        pictureInPictureController?.isPictureInPicturePossible ?? false
    }
    
    var isBound: Bool {
        call != nil
    }
    
    private let contentViewController = AVPictureInPictureVideoCallViewController()
    private let videoView = SampleBufferVideoView()
    private let placeholderHost = UIHostingController(rootView: AnyView(EmptyView()))
    /// Builds the avatar shown when the member in the window has no video (nil = nobody to show).
    var placeholderProvider: ((String?) -> AnyView)?
    private var pictureInPictureController: AVPictureInPictureController?
    private var stopReason: StopReason?
    private var attached: MatrixRTCTileID?
    private var observationTask: Task<Void, Never>?
    private var automaticStartTask: Task<Void, Never>?
    /// Whether a failed start is worth one more attempt. See ``start()``.
    private var pendingStartRetry = false
    private weak var call: MatrixRTCMediaSession?
    private var spotlightProvider: (() -> (tileID: MatrixRTCTileID?, isExact: Bool))?
    
    override init() {
        super.init()
        sourceView.backgroundColor = .clear
        sourceView.isUserInteractionEnabled = false
        let container = UIView()
        container.backgroundColor = .black
        let placeholderView: UIView = placeholderHost.view
        for subview in [videoView, placeholderView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                subview.topAnchor.constraint(equalTo: container.topAnchor),
                subview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
        placeholderHost.view.backgroundColor = .clear
        placeholderHost.view.isHidden = true
        contentViewController.view = container
        contentViewController.addChild(placeholderHost)
        placeholderHost.didMove(toParent: contentViewController)
        contentViewController.preferredContentSize = CGSize(width: 1080, height: 1920)
        videoView.onAspectChange = { [weak self] aspect in
            self?.applyPreferredSize(aspect: aspect)
        }
        videoView.onPixelSizeChange = { [weak self] size in
            guard let self, let call, let attached else { return }
            call.reportDrawnSize(size, slot: videoView.slot, memberID: attached.memberID, kind: attached.kind.videoStreamKind)
        }
    }
    
    /// Binds to a call; the spotlight provider is read whenever the call's video state changes.
    func bind(call: MatrixRTCMediaSession, spotlightProvider: @escaping () -> (tileID: MatrixRTCTileID?, isExact: Bool)) {
        self.call = call
        self.spotlightProvider = spotlightProvider
        if pictureInPictureController == nil, AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(contentSource: .init(activeVideoCallSourceView: sourceView,
                                                                               contentViewController: contentViewController))
            controller.delegate = self
            pictureInPictureController = controller
        }
        observeAutomaticStart()
    }
    
    /// Leaving the app during a full-screen video call shrinks it to the window, like FaceTime
    /// (subject to the system's "Start PiP Automatically" setting).
    ///
    /// An audio call only follows if the host asked for it through
    /// ``ElementCallOptions/isAutomaticPictureInPictureForAudioCallsEnabled``: minimizing on
    /// purpose is one thing, but a window appearing on every app switch to show a still avatar is
    /// another, and CallKit's island already covers that case.
    private func observeAutomaticStart() {
        automaticStartTask?.cancel()
        automaticStartTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        let hasVideo = self.call?.hasVideo ?? false
                        let audioQualifies = self.automaticStartIncludesAudioCalls && self.call != nil
                        self.pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = hasVideo || audioQualifies
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    func start() {
        guard let pictureInPictureController, !pictureInPictureController.isPictureInPictureActive else { return }
        stopReason = nil
        let candidate = applyPreferredSizeForCurrentSource()
        // A video window opened before the layer has any content fails with AVKitErrorDomain -1001.
        // The placeholder is a hosted SwiftUI view and is ready immediately, so only video waits.
        pendingStartRetry = candidate != nil
        pictureInPictureController.startPictureInPicture()
    }
    
    /// Sizes the window for whatever it is about to show, and says what that was.
    ///
    /// Called from ``start()`` and again from `willStart`, because the system opens the window by
    /// itself when `canStartPictureInPictureAutomaticallyFromInline` is set and that path never
    /// goes through `start()`. Both are before the window appears, which is the only time the size
    /// is honoured.
    @discardableResult
    private func applyPreferredSizeForCurrentSource() -> MatrixRTCTileID? {
        let spotlight = spotlightProvider?()
        let candidate = call?.pictureInPictureCandidate(spotlight: spotlight?.tileID, isExact: spotlight?.isExact ?? false)
        if let call, let candidate, let aspect = call.videoAspect(memberID: candidate.memberID, kind: candidate.kind.videoStreamKind) {
            applyPreferredSize(aspect: aspect)
        } else if candidate == nil {
            // Nobody has video, so the window will show the avatar placeholder. Without this it
            // would inherit whatever aspect the last video call left behind — a 9:16 slot with a
            // circle marooned in the middle of it.
            applyPreferredSize(aspect: 1)
        }
        return candidate
    }
    
    private func applyPreferredSize(aspect: CGFloat) {
        let size = aspect >= 1
            ? CGSize(width: 1080, height: (1080 / aspect).rounded())
            : CGSize(width: (1080 * aspect).rounded(), height: 1080)
        guard contentViewController.preferredContentSize != size else { return }
        logger?.log(.info, "picture in picture aspect \(aspect), preferred size \(size)")
        contentViewController.preferredContentSize = size
    }
    
    /// Ends the window from our side (restoring the screen, or the call ended).
    func stop() {
        guard let pictureInPictureController, pictureInPictureController.isPictureInPictureActive else { return }
        stopReason = .programmatic
        pictureInPictureController.stopPictureInPicture()
    }
    
    func unbind() {
        stop()
        detach()
        // A retry armed against the old call must not open a window for the next one.
        videoView.onFirstFrame = nil
        pendingStartRetry = false
        observationTask?.cancel()
        observationTask = nil
        automaticStartTask?.cancel()
        automaticStartTask = nil
        call = nil
        pictureInPictureController = nil
    }
    
    // MARK: - AVPictureInPictureControllerDelegate
    
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            // Attach before the screen collapses so the spotlight stream never goes idle in between.
            self.stopReason = nil
            // The system starts the window by itself when backgrounding a call, which never goes
            // through `start()`; without this such a window keeps whatever size was last set.
            self.applyPreferredSizeForCurrentSource()
            self.observeVideoSource()
        }
    }
    
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            logger?.log(.info, "picture in picture started")
            self.actionsSubject.send(.started)
        }
    }
    
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        // The handler is not Sendable, so it is answered right here; the screen restores on the main
        // actor a moment later, which is what the system animates towards anyway.
        Task { @MainActor in
            self.stopReason = .restore
            self.actionsSubject.send(.restoreRequested)
        }
        completionHandler(true)
    }
    
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            // Neither a restore nor our own stop: the user tapped the close button.
            if self.stopReason == nil {
                self.stopReason = .userClosed
            }
        }
    }
    
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            let reason = self.stopReason
            self.stopReason = nil
            self.observationTask?.cancel()
            self.observationTask = nil
            self.detach()
            logger?.log(.info, "picture in picture stopped (\(reason.map { "\($0)" } ?? "unknown"))")
            if reason == .userClosed {
                self.actionsSubject.send(.closed)
            }
        }
    }
    
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            logger?.log(.warning, "picture in picture failed to start: \(error)")
            
            // Minimizing a video call within a few seconds of connecting fails with
            // AVKitErrorDomain -1001: the layer has no content yet. The same call minimizes
            // cleanly later, so the fix is to wait for a frame rather than to try again straight
            // away, which would fail for exactly the same reason. Only video needs this — the
            // placeholder is a hosted SwiftUI view and is ready the moment it is asked for.
            //
            // Decided before tearing anything down, because waiting for a frame means keeping the
            // stream attached and the source observation running.
            if self.pendingStartRetry {
                self.pendingStartRetry = false
                if self.retryStartOnFirstFrame() {
                    return
                }
            }
            
            // `willStart` has already started this; only `didStop` used to cancel it, so a failed
            // start left an observation loop running for the rest of the call.
            self.observationTask?.cancel()
            self.observationTask = nil
            self.detach()
            self.actionsSubject.send(.failed)
        }
    }
    
    // MARK: - Private
    
    /// Arms a single retry for when the attached stream first draws.
    ///
    /// Returns false when there is nothing to wait for — no stream attached, or one that has
    /// already drawn, in which case -1001 was not about missing content and retrying would only
    /// fail again.
    private func retryStartOnFirstFrame() -> Bool {
        guard attached != nil, !videoView.hasDrawnContent else { return false }
        logger?.log(.info, "picture in picture will retry once the video layer has content")
        videoView.onFirstFrame = { [weak self] in
            guard let self else { return }
            videoView.onFirstFrame = nil
            // Only if nobody restored the call in the meantime.
            guard !isActive, isBound else { return }
            logger?.log(.info, "retrying picture in picture")
            start()
        }
        return true
    }
    
    /// Follows the call's video state while the window is up, switching what it shows.
    private func observeVideoSource() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        self.updateVideoSource()
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
    
    private func updateVideoSource() {
        guard let call else { return }
        let spotlight = spotlightProvider?()
        let candidate = call.pictureInPictureCandidate(spotlight: spotlight?.tileID, isExact: spotlight?.isExact ?? false)
        if candidate == nil {
            // Nobody has video, or the person named has none: show who we are in the call with
            // instead of a black window.
            let shown = call.pictureInPicturePlaceholderMemberID(spotlight: spotlight?.tileID)
            placeholderHost.rootView = placeholderProvider?(shown) ?? AnyView(Color.black)
            placeholderHost.view.isHidden = false
        } else {
            placeholderHost.view.isHidden = true
        }
        guard candidate != attached else { return }
        detach()
        guard let candidate else { return }
        if let aspect = call.videoAspect(memberID: candidate.memberID, kind: candidate.kind.videoStreamKind) {
            applyPreferredSize(aspect: aspect)
        }
        if candidate.memberID == call.localMemberID {
            call.localVideo.attach(videoView.slot)
        } else {
            call.attachVideo(videoView.slot, memberID: candidate.memberID, kind: candidate.kind.videoStreamKind)
        }
        attached = candidate
        logger?.log(.info, "picture in picture showing \(candidate.memberID) (\(candidate.kind))")
    }
    
    private func detach() {
        guard let attached, let call else { return }
        if attached.memberID == call.localMemberID {
            call.localVideo.detach(videoView.slot)
        } else {
            call.detachVideo(videoView.slot, memberID: attached.memberID, kind: attached.kind.videoStreamKind)
        }
        self.attached = nil
        videoView.clear()
    }
}
