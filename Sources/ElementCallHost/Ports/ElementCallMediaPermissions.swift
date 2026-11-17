//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import UIKit

// The microphone and camera permissions, behind a seam so a test can answer them (042). No host has
// to implement this: the system implementation is the default, and a host's own tests of a real
// controller pass ``ElementCallFakeMediaPermissions`` instead of meeting the system's dialog.
// The controller owns microphone authorization for every native start, including ordinary and
// waiting incoming answers. A host may read permission state for entry preflight, but must not
// request it in parallel. Cancel or expire an answer through hangUp(); a late reply cannot join it.

public nonisolated enum ElementCallMediaDevice: Sendable, Equatable {
    case microphone
    case camera
}

public nonisolated enum ElementCallMediaPermission: Sendable, Equatable {
    /// The system has never asked: a request shows its dialog.
    case notAsked
    case granted
    /// Refused, and for the camera also restricted (Screen Time, device management): a request
    /// answers no at once, with no dialog.
    case refused
}

@MainActor
public protocol ElementCallMediaPermissionsProtocol: AnyObject {
    /// Read afresh each time: a grant made in Settings since the last read counts (042 R12).
    func permission(for device: ElementCallMediaDevice) -> ElementCallMediaPermission
    /// Shows the system dialog when the permission is ``ElementCallMediaPermission/notAsked``;
    /// answers at once otherwise.
    func request(_ device: ElementCallMediaDevice) async -> Bool
    /// The app's own page in the system Settings.
    func openSettings()
}

/// The default: `AVAudioApplication` for the microphone, `AVCaptureDevice` for the camera.
@MainActor
public final class ElementCallSystemMediaPermissions: ElementCallMediaPermissionsProtocol {
    public init() { }
    
    public func permission(for device: ElementCallMediaDevice) -> ElementCallMediaPermission {
        switch device {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .undetermined: .notAsked
            default: .refused
            }
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: .granted
            case .notDetermined: .notAsked
            default: .refused
            }
        }
    }
    
    public func request(_ device: ElementCallMediaDevice) async -> Bool {
        switch device {
        case .microphone: await AVAudioApplication.requestRecordPermission()
        case .camera: await AVCaptureDevice.requestAccess(for: .video)
        }
    }
    
    public func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
