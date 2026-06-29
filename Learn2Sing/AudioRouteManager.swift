//
//  AudioRouteManager.swift
//  Learn2Sing
//
//  Centralises audio-route selection so playback output (speaker) and microphone
//  input both honour the choices the user makes in Settings. Without this the app
//  forced `.defaultToSpeaker`, so playback stayed on the phone speaker even with
//  AirPods connected.
//

import AVFoundation
import Combine

final class AudioRouteManager: ObservableObject {
    static let shared = AudioRouteManager()

    static let speakerKey = "selectedSpeaker"
    static let micKey = "selectedMicrophone"

    /// Output sentinel: follow the system — use connected earphones/Bluetooth, else the speaker.
    static let automatic = "Automatic"
    /// Output sentinel: always the phone's built-in speaker.
    static let builtInSpeaker = "iPhone Speaker"
    /// Input sentinel: always the phone's built-in microphone.
    static let builtInMic = "iPhone Microphone"

    private let session = AVAudioSession.sharedInstance()
    private var observer: NSObjectProtocol?

    /// Selectable output / input device names, refreshed as devices connect & disconnect.
    @Published private(set) var outputOptions: [String] = []
    @Published private(set) var inputOptions: [String] = []

    var selectedSpeaker: String {
        UserDefaults.standard.string(forKey: Self.speakerKey) ?? Self.automatic
    }
    var selectedMic: String {
        UserDefaults.standard.string(forKey: Self.micKey) ?? Self.builtInMic
    }

    private init() {
        refreshOptions()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshOptions() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Rebuild the lists of selectable devices from what's currently connected.
    func refreshOptions() {
        // Inputs: automatic + built-in mic + every external input port (headset / Bluetooth mics).
        var ins = [Self.automatic, Self.builtInMic]
        for port in session.availableInputs ?? [] where port.portType != .builtInMic {
            ins.append(port.portName)
        }

        // Outputs: automatic + built-in speaker + any connected external output (AirPods, etc.).
        var outs = [Self.automatic, Self.builtInSpeaker]
        for port in session.currentRoute.outputs
        where port.portType != .builtInSpeaker && port.portType != .builtInReceiver {
            outs.append(port.portName)
        }

        let inputs = ins, outputs = outs
        DispatchQueue.main.async {
            if self.inputOptions != inputs { self.inputOptions = inputs }
            if self.outputOptions != outputs { self.outputOptions = outputs }
        }
    }

    /// Configure the shared session for simultaneous record + playback, honouring the
    /// user's speaker / microphone preferences. Call before starting the engine or mic tap.
    func configureSession() {
        // Allow only *output* Bluetooth (A2DP) and AirPlay, so earphones get full-quality
        // stereo sound. Crucially we do NOT pass `.allowBluetooth`: that enables the
        // Hands-Free Profile (HFP/SCO) — the low-quality, two-way "phone-call" Bluetooth
        // mode (mono, ~8–16 kHz). Under `.playAndRecord`, allowing HFP makes iOS route
        // AirPods through it (so playback sounds like a phone call), forces the whole
        // system into that voice route (degrading other apps' audio), and keeps the
        // session in a voice-processing state that also quietens the built-in speaker.
        //
        // With only A2DP allowed, the Bluetooth mic isn't offered, so input falls back to
        // the built-in microphone — exactly what we want: clean music to the AirPods while
        // the phone's mic listens for pitch. `.mixWithOthers` is intentionally omitted so
        // the app takes normal audio focus and plays back at full volume.
        //
        // `.defaultToSpeaker` makes the built-in speaker the default output and, crucially,
        // drives it at full *media* volume. Routing to the speaker with
        // `overrideOutputAudioPort(.speaker)` instead uses the "speakerphone" path, which
        // under `.playAndRecord` is attenuated to a quiet, voice-call level — the reason
        // the speaker was so much quieter than other apps. A connected accessory (AirPods)
        // still takes priority over this default, so it doesn't pin output to the speaker.
        let options: AVAudioSession.CategoryOptions =
            [.allowBluetoothA2DP, .allowAirPlay, .defaultToSpeaker]
        try? session.setCategory(.playAndRecord, mode: .default, options: options)
        try? session.setActive(true)
        applyOutputRoute()
        applyInputRoute()
    }

    /// Release the shared session when playback ends. Pairs with `configureSession`
    /// so the mic/route is freed instead of being left active behind the exercise
    /// list. Call only after both audio engines have been stopped.
    func deactivateSession() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func applyOutputRoute() {
        let externalConnected = session.currentRoute.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
        if selectedSpeaker == Self.builtInSpeaker && externalConnected {
            // The user forces the phone speaker while an accessory is connected, so the
            // route has to be overridden explicitly (the "speakerphone" path). This is
            // the only case that path is used, as it's quieter than the default speaker.
            try? session.overrideOutputAudioPort(.speaker)
        } else {
            // Clear any override and let `.defaultToSpeaker` decide: a connected accessory
            // (AirPods etc.) takes priority, otherwise it routes to the built-in speaker at
            // full media volume — never the quiet earpiece receiver. Covers Automatic, a
            // specific chosen output, and the plain built-in-speaker (no accessory) case.
            try? session.overrideOutputAudioPort(.none)
        }
    }

    private func applyInputRoute() {
        let inputs = session.availableInputs ?? []
        let preferred: AVAudioSessionPortDescription?
        switch selectedMic {
        case Self.builtInMic:
            preferred = inputs.first { $0.portType == .builtInMic }
        case Self.automatic:
            // Prefer an external mic (headset / Bluetooth) when connected, else built-in.
            preferred = inputs.first { $0.portType != .builtInMic }
                ?? inputs.first { $0.portType == .builtInMic }
        default:
            preferred = inputs.first { $0.portName == selectedMic }
                ?? inputs.first { $0.portType == .builtInMic }
        }
        if let preferred { try? session.setPreferredInput(preferred) }
    }
}
