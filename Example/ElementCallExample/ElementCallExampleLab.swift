//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
import Combine
import ElementCall
import Foundation
import SwiftUI
import VisionKit

/// What the lab's QR code carries (`element-call-feature-hq/harness/lab.md`, "Accounts and joining"):
///
///     elementcall-lab://join?hs=https://hs-a.192-168-1-10.nip.io&user=alice&password=…&room=!abc:lab-a
///
/// The same parameters on both platforms, the way fixture keys are shared, plus `recovery` and
/// `format` (`current` or `state`, the lab's call format). Unknown parameters are ignored. `-lab <url>` passes one at launch, for `devicectl` and the simulator.
struct ElementCallExampleLabJoin: Equatable {
    static let scheme = "elementcall-lab"
    static let launchArgument = "-lab"
    
    let homeserver: String
    let user: String
    let password: String
    let roomID: String
    /// The account's recovery key, when the lab has one: a new device joins the account's
    /// cross-signing identity with it, so the others accept its media key.
    let recoveryKey: String?
    /// The lab's call format, which its bots use too: a phone in another one would sit in a
    /// silent call of its own.
    let format: MatrixRTCMembershipFormat
    
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let homeserver = value("hs"), let user = value("user"),
              let password = value("password"), let roomID = value("room") else { return nil }
        self.homeserver = homeserver
        self.user = user
        self.password = password
        self.roomID = roomID
        recoveryKey = value("recovery")
        format = MatrixRTCMembershipFormat(labName: value("format"))
    }
    
    /// Where the lab serves its CA: the same name suffix as the homeserver, under `lab.`.
    var certificateURL: URL? {
        Self.certificateURL(homeserver: homeserver)
    }
    
    static func certificateURL(homeserver: String) -> URL? {
        guard let hs = URL(string: homeserver), let host = hs.host(),
              let dot = host.firstIndex(of: ".") else { return nil }
        return URL(string: "https://lab\(host[dot...])/lab-ca.crt")
    }
}

/// Makes the Rust media layer trust the lab's CA. The phone trusts it for the SDK's HTTP once the
/// profile is installed, but the core's token exchange and SFU socket use rustls, which reads
/// `SSL_CERT_FILE` rather than the system's trust settings. So the CA is fetched (over TLS the
/// phone already trusts) and the variable set before anything in the core opens a connection.
enum ElementCallExampleLabTrust {
    static func install(from url: URL?) async {
        guard let url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let dir = URL.applicationSupportDirectory.appending(path: "lab-ca")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: "lab-ca.pem")
            try data.write(to: file)
            setenv("SSL_CERT_FILE", file.path(percentEncoded: false), 1)
        } catch {
            FileHandle.standardError.write(Data("[lab] could not fetch the lab CA from \(url): \(error)\n".utf8))
        }
    }
}

/// The system port for a lab call: no CallKit, so the audio session is ours to activate. The
/// controller starts audio only once the system says the session is up (it normally hears that
/// from CallKit), and on a device nothing else would say it.
@MainActor
final class ElementCallExampleLabSystem: ElementCallSystemProvidingProtocol {
    private let subject = PassthroughSubject<ElementCallSystemEvent, Never>()
    
    var events: AnyPublisher<ElementCallSystemEvent, Never> {
        subject.eraseToAnyPublisher()
    }
    
    func startCall(roomID: String, displayName: String, isVideo: Bool) async {
        do {
            try CallAudioSessionConfigurator.configure()
            try CallAudioSessionConfigurator.activate()
            subject.send(.audioSessionActivated)
        } catch {
            FileHandle.standardError.write(Data("[lab] could not activate the audio session: \(error)\n".utf8))
        }
    }
    
    func reportConnected(roomID: String) { }
    
    func endCall(roomID: String, reason: ElementCallEndReason) {
        subject.send(.audioSessionDeactivated)
        CallAudioSessionConfigurator.deactivate()
    }
    
    func setMicrophoneEnabled(_ enabled: Bool, roomID: String) { }
}

/// The package's log on stderr, beside the core's, which the app already sends there.
struct ElementCallExampleLabLogger: ElementCallLoggingProtocol {
    func log(_ record: ElementCallLogRecord) {
        FileHandle.standardError.write(Data("[ElementCall \(record.level)] \(record.message)\n".utf8))
    }
}

/// The lab tab: the account kept on this phone, back into the call with it or log it out, and the
/// scanner for a code. Scanning the same account's code reuses the kept device; another account's
/// logs the kept one out first.
struct ElementCallExampleLabTab: View {
    /// Something the host wants read, such as why a lab login failed.
    var notice: String?
    /// The kept account's Matrix ID, nil when logged out.
    var account: String?
    /// The kept session's call format, which the lab page's code set.
    var format: MatrixRTCMembershipFormat?
    let onScan: (ElementCallExampleLabJoin) -> Void
    let onRejoin: () -> Void
    let onLogOut: () -> Void
    
    @State private var isScanning = false
    
    var body: some View {
        List {
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("example.notice")
            }
            if let account {
                Section("Signed in") {
                    Text(account)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("example.lab.account")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Call format: \(format?.labLabel ?? "unknown")")
                            .font(.body.bold())
                        Text("Set by the lab page; scan its code again after switching it there.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("example.lab.format")
                    Button {
                        onRejoin()
                    } label: {
                        Label("Rejoin the lab call", systemImage: "phone.arrow.up.right")
                    }
                    .accessibilityIdentifier("example.lab.rejoin")
                    Button(role: .destructive) {
                        onLogOut()
                    } label: {
                        Label("Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .accessibilityIdentifier("example.lab.logout")
                }
            }
            Section {
                Button {
                    isScanning = true
                } label: {
                    Label("Scan a lab code", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("example.lab.scan")
                .sheet(isPresented: $isScanning) {
                    ElementCallExampleLabScanner { join in
                        isScanning = false
                        onScan(join)
                    }
                }
            } footer: {
                Text(account == nil
                    ? "Scan an account's code on the lab page to log in and join its call."
                    : "A code for another account logs this one out first.")
            }
        }
    }
}

/// The camera on the lab page, from inside the app: one code at a time, the one in the middle of
/// the frame, where the system camera app tries to open whichever of the page's codes it sees first.
struct ElementCallExampleLabScanner: UIViewControllerRepresentable {
    let onScan: (ElementCallExampleLabJoin) -> Void
    
    func makeUIViewController(context: Context) -> UIViewController {
        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            return UIHostingController(rootView: Text("No camera to scan with on this device."))
        }
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced,
                                                recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }
    
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (ElementCallExampleLabJoin) -> Void
        private var done = false
        
        init(onScan: @escaping (ElementCallExampleLabJoin) -> Void) {
            self.onScan = onScan
        }
        
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let url = URL(string: payload),
                      let join = ElementCallExampleLabJoin(url: url) else { continue }
                done = true
                dataScanner.stopScanning()
                onScan(join)
                return
            }
        }
    }
}
