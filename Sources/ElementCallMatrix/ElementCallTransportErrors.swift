//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallHost
import ElementCallKit
import Foundation
import MatrixRustSDK

// Failures are passed on with what the homeserver said and never classified here: which refusals
// retire a feature for the session is the core's decision, made from the `errcode` and status.

// Both extensions are `nonisolated` because the module default is `MainActor` and these are pure
// switches over values with no reason to need it. It also lets the tests that exercise them run off
// the main actor, which is what stopped them being billed for time the snapshot tests spent holding
// it -- a two-line comparison below was reported taking 68 seconds on CI, all of it queueing.
nonisolated extension MatrixRTCRoomBridgeError {
    var transportError: MatrixRTCTransportError {
        switch self {
        case .matrixAPI(let errcode, let httpStatus, let message):
            .failed(message, errcode: errcode, httpStatus: httpStatus.flatMap(UInt16.init(exactly:)))
        case .notRunning, .timedOut, .invalidResponse:
            .failed("\(self)")
        }
    }
}

extension Result where Failure == MatrixRTCRoomBridgeError {
    func mapTransportError() throws -> Success {
        switch self {
        case .success(let value): value
        case .failure(let error): throw error.transportError
        }
    }
}

nonisolated extension Error {
    /// The same for failures that come straight off the SDK rather than the bridge. The SDK reports
    /// the homeserver's `errcode` but not its status.
    var transportError: MatrixRTCTransportError {
        if let clientError = self as? ClientError, case .MatrixApi(_, let code, let message, _) = clientError {
            return .failed(message, errcode: code)
        }
        return .failed("\(self)")
    }
}
