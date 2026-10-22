//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
import ElementCallHost
import ElementCallKit
import SwiftUI

/// The full-screen call. This is what a host presents.
///
/// The view model is passed in rather than built here so the host owns its lifetime, which is what
/// its own coordinators expect, and so the observation it starts is not restarted by a redraw.
///
/// Everything the inner view needs, the Picture in Picture anchor, the live call for the video
/// tiles, and the host's style, is wired here rather than being asked of the host.
public struct ElementCallScreen: View {
    private let viewModel: ElementCallScreenViewModel
    
    public init(viewModel: ElementCallScreenViewModel) {
        self.viewModel = viewModel
    }
    
    public var body: some View {
        ElementCallView(context: viewModel.context,
                        pictureInPictureSourceView: viewModel.pictureInPictureSourceView) { [viewModel] in
            viewModel.call
        }
        .environment(\.elementCallStyle, viewModel.context.style)
        .reportInterfaceOrientation { [viewModel] in viewModel.call }
    }
}

/// Keeps the capturer's idea of which way up the phone is in step with the interface.
///
/// The camera tags what it sends with the interface orientation so the far end can turn it back the
/// right way, and until now nothing told it when that changed: rotate mid-call and everyone else
/// watched you sideways for the rest of it, because the orientation was read once when the camera
/// started and never again.
///
/// It reads the scene's interface orientation rather than the device's, because that is the one the
/// capturer is compensating for and the two disagree whenever rotation is locked. But it listens for
/// the *device* notification, because the interface orientation is a property with nothing to
/// subscribe to, and because a half turn from portrait to upside down changes it while changing no
/// size a layout could have noticed.
private struct InterfaceOrientationReporter: ViewModifier {
    let callProvider: () -> MatrixRTCMediaSession?
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                report()
            }
            .onAppear {
                // UIKit only posts the notification while someone has asked for it. Paired with the
                // end below, which is refcounted, so this does not disturb anyone else asking.
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                report()
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
    }
    
    private func report() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        callProvider()?.updateInterfaceOrientation(scene.interfaceOrientation)
    }
}

private extension View {
    func reportInterfaceOrientation(_ callProvider: @escaping () -> MatrixRTCMediaSession?) -> some View {
        modifier(InterfaceOrientationReporter(callProvider: callProvider))
    }
}
