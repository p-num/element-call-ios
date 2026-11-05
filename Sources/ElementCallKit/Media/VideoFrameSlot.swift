//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Foundation
import MatrixRtc
import Synchronization

/// The latest frame for one renderer. Overwriting releases the previous frame (dropping is the
/// normal case under load, and must never become back-pressure on the decoder or a leak).
public final nonisolated class VideoFrameSlot: Sendable, Identifiable {
    public let id = UUID()
    /// Boxed on purpose: a function value kept directly in a generic `Mutex` is reabstracted on
    /// every `withLock` and written back wrapped in one more thunk, so the stored closure grew by
    /// two frames per offered video frame until invoking or releasing it overflowed the stack.
    private struct FrameHandler {
        let call: @Sendable () -> Void
    }
    
    private let latest = Mutex<MatrixRTCVideoFrame?>(nil)
    private let onFrame = Mutex<FrameHandler?>(nil)
    private let firstFrame = Mutex<FrameHandler?>(nil)
    private let hasFrame = Atomic<Bool>(false)
    
    /// Whether this slot has ever been offered a frame since the last ``clear()``.
    ///
    /// A tile draws video when the roster says the member publishes a camera, which is a claim
    /// about signalling rather than about pixels. When the two disagree — the roster is stale, or
    /// the far end publishes a track it never sends on — the tile used to be a black rectangle
    /// with nothing to explain it. This is how a surface knows to keep showing the avatar.
    public var hasReceivedFrame: Bool {
        hasFrame.load(ordering: .relaxed)
    }
    
    public init() { }
    
    public func offer(_ frame: MatrixRTCVideoFrame) {
        latest.withLock { $0 = frame }
        // Fired once per clear, off the render path after the first frame: the exchange is what
        // makes it once, so a surface can swap the avatar out without polling.
        if !hasFrame.exchange(true, ordering: .relaxed) {
            firstFrame.withLock { $0 }?.call()
        }
        onFrame.withLock { $0 }?.call()
    }
    
    /// Called on the offering thread the first time a frame arrives, and again after a ``clear()``.
    /// Separate from ``setOnFrame(_:)``, which the renderer owns.
    public func setOnFirstFrame(_ handler: (@Sendable () -> Void)?) {
        let boxed = handler.map(FrameHandler.init)
        firstFrame.withLock { $0 = boxed }
    }
    
    /// Takes the pending frame, leaving the slot empty.
    public func take() -> MatrixRTCVideoFrame? {
        latest.withLock { frame in
            defer { frame = nil }
            return frame
        }
    }
    
    /// Called on the offering thread whenever a frame arrives; renderers use it to request a draw.
    public func setOnFrame(_ handler: (@Sendable () -> Void)?) {
        let boxed = handler.map(FrameHandler.init)
        onFrame.withLock { $0 = boxed }
    }
    
    public func clear() {
        latest.withLock { $0 = nil }
        // A slot is reused when its tile changes member, so the next stream has to earn its
        // first frame again rather than inheriting the previous one's.
        hasFrame.store(false, ordering: .relaxed)
    }
}

