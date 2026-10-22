//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AVFoundation
@testable import ElementCallKit
import Testing

/// What the audio button offers for each route. The session cannot be given a headset in a test, so
/// these drive the rules with ports shaped as the session reports them.
struct CallAudioRouteTests {
    private let mic = CallAudioPort(type: .builtInMic, uid: "Built-In Microphone", name: "iPhone Microphone")
    private let receiver = CallAudioPort(type: .builtInReceiver, uid: "Built-In Receiver", name: "Receiver")
    private let speaker = CallAudioPort(type: .builtInSpeaker, uid: "Built-In Speaker", name: "Speaker")
    private let airPods = CallAudioPort(type: .bluetoothHFP, uid: "AA:BB:CC:DD:EE:FF-tsco", name: "AirPods Pro")
    private let headsetMic = CallAudioPort(type: .headsetMic, uid: "Wired Microphone", name: "Headset Microphone")
    private let headphones = CallAudioPort(type: .headphones, uid: "Wired Headphones", name: "Headphones")
    private let carPlay = CallAudioPort(type: .carAudio, uid: "CarPlay", name: "My Car")
    private let carKit = CallAudioPort(type: .bluetoothHFP, uid: "11:22:33:44:55:66-tsco", name: "VW BT 1234")
    
    private func kinds(_ outputs: [CallAudioOutput]) -> [CallAudioOutput.Kind] {
        outputs.map(\.kind)
    }
    
    @Test
    func anIPhoneAloneOffersTheEarpieceAndTheSpeaker() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic], routeOutputs: [receiver], hasReceiver: true)
        #expect(kinds(outputs) == [.receiver, .speaker])
        #expect(CallAudioRoute.current(routeOutputs: [receiver], in: outputs) == .receiver)
        #expect(CallAudioRoute.current(routeOutputs: [speaker], in: outputs) == .speaker)
    }
    
    @Test
    func anIPadHasNoEarpieceToOffer() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic], routeOutputs: [speaker], hasReceiver: false)
        #expect(kinds(outputs) == [.speaker])
    }
    
    @Test
    func aBluetoothHeadsetComesFirstUnderItsOwnName() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic, airPods], routeOutputs: [airPods], hasReceiver: true)
        #expect(kinds(outputs) == [.bluetooth, .receiver, .speaker])
        #expect(outputs.first?.name == "AirPods Pro")
        #expect(CallAudioRoute.current(routeOutputs: [airPods], in: outputs) == outputs.first)
    }
    
    @Test
    func twoBluetoothHeadsetsAreTwoRows() {
        let other = CallAudioPort(type: .bluetoothHFP, uid: "00:11:22:33:44:55-tsco", name: "WH-1000XM4")
        let outputs = CallAudioRoute.outputs(availableInputs: [mic, airPods, other], routeOutputs: [airPods], hasReceiver: true)
        #expect(kinds(outputs) == [.bluetooth, .bluetooth, .receiver, .speaker])
    }
    
    /// One device, two ports under two names: the headset's microphone and its earpieces.
    @Test
    func aWiredHeadsetIsOneRowAndTakesTheEarpiecesPlace() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic, headsetMic], routeOutputs: [headphones], hasReceiver: true)
        #expect(kinds(outputs) == [.wired, .speaker])
        #expect(CallAudioRoute.current(routeOutputs: [headphones], in: outputs)?.kind == .wired)
    }
    
    @Test
    func headphonesWithoutAMicrophoneAreFoundInTheRoute() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic], routeOutputs: [headphones], hasReceiver: true)
        #expect(kinds(outputs) == [.wired, .speaker])
    }
    
    @Test
    func carPlayListedAsAnInputIsOffered() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic, carPlay], routeOutputs: [carPlay], hasReceiver: true)
        #expect(kinds(outputs) == [.car, .receiver, .speaker])
        #expect(outputs.first?.name == "My Car")
        #expect(CallAudioRoute.current(routeOutputs: [carPlay], in: outputs)?.kind == .car)
    }
    
    /// Whether CarPlay lists the car's microphone is only learnt in a car; the route covers both.
    @Test
    func carPlayOnlyInTheRouteIsOfferedToo() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic], routeOutputs: [carPlay], hasReceiver: true)
        #expect(kinds(outputs) == [.car, .receiver, .speaker])
    }
    
    @Test
    func aBluetoothCarKitIsABluetoothRowNamedAfterTheCar() {
        let outputs = CallAudioRoute.outputs(availableInputs: [mic, carKit], routeOutputs: [carKit], hasReceiver: true)
        #expect(kinds(outputs) == [.bluetooth, .receiver, .speaker])
        #expect(outputs.first?.name == "VW BT 1234")
    }
    
    /// Nothing a voice-chat session can send a call to, so nothing to offer.
    @Test
    func playOnlyBluetoothAndAirPlayAreLeftOut() {
        let speakerBox = CallAudioPort(type: .bluetoothA2DP, uid: "box", name: "Speaker Box")
        let airPlay = CallAudioPort(type: .airPlay, uid: "tv", name: "Living Room")
        let outputs = CallAudioRoute.outputs(availableInputs: [mic], routeOutputs: [speakerBox, airPlay], hasReceiver: true)
        #expect(kinds(outputs) == [.receiver, .speaker])
    }
}
