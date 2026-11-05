//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

// Deliberately the only import: this file exists to prove that one import reaches all three
// modules and the core's bindings. Adding `import ElementCallKit` here to fix a build failure would defeat it — fix the
// re-export in Sources/ElementCall instead.
import ElementCall
import Testing

/// The umbrella is a compile-time promise, so these are compile-time assertions that happen to run.
nonisolated struct UmbrellaProductTests {
    @Test
    func reachesEveryModuleThroughOneImport() {
        // ElementCallKit
        #expect(MatrixRTCStreamKind.camera != .screenShare)
        // ElementCallHost
        #expect(ElementCallOptions().isPictureInPictureEnabled)
        // ElementCallUI
        #expect(!ElementCallAccessibilityIdentifiers.minimizedBar.isEmpty)
        // That a host can implement the backend the stack takes: the protocol comes from
        // ElementCallKit and the conformance from ElementCallHost.
        let backend: any ElementCallMatrixBackendProtocol = ElementCallFakeMatrixBackend()
        #expect(backend.userID == "@alice:example.org")
        // The core's bindings.
        #expect(!sdkVersion().isEmpty)
    }
}
