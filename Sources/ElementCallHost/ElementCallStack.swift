//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import ElementCallKit
import Foundation

/// Everything the host needs to hold on to, built once per logged-in session. There is nothing to
/// start: the core subscribes to a room, and to the media keys sent for it, when a call opens it.
@MainActor
public final class ElementCallStack {
    /// The call, whether or not one is in progress. Observable, so a view can be driven straight
    /// from it.
    public let controller: ElementCallController
    
    public init(transport: any ElementCallMatrixTransportProtocol,
                system: any ElementCallSystemProvidingProtocol,
                options: ElementCallOptions = .init(),
                style: ElementCallStyle = .stock,
                logger: (any ElementCallLoggingProtocol)? = nil) {
        controller = ElementCallController(rtcClient: MatrixRTCClient(transport: transport),
                                           system: system,
                                           options: options,
                                           style: style,
                                           logger: logger)
    }
}
