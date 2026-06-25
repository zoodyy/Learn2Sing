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
        // Allow routing to Bluetooth / AirPlay so earphones can be used; mixWithOthers keeps
        // the mic-based pitch detector and the synth playing together.
        let options: AVAudioSession.CategoryOptions =
            [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay, .mixWithOthers]
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
        switch selectedSpeaker {
        case Self.builtInSpeaker:
            try? session.overrideOutputAudioPort(.speaker)
        case Self.automatic:
            // Use connected earphones / Bluetooth when present; otherwise the speaker
            // (so it never falls back to the quiet earpiece receiver).
            try? session.overrideOutputAudioPort(externalConnected ? .none : .speaker)
        default:
            // A specific external output was chosen: route to it when connected, else speaker.
            let connected = session.currentRoute.outputs.contains { $0.portName == selectedSpeaker }
            try? session.overrideOutputAudioPort(connected ? .none : .speaker)
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
