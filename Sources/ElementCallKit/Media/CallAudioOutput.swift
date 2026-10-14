//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation

/// Somewhere the call's audio can come out of.
public nonisolated struct CallAudioOutput: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case speaker
        case receiver
        case bluetooth
        case wired
        case usb
        case car
    }
    
    public let kind: Kind
    /// The port's UID for external hardware, a fixed value for the two built-in outputs.
    public let id: String
    /// The port's own name. Shown for external hardware, where "Bluetooth" alone is useless with two
    /// headsets paired; the built-in outputs are named by the host's strings instead.
    public let name: String
    
    public init(kind: Kind, id: String, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }
    
    public var isBuiltIn: Bool {
        kind == .speaker || kind == .receiver
    }
    
    public static let speaker = CallAudioOutput(kind: .speaker, id: "builtInSpeaker", name: "Speaker")
    public static let receiver = CallAudioOutput(kind: .receiver, id: "builtInReceiver", name: "Receiver")
}

/// A port as the session describes it, reduced to what the output list is built from, so the rules
/// can be tested without an `AVAudioSessionPortDescription`, which nothing outside AVFoundation can
/// make.
public nonisolated struct CallAudioPort: Hashable, Sendable {
    public let type: AVAudioSession.Port
    public let uid: String
    public let name: String
    
    public init(type: AVAudioSession.Port, uid: String, name: String) {
        self.type = type
        self.uid = uid
        self.name = name
    }
    
    init(_ description: AVAudioSessionPortDescription) {
        self.init(type: description.portType, uid: description.uid, name: description.portName)
    }
    
    /// Nil for the built-in ports and for anything a voice-chat session cannot route a call to:
    /// AirPlay, HDMI, line connections, and Bluetooth that can only play (A2DP).
    var externalOutput: CallAudioOutput? {
        let kind: CallAudioOutput.Kind? = switch type {
        case .bluetoothHFP, .bluetoothLE: .bluetooth
        case .headsetMic, .headphones: .wired
        case .usbAudio: .usb
        case .carAudio: .car
        default: nil
        }
        return kind.map { CallAudioOutput(kind: $0, id: uid, name: name) }
    }
}

public nonisolated enum CallAudioRoute {
    /// Everything the user can pick, external hardware first, then the receiver, then the speaker.
    ///
    /// Built from the *inputs*, because a voice-chat session has no API for choosing an output: the
    /// only levers are the speaker override and the preferred input, and preferring a headset's
    /// microphone is what sends the call to its earpieces. Ports in the route that are not also
    /// inputs are added as well, which is how headphones without a microphone appear, and CarPlay
    /// should it not list the car's microphone.
    ///
    /// - Parameter hasReceiver: whether the device has an earpiece at all; an iPad does not.
    public static func outputs(availableInputs: [CallAudioPort],
                               routeOutputs: [CallAudioPort],
                               hasReceiver: Bool) -> [CallAudioOutput] {
        var external: [CallAudioOutput] = []
        for port in availableInputs + routeOutputs {
            guard let output = port.externalOutput else { continue }
            if !external.contains(where: { isSameDevice($0, output) }) {
                external.append(output)
            }
        }
        
        var outputs = external
        // Wired headphones take the earpiece's place: with them plugged in the system will not route
        // a call to the receiver, so offering it would be a row that does nothing.
        if hasReceiver, !external.contains(where: { $0.kind == .wired }) {
            outputs.append(.receiver)
        }
        outputs.append(.speaker)
        return outputs
    }
    
    /// Which of `outputs` the call is coming out of now.
    public static func current(routeOutputs: [CallAudioPort], in outputs: [CallAudioOutput]) -> CallAudioOutput? {
        for port in routeOutputs {
            switch port.type {
            case .builtInSpeaker:
                return .speaker
            case .builtInReceiver:
                return .receiver
            default:
                if let routed = port.externalOutput, let match = outputs.first(where: { isSameDevice($0, routed) }) {
                    return match
                }
            }
        }
        return nil
    }
    
    /// One device can show as two ports: a wired headset is a `headsetMic` input and a `headphones`
    /// output, under different names. There is only ever one wired, USB or car connection, so
    /// those match on kind; Bluetooth can have two headsets at once and matches on UID or name.
    static func isSameDevice(_ lhs: CallAudioOutput, _ rhs: CallAudioOutput) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        if lhs.kind != .bluetooth {
            return true
        }
        return lhs.id == rhs.id || lhs.name == rhs.name
    }
}
