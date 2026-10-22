//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@preconcurrency import AVFoundation
import CoreMedia
import MatrixRtc
import Synchronization
import UIKit

/// The local camera, published straight from the capture queue (`captureVideo` is synchronous).
///
/// Turning the camera off releases the device — the indicator going out is the point — while the
/// track stays published and muted at the transport, so peers see a deliberate camera-off rather
/// than a track disappearing.
final nonisolated class CameraCapturer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// The cameras the capturer chooses between. One query for both it and ``hasFrontAndBack``, so
    /// the flip button is offered on exactly the devices where flipping changes something.
    private static func discoverCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
    }
    
    /// The requested camera, or whatever exists rather than refusing.
    private static func camera(front: Bool) -> AVCaptureDevice? {
        let devices = discoverCameras()
        return devices.first { $0.position == (front ? .front : .back) } ?? devices.first
    }
    
    /// The camera's format and the size its frames are sent at, from the formats our pixel format
    /// comes in: another subtype would be converted on every frame.
    private static func captureFormat(of device: AVCaptureDevice) -> (AVCaptureDevice.Format, CameraCaptureFormat)? {
        let formats = device.formats.filter { CMFormatDescriptionGetMediaSubType($0.formatDescription) == pixelFormat }
        let candidates = formats.map { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CameraCaptureFormat.Candidate(width: Int(dimensions.width),
                                                 height: Int(dimensions.height),
                                                 maxFrameRate: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0,
                                                 fieldOfView: Double(format.videoFieldOfView),
                                                 isBinned: format.isVideoBinned)
        }
        return CameraCaptureFormat.choose(from: candidates).map { (formats[$0.candidate], $0) }
    }
    
    private static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    
    /// The size the camera that ``start(track:)`` opens will send, for the publish that precedes it:
    /// the layers are derived from it, so it has to be what the frames really are.
    var publishedSize: CameraCaptureFormat.Size {
        Self.camera(front: isFrontFacing).flatMap(Self.captureFormat)?.1.output ?? CameraCaptureFormat.fallbackOutput
    }
    
    static var hasFrontAndBack: Bool {
        let positions = Set(discoverCameras().map(\.position))
        return positions.contains(.front) && positions.contains(.back)
    }
    
    /// Every format a camera offers, one per line: what a bug report needs to answer "what could this
    /// phone have captured", since the choice between them is ours.
    static func describeFormats(of device: AVCaptureDevice) -> String {
        let lines = device.formats.map { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: subtype >> $0) }, encoding: .ascii) ?? "\(subtype)"
            let rates = format.videoSupportedFrameRateRanges.map { "\(Int($0.minFrameRate))-\(Int($0.maxFrameRate))" }.joined(separator: ",")
            return "  \(dimensions.width)x\(dimensions.height) \(fourCC) \(rates) fps fov \(String(format: "%.1f", format.videoFieldOfView))\(format.isVideoBinned ? " binned" : "")"
        }
        return (["Camera formats, \(device.position == .front ? "front" : "back") \(device.localizedName):"] + lines).joined(separator: "\n")
    }
    
    private let queue = DispatchQueue(label: "io.element.matrixrtc.camera", qos: .userInitiated)
    private let state = Mutex<State>(.init())
    private let onLocalFrame: @Sendable (MatrixRTCVideoFrame) -> Void
    /// The system took the camera away (app in the background, another app using it) or gave it back.
    /// Without the multitasking-camera entitlement this fires on every backgrounding.
    var onInterruption: (@Sendable (Bool) -> Void)?
    private var interruptionObservers: [NSObjectProtocol] = []
    
    private struct State {
        var session: AVCaptureSession?
        var track: FfiLocalTrack?
        var isFrontFacing = true
        var rotation: FfiVideoRotation = .deg0
    }
    
    /// - Parameter onLocalFrame: a copy of each published frame for the self view.
    init(onLocalFrame: @escaping @Sendable (MatrixRTCVideoFrame) -> Void) {
        self.onLocalFrame = onLocalFrame
        super.init()
        let center = NotificationCenter.default
        interruptionObservers = [
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let self, notification.object as? AVCaptureSession === state.withLock({ $0.session }) else { return }
                let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).flatMap(AVCaptureSession.InterruptionReason.init)
                MatrixRTCLog.info("Camera interrupted: \(reason.map { "\($0)" } ?? "unknown reason")")
                onInterruption?(true)
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: nil, queue: nil) { [weak self] notification in
                guard let self, notification.object as? AVCaptureSession === state.withLock({ $0.session }) else { return }
                MatrixRTCLog.info("Camera interruption ended")
                onInterruption?(false)
            },
            // The one fact about heat a bug report can carry: the camera's encode is the call's
            // largest cost, and whether it heats a phone is measured rather than assumed.
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
                let state = switch ProcessInfo.processInfo.thermalState {
                case .nominal: "nominal"
                case .fair: "fair"
                case .serious: "serious"
                case .critical: "critical"
                @unknown default: "unknown"
                }
                MatrixRTCLog.info("Thermal state \(state)")
            }
        ]
    }
    
    deinit {
        interruptionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    
    var isFrontFacing: Bool {
        state.withLock { $0.isFrontFacing }
    }
    
    func start(track: FfiLocalTrack) throws {
        state.withLock { $0.track = track }
        let front = isFrontFacing
        try configureSession(front: front)
    }
    
    /// Stops on the capture queue (never blocking the caller); the session is kept alive by the
    /// closure until it has really stopped, which is what makes dropping it safe.
    func stop() {
        let session = state.withLock { state -> AVCaptureSession? in
            defer {
                state.session = nil
                state.track = nil
            }
            return state.session
        }
        guard let session else { return }
        queue.async {
            session.stopRunning()
            MatrixRTCLog.info("Camera released")
        }
    }
    
    /// Asynchronous by nature: one camera closes and another opens.
    func switchCamera() throws -> Bool {
        let front = !isFrontFacing
        try configureSession(front: front)
        return isFrontFacing
    }
    
    /// Called by the owner when the interface orientation changes; frames carry it, pixels are not rotated.
    func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        // Same table as libwebrtc's RTCCameraVideoCapturer, expressed in interface orientation
        // (interface landscapeLeft is the device turned to landscapeRight).
        let rotation: FfiVideoRotation = switch orientation {
        case .portrait: .deg90
        case .portraitUpsideDown: .deg270
        case .landscapeLeft: isFrontFacing ? .deg0 : .deg180
        case .landscapeRight: isFrontFacing ? .deg180 : .deg0
        default: .deg90
        }
        state.withLock { $0.rotation = rotation }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let planes = I420Repacker.repack(pixelBuffer) else { return }
        let (track, rotation) = state.withLock { ($0.track, $0.rotation) }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = Int64(CMTimeGetSeconds(timestamp) * 1_000_000)
        
        let frame = planes.ffiFrame(rotation: rotation, timestampUs: timestampUs)
        onLocalFrame(MatrixRTCVideoFrame(planes: planes, rotation: .init(rotation), isMirrored: isFrontFacing))
        
        guard let track else { return }
        do {
            try track.captureVideo(frame: frame)
        } catch {
            MatrixRTCLog.warning("captureVideo failed: \(error)")
        }
    }
    
    // MARK: - Private
    
    private func configureSession(front: Bool) throws {
        guard let device = Self.camera(front: front) else {
            throw MatrixRTCError.media("No camera available")
        }
        MatrixRTCLog.debug(Self.describeFormats(of: device))
        guard let (format, choice) = Self.captureFormat(of: device) else {
            throw MatrixRTCError.media("No camera format in \(Self.pixelFormat)")
        }
        let input = try AVCaptureDeviceInput(device: device)
        
        let output = AVCaptureVideoDataOutput()
        // The output scales to the size the layers were declared for; iOS honours the size keys.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Self.pixelFormat,
                                kCVPixelBufferWidthKey as String: choice.output.width,
                                kCVPixelBufferHeightKey as String: choice.output.height]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MatrixRTCError.media("Cannot configure the camera session")
        }
        session.addInput(input)
        session.addOutput(output)
        // After the input is added, and with no `sessionPreset`: a preset applies its own format.
        // Setting the format is what moves the session to `.inputPriority`, and it holds through
        // `startRunning`.
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let maxFrameRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? CameraCaptureFormat.frameRate
            // A ceiling only: the camera may still slow down in the dark to keep the picture exposed.
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(min(CameraCaptureFormat.frameRate, maxFrameRate)))
            device.unlockForConfiguration()
        } catch {
            MatrixRTCLog.warning("Cannot choose the camera format: \(error)")
        }
        // Sensor-native frames, with the rotation travelling as metadata: a rotation then changes
        // neither the frame size nor the track. Upright frames would turn 960x720 into 720x960 on
        // every rotation, and each receiver would freeze until the encoder's next key frame.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
        session.commitConfiguration()
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        MatrixRTCLog.info("Camera format \(dimensions.width)x\(dimensions.height)\(format.isVideoBinned ? " binned" : "") "
            + "\(String(format: "%.1f", format.videoFieldOfView))°, sending \(choice.output.width)x\(choice.output.height)")
        
        let previous = state.withLock { state -> AVCaptureSession? in
            defer {
                state.session = session
                state.isFrontFacing = device.position == .front
            }
            return state.session
        }
        // startRunning blocks; never on the main thread.
        queue.async {
            previous?.stopRunning()
            session.startRunning()
            MatrixRTCLog.info("Camera started (\(device.position == .front ? "front" : "back"))")
        }
    }
}
