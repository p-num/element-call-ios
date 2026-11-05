//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementCallKit
import Foundation
import Synchronization
import Testing

nonisolated struct VideoFrameSlotTests {
    /// The frame callback used to be reabstracted and re-stored on every offer, growing a chain of
    /// thunks that overflowed the stack after a few minutes of video. A hundred thousand offers is
    /// what a five-minute call delivers; invoking and releasing the handler must both stay flat.
    @Test
    func frameCallbackDoesNotGrowWithEveryOffer() {
        let slot = VideoFrameSlot()
        let count = Mutex(0)
        slot.setOnFrame { count.withLock { $0 += 1 } }
        let frame = MatrixRTCVideoFrame(planes: .init(width: 2, height: 2, y: Data(count: 4), u: Data(count: 1), v: Data(count: 1)),
                                        rotation: .deg0,
                                        isMirrored: false)
        
        for _ in 0..<100_000 {
            slot.offer(frame)
        }
        #expect(count.withLock { $0 } == 100_000)
        #expect(slot.take() === frame)
        #expect(slot.take() == nil)
        
        slot.setOnFrame(nil)
        slot.offer(frame)
        #expect(count.withLock { $0 } == 100_000)
    }
    
    /// A LiveKit full restart replaces every remote track, and the reader of the old one is parked
    /// for good: unless the source opens the new track, the tile stays on its last frame.
    @Test
    func aReplacedTrackIsOpenedAgain() async throws {
        let opens = Mutex(0)
        let source = RemoteVideoSource(open: {
            opens.withLock { $0 += 1 }
            return nil
        }, onIdle: { })
        let slot = VideoFrameSlot()
        
        source.attach(slot)
        try await waitFor(opens: 1, in: opens)
        // A second tile on the same track shares the reader.
        source.attach(VideoFrameSlot())
        source.reopen()
        try await waitFor(opens: 2, in: opens)
        source.close()
    }
    
    /// With nobody drawing, the new track waits for the next tile rather than being read for no one.
    @Test
    func aReplacedTrackNobodyDrawsIsOpenedOnTheNextAttach() async throws {
        let opens = Mutex(0)
        let source = RemoteVideoSource(open: {
            opens.withLock { $0 += 1 }
            return nil
        }, onIdle: { })
        let slot = VideoFrameSlot()
        
        source.attach(slot)
        try await waitFor(opens: 1, in: opens)
        source.detach(slot)
        source.reopen()
        try await Task.sleep(for: .milliseconds(50))
        #expect(opens.withLock { $0 } == 1)
        source.attach(slot)
        try await waitFor(opens: 2, in: opens)
        source.close()
    }
    
    private func waitFor(opens expected: Int, in opens: borrowing Mutex<Int>) async throws {
        for _ in 0..<200 where opens.withLock({ $0 }) < expected {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(opens.withLock { $0 } == expected)
    }
}
