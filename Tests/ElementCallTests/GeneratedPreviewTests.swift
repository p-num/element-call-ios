// Generated using Sourcery 2.3.0 — https://github.com/krzysztofzablocki/Sourcery
// DO NOT EDIT

// swiftlint:disable all
// swiftformat:disable all

import Testing
@testable import ElementCallUI

extension PreviewTests {

    // MARK: - PreviewProvider

    @Test("ElementCallControlsView")
    func elementCallControlsView() async throws {
        for (index, preview) in ElementCallControlsView_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallFailureView")
    func elementCallFailureView() async throws {
        for (index, preview) in ElementCallFailureView_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallFullscreenChrome")
    func elementCallFullscreenChrome() async throws {
        for (index, preview) in ElementCallFullscreenChrome_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallInterruptionsIndicator")
    func elementCallInterruptionsIndicator() async throws {
        for (index, preview) in ElementCallInterruptionsIndicator_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallPreferencesSheet")
    func elementCallPreferencesSheet() async throws {
        for (index, preview) in ElementCallPreferencesSheet_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallReactionsOverlay")
    func elementCallReactionsOverlay() async throws {
        for (index, preview) in ElementCallReactionsOverlay_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallStage")
    func elementCallStage() async throws {
        for (index, preview) in ElementCallStage_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallTileView")
    func elementCallTileView() async throws {
        for (index, preview) in ElementCallTileView_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }

    @Test("ElementCallView")
    func elementCallView() async throws {
        for (index, preview) in ElementCallView_Previews._allPreviews.enumerated() {
            try await assertSnapshots(matching: preview, step: index)
        }
    }
}

// swiftlint:enable all
// swiftformat:enable all
