//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCall
import Foundation
import Synchronization

/// Pushes generated frames into whatever slots the stage has mounted, at something like a call's
/// frame rate.
///
/// This is what makes the harness worth having for the renderer rather than only for the layout.
/// With avatars in every tile, fitting against filling, zoom, pan and — above all — the shape of the
/// picture *through* a move are all invisible, and a move is the hardest thing to look at closely in
/// a real call.
///
/// Sizes differ by member on purpose. A 16:9 landscape picture full screen on an upright phone is
/// the case this feature exists for, and a portrait one beside it is the control: whether a border
/// runs off the edges or has black beside it is the whole question, and one answer is not proof.
///
/// **Frames are made off the main thread**, as a real call's are: the decoder offers them from its
/// own task. Generating them on main, on a run loop timer, charged the harness's scroll with work
/// the app never does, which is the wrong way round for anything measured with it. A dispatch timer
/// also has no run loop mode to get wrong: a default-mode `Timer` stopped while a touch was being
/// tracked, and starved the tiles of frames for exactly the length of a gesture.
final class TestPatternVideo: Sendable {
    private struct Attachment {
        let slot: VideoFrameSlot
        let memberID: String
    }
    
    private struct State {
        var attachments: [UUID: Attachment] = [:]
        /// The stage's shape, which our own camera's picture follows.
        var isLandscape = false
        /// The last frame made at each width, so a slot that mounts is handed one at once, without
        /// making another picture on the thread that is mounting it.
        var latest: [Int: MatrixRTCVideoFrame] = [:]
        var timer: DispatchSourceTimer?
        var phase = 0
    }
    
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "io.element.call.example.test-pattern", qos: .userInitiated)
    
    /// Landscape unless the member is one of these, so both shapes are on the stage at once.
    private static let portraitMembers = ["@bob:example.com:DEVICE", "@erin:example.com:DEVICE"]
    /// Ourselves, Alice in every fixture. Our picture is upright in the interface orientation, as a
    /// real front camera's is, so it is portrait on an upright phone and landscape on its side: the
    /// floating tile takes that shape (019 R10, R29), and with a fixed shape the harness only ever
    /// showed one of them.
    private static let ownMemberID = "@alice:example.com:DEVICE"
    /// Deliberately modest. In a real call every tile is sent a layer that suits the size it is
    /// drawn at, so a strip cell a couple of hundred points wide never receives 720p; handing every
    /// tile a full-size frame is both far more work than the real thing and less like it. Nothing
    /// the harness is for — fitting, zoom, pan, the shape of a picture through a move — depends on
    /// how sharp the picture is.
    private static let landscape = CGSize(width: 640, height: 360)
    private static let portrait = CGSize(width: 360, height: 640)
    
    var source: ElementCallPreviewVideo {
        ElementCallPreviewVideo(attach: { [weak self] slot, memberID, _ in
            self?.attach(slot, memberID: memberID)
        }, detach: { [weak self] slot in
            self?.detach(slot)
        })
    }
    
    /// The stage turned. Our own picture changes shape on the next frame, as a camera's does.
    func setLandscape(_ isLandscape: Bool) {
        state.withLock { $0.isLandscape = isLandscape }
    }
    
    private static func size(for memberID: String, isLandscape: Bool) -> CGSize {
        if memberID == ownMemberID {
            return isLandscape ? landscape : portrait
        }
        return portraitMembers.contains(memberID) ? portrait : landscape
    }
    
    private func attach(_ slot: VideoFrameSlot, memberID: String) {
        let latest = state.withLock { state in
            state.attachments[slot.id] = Attachment(slot: slot, memberID: memberID)
            return state.latest[Int(Self.size(for: memberID, isLandscape: state.isLandscape).width)]
        }
        // The first frame goes in straight away: a slot mounted mid-animation would otherwise show
        // its avatar until the next tick, which is the very stutter this is here to look for.
        if let latest {
            slot.offer(latest)
        } else {
            queue.async { self.tick(advancing: false) }
        }
        start()
    }
    
    private func detach(_ slot: VideoFrameSlot) {
        state.withLock { state in
            state.attachments[slot.id] = nil
            if state.attachments.isEmpty {
                state.timer?.cancel()
                state.timer = nil
            }
        }
    }
    
    /// One frame per distinct size per tick, handed to every slot that wants that size. Frames are
    /// immutable reference types, so sharing one is just a retain, where generating six identical
    /// pictures was six times the work for the same result.
    private func tick(advancing: Bool) {
        let (attachments, phase, isLandscape) = state.withLock { state in
            if advancing {
                state.phase += 8
            }
            return (Array(state.attachments.values), state.phase, state.isLandscape)
        }
        // Keyed by width, which is enough to tell the two sizes apart and saves making CGSize
        // hashable from outside the module that owns it.
        var generated: [Int: MatrixRTCVideoFrame] = [:]
        for attachment in attachments {
            let size = Self.size(for: attachment.memberID, isLandscape: isLandscape)
            let width = Int(size.width)
            let frame = generated[width] ?? MatrixRTCTestPattern.frame(width: width,
                                                                       height: Int(size.height),
                                                                       phase: phase)
            generated[width] = frame
            attachment.slot.offer(frame)
        }
        state.withLock { $0.latest.merge(generated) { $1 } }
    }
    
    private func start() {
        state.withLock { state in
            guard state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30))
            timer.setEventHandler { [weak self] in
                self?.tick(advancing: true)
            }
            timer.resume()
            state.timer = timer
        }
    }
}
