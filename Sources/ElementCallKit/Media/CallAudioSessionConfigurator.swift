//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation

/// Configures the shared audio session for a call. Never activates it when CallKit is in charge —
/// CallKit activates the session and reports it through `didActivate`, and activating it ourselves
/// makes that callback fire twice or not at all.
public nonisolated enum CallAudioSessionConfigurator {
    /// No `.defaultToSpeaker` here on purpose: with it, clearing the output override still lands on
    /// the speaker and the earpiece becomes unreachable. Video calls ask for the speaker explicitly
    /// once the session is active (`setLoudspeaker`).
    public static func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        try session.setPreferredSampleRate(Double(AudioFormat.sampleRate))
        try session.setPreferredIOBufferDuration(0.01)
    }
    
    /// Whether *we* have to activate the session because nothing else will.
    ///
    /// Normally CallKit does it and reports back through `didActivate`, and activating it
    /// ourselves as well makes that callback fire twice or not at all. Two runtimes have no
    /// CallKit to do it:
    ///
    /// - the simulator, which is a compile-time fact;
    /// - an iOS app running on macOS, which is **not**. Such a binary is `platform IOS` and is
    ///   neither a simulator nor Catalyst, so no `#if` can see it and the question has to be asked
    ///   of `ProcessInfo` at runtime. Getting this wrong is not a degraded call but a silent one:
    ///   the session never activates, the input node reports 0 Hz forever, and
    ///   ``InputStreamFormat/isUsable`` then refuses to build the graph.
    ///
    /// It lives here rather than at the call sites so activation and deactivation cannot disagree
    /// about which platforms they apply to.
    public static var isSelfActivating: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }
    
    /// For the simulator and any path where CallKit is not driving activation.
    public static func activate() throws {
        try AVAudioSession.sharedInstance().setActive(true, options: [])
    }
    
    public static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    
    /// Speaker vs. whatever the system would pick (earpiece, headset, Bluetooth).
    public static func setLoudspeaker(_ enabled: Bool) throws {
        try AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }
    
    public static var isLoudspeaker: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }
    
    public static var isBuiltInReceiver: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver }
    }
    
    public static var currentOutputName: String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName
    }
    
    /// What the user can pick, and which of it is in use. See ``CallAudioRoute`` for the rules.
    public static func audioOutputs(hasReceiver: Bool) -> (outputs: [CallAudioOutput], current: CallAudioOutput?) {
        let session = AVAudioSession.sharedInstance()
        let inputs = (session.availableInputs ?? []).map(CallAudioPort.init)
        let route = session.currentRoute.outputs.map(CallAudioPort.init)
        let outputs = CallAudioRoute.outputs(availableInputs: inputs, routeOutputs: route, hasReceiver: hasReceiver)
        return (outputs, CallAudioRoute.current(routeOutputs: route, in: outputs))
    }
    
    /// Sends the call to `output`. Everything but the speaker clears the override and prefers that
    /// device's microphone, which is what moves the audio there; a device with no microphone of its
    /// own (wired headphones, possibly CarPlay) clears the preference so the system routes to it.
    public static func selectAudioOutput(_ output: CallAudioOutput) throws {
        let session = AVAudioSession.sharedInstance()
        if output.kind == .speaker {
            try session.overrideOutputAudioPort(.speaker)
            return
        }
        try session.overrideOutputAudioPort(.none)
        let inputs = session.availableInputs ?? []
        let input = switch output.kind {
        case .receiver:
            inputs.first { $0.portType == .builtInMic }
        default:
            inputs.first { CallAudioPort($0).externalOutput.map { CallAudioRoute.isSameDevice($0, output) } ?? false }
        }
        try session.setPreferredInput(input)
    }
    
    /// The route and the inputs as the session reports them, for the log line on each route change:
    /// what CarPlay calls its ports is only learnt in a car.
    public static var routeDescription: String {
        let session = AVAudioSession.sharedInstance()
        let describe: (AVAudioSessionPortDescription) -> String = { "\($0.portType.rawValue)(\($0.portName))" }
        let outputs = session.currentRoute.outputs.map(describe).joined(separator: ", ")
        let inputs = (session.availableInputs ?? []).map(describe).joined(separator: ", ")
        return "outputs: [\(outputs)], available inputs: [\(inputs)]"
    }
}