/// One decoding stream per `(member, kind)`, fanned out to every tile drawing it.
///
/// Opening the stream is what makes the core decode at all, so a stream nobody draws costs
/// nothing. Two handles on one track crash the core, hence exactly one per key, and a linger before
/// closing: SwiftUI disposes the old tile before creating the new one when a member moves between
/// spotlight and strip, and tearing the stream down in that gap raced a frame in flight.
final nonisolated class RemoteVideoSource: @unchecked Sendable {
    static let linger: Duration = .seconds(2)
    
    private let open: @Sendable () -> VideoFrameStreamBox?
    /// Whose stream this is, for the log: `member/kind`.
    private let label: String
    /// Numbers the readers, so the log tells a reader parked on an old stream from its successor.
    private let readers = Mutex<Int>(0)
    /// Called when the last tile has gone and the linger elapsed: nobody is drawing this stream.
    private let onIdle: @Sendable () -> Void
    /// What the linger runs on: the call's clock, so a scenario can step past it. The fifth timer
    /// the harness has to own, and the one the plan's list missed because it lives here rather
    /// than on the call.
    private let clock: any Clock<Duration>
    /// The upright size and frame rate of the decoded frames, about once a second.
    var onVideoInfo: (@Sendable (MatrixRTCVideoInfo) -> Void)?
    private let meter = VideoFrameMeter()
    private let state = Mutex<State>(.init())
    
    private struct State {
        var slots = [UUID: VideoFrameSlot]()
        var reader: Task<Void, Never>?
        var lingerTask: Task<Void, Never>?
    }
    
    init(label: String = "",
         open: @escaping @Sendable () -> VideoFrameStreamBox?,
         onIdle: @escaping @Sendable () -> Void,
         clock: any Clock<Duration> = ContinuousClock()) {
        self.label = label
        self.open = open
        self.onIdle = onIdle
        self.clock = clock
    }
    
    func attach(_ slot: VideoFrameSlot) {
        state.withLock { state in
            state.slots[slot.id] = slot
            MatrixRTCLog.info("Video \(label): slot attached (\(state.slots.count) drawing, reader \(state.reader == nil ? "none" : "kept"))")
            state.lingerTask?.cancel()
            state.lingerTask = nil
            if state.reader == nil {
                state.reader = startReader()
            }
        }
    }
    
    /// Whether this slot is attached here: false for one whose source was closed under it.
    func holds(_ slot: VideoFrameSlot) -> Bool {
        state.withLock { $0.slots[slot.id] != nil }
    }
    
    func detach(_ slot: VideoFrameSlot) {
        state.withLock { state in
            state.slots[slot.id] = nil
            MatrixRTCLog.info("Video \(label): slot detached (\(state.slots.count) drawing)")
            slot.clear()
            guard state.slots.isEmpty, state.lingerTask == nil else { return }
            let clock = clock
            state.lingerTask = Task { [weak self] in
                try? await clock.sleep(for: Self.linger)
                guard !Task.isCancelled else { return }
                self?.closeIfIdle()
            }
        }
    }
    
    /// The member's track was replaced: read the new one. The old reader is parked on a track that
    /// will never send again, so it is cancelled rather than waited for, and it can no longer offer
    /// a frame if that track does wake. Opening here does not break the rule below, which is about
    /// two streams on one track. With no tile drawing, the next attach opens it.
    func reopen() {
        MatrixRTCLog.info("Video \(label): reopening on a new track")
        state.withLock { state in
            state.reader?.cancel()
            state.reader = state.slots.isEmpty ? nil : startReader()
        }
    }
    
    /// The member left: stop reading their track and blank the tiles, but keep the tiles attached.
    /// A member who comes back within one layout pass keeps their tile mounted, and that tile never
    /// attaches again; their returning stream then reopens here, onto the tiles still held.
    func suspend() {
        MatrixRTCLog.info("Video \(label): suspended, the member left")
        state.withLock { state in
            state.reader?.cancel()
            state.reader = nil
            state.slots.values.forEach { $0.clear() }
        }
    }
    
    func close() {
        MatrixRTCLog.info("Video \(label): closed")
        state.withLock { state in
            state.reader?.cancel()
            state.reader = nil
            state.lingerTask?.cancel()
            state.lingerTask = nil
            state.slots.values.forEach { $0.clear() }
            state.slots.removeAll()
        }
    }
    
    /// Nobody is drawing: stop asking the SFU for frames, but keep the reader. The FFI stream has no
    /// `close()` and `next()` cannot be cancelled, so a reader parked on a quiet stream would stay
    /// alive, and opening a second stream on the same track crashes the core. Reattaching reuses it.
    private func closeIfIdle() {
        let idle = state.withLock { state -> Bool in
            guard state.slots.isEmpty else { return false }
            state.lingerTask = nil
            return true
        }
        if idle {
            MatrixRTCLog.info("Video \(label): idle, nobody drawing; the reader is kept")
            onIdle()
        }
    }
    
    private func reportAspect(of frame: MatrixRTCVideoFrame) {
        if let info = meter.record(frame) {
            onVideoInfo?(info)
        }
    }
    
    private func startReader() -> Task<Void, Never> {
        let open = open
        let label = label
        let number = readers.withLock { count -> Int in
            count += 1
            return count
        }
        return Task.detached(priority: .userInitiated) { [weak self] in
            guard let stream = open() else {
                MatrixRTCLog.warning("Video \(label): reader \(number) found no stream to open")
                return
            }
            MatrixRTCLog.info("Video \(label): reader \(number) opened its stream")
            var frames = 0
            defer {
                stream.close()
                MatrixRTCLog.info("Video \(label): reader \(number) ended after \(frames) frame(s)\(Task.isCancelled ? ", cancelled" : "")")
            }
            while !Task.isCancelled, let ref = await stream.next() {
                guard let self, !Task.isCancelled else { return }
                frames += 1
                if frames == 1 {
                    MatrixRTCLog.info("Video \(label): reader \(number) got its first frame")
                }
                let frame = MatrixRTCVideoFrame(ref: ref)
                reportAspect(of: frame)
                let slots = state.withLock { Array($0.slots.values) }
                // Every slot holds its own reference; the frame is freed once the last one drops it.
                for slot in slots {
                    slot.offer(frame)
                }
            }
        }
    }
}

/// Wraps the FFI stream so the reader can close it explicitly when cancelled.
final nonisolated class VideoFrameStreamBox: @unchecked Sendable {
    private let stream: MatrixRtc.VideoFrameStream
    
    init(_ stream: MatrixRtc.VideoFrameStream) {
        self.stream = stream
    }
    
    func next() async -> MatrixRtc.VideoFrameRef? {
        await stream.next()
    }
    
    func close() {
        // Dropping the last reference closes the stream on the Rust side.
    }
}
