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

    /// What to show for a route in the pickers. The three sentinels double as the
    /// values stored in UserDefaults, so they're translated only on the way to the
    /// screen; everything else is a port name from the system, already localised.
    static func displayName(for option: String) -> String {
        switch option {
        case automatic, builtInSpeaker, builtInMic: L(option)
        default: option
        }
    }

    private let session = AVAudioSession.sharedInstance()
    private var observer: NSObjectProtocol?
    /// Whether the app currently owns the session, i.e. `configureSession` ran and
    /// `deactivateSession` hasn't. Guards the two things that must never happen mid
    /// playback: probing for devices (which widens the category) and re-asserting a
    /// route we aren't using.
    private var sessionActive = false

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
        ) { [weak self] _ in
            self?.refreshOptions()
            // A speaker override only lasts "until the current route changes", so a
            // device connecting or disconnecting mid-exercise silently undoes the
            // user's choice unless it's applied again.
            self?.reapplyRoutesIfNeeded()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Rebuild the lists of selectable devices from what's currently connected.
    ///
    /// - Parameter probingDevices: widen the category first so devices the current
    ///   configuration hides become visible. Only for the settings screen — it
    ///   changes the route, so it's ignored while the session is in use.
    func refreshOptions(probingDevices: Bool = false) {
        // What the system reports as available depends on the category options in
        // force: without `.allowBluetoothHFP` no Bluetooth microphone is ever listed,
        // and with the phone speaker pinned (no A2DP) the headset isn't in the route
        // either. So on the settings screen, where nothing is playing, allow every
        // device before looking. `configureSession` narrows it again before playback.
        if probingDevices && !sessionActive {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: categoryOptions(allowingEveryDevice: true))
        }

        let availableInputs = session.availableInputs ?? []

        // Inputs: automatic + built-in mic + every external input port (headset / Bluetooth mics).
        var ins = [Self.automatic, Self.builtInMic]
        for port in availableInputs where port.portType != .builtInMic {
            ins.append(port.portName)
        }

        // Outputs: automatic + built-in speaker + any connected external output (AirPods, etc.).
        var outs = [Self.automatic, Self.builtInSpeaker]
        for port in session.currentRoute.outputs where Self.isExternalOutput(port) {
            outs.append(port.portName)
        }
        // A Bluetooth headset that the current route doesn't use — because the phone
        // speaker is pinned, which takes it out of the route — still appears among the
        // inputs. Take its name from there, otherwise choosing it again is impossible.
        for port in availableInputs
        where port.portType == .bluetoothHFP || port.portType == .bluetoothLE {
            outs.append(port.portName)
        }

        let inputs = Self.deduplicated(ins), outputs = Self.deduplicated(outs)
        DispatchQueue.main.async {
            if self.inputOptions != inputs { self.inputOptions = inputs }
            if self.outputOptions != outputs { self.outputOptions = outputs }
        }
    }

    /// Configure the shared session for simultaneous record + playback, honouring the
    /// user's speaker / microphone preferences. Call before starting the engine or mic tap.
    func configureSession() {
        try? session.setCategory(.playAndRecord, mode: .default, options: categoryOptions())
        try? session.setActive(true)
        sessionActive = true
        applyOutputRoute()
        applyInputRoute()
    }

    /// Release the shared session when playback ends. Pairs with `configureSession`
    /// so the mic/route is freed instead of being left active behind the exercise
    /// list. Call only after both audio engines have been stopped.
    func deactivateSession() {
        sessionActive = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The category options that match the current preferences.
    ///
    /// Which devices iOS may route to is decided *here*, not by `overrideOutputAudioPort`:
    /// while `.allowBluetoothA2DP` is set, a connected headset outranks everything and
    /// the speaker override can't pull audio away from it. So the only reliable way to
    /// honour "iPhone Speaker" is to not offer Bluetooth/AirPlay at all.
    ///
    /// - Parameter allowingEveryDevice: allow every device regardless of the
    ///   preferences, so they can all be enumerated for the pickers.
    private func categoryOptions(allowingEveryDevice: Bool = false)
        -> AVAudioSession.CategoryOptions {
        // `.defaultToSpeaker` makes the built-in speaker the default output and, crucially,
        // drives it at full *media* volume. Routing to the speaker with
        // `overrideOutputAudioPort(.speaker)` instead uses the "speakerphone" path, which
        // under `.playAndRecord` is attenuated to a quiet, voice-call level — the reason
        // the speaker was so much quieter than other apps. A connected accessory (AirPods)
        // still takes priority over this default, so it doesn't pin output to the speaker.
        // `.mixWithOthers` is intentionally omitted so the app takes normal audio focus
        // and plays back at full volume.
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]

        // Wireless output (A2DP = full-quality stereo, and AirPlay) unless the user has
        // pinned the phone speaker, in which case offering them is what breaks the pin.
        if allowingEveryDevice || selectedSpeaker != Self.builtInSpeaker {
            options.insert(.allowBluetoothA2DP)
            options.insert(.allowAirPlay)
        }

        // `.allowBluetoothHFP` enables the Hands-Free Profile: the two-way "phone-call"
        // Bluetooth mode (mono, ~8–16 kHz) and the *only* way a Bluetooth microphone can
        // be used at all. It costs audio quality — HFP outranks A2DP, so with it on,
        // playback to the same headset drops to call quality — so it's enabled only when
        // the user asked for a microphone other than the phone's own. That's also why the
        // built-in mic stays the default: it keeps clean music on the AirPods while the
        // phone's mic listens for pitch.
        if allowingEveryDevice || selectedMic != Self.builtInMic {
            options.insert(.allowBluetoothHFP)
        }

        return options
    }

    private func applyOutputRoute() {
        let externalConnected = session.currentRoute.outputs.contains(where: Self.isExternalOutput)
        if selectedSpeaker == Self.builtInSpeaker && externalConnected {
            // The category already keeps wireless outputs away, so what's left here is a
            // wired accessory (or a Bluetooth headset still in the route because its mic
            // is in use). Those need the explicit override — the "speakerphone" path,
            // used only in this case as it's quieter than the default speaker.
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
        if let preferred = preferredInput() { try? session.setPreferredInput(preferred) }
    }

    /// The input port matching the user's choice, falling back to the built-in mic
    /// when the chosen device isn't connected.
    private func preferredInput() -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        switch selectedMic {
        case Self.builtInMic:
            return inputs.first { $0.portType == .builtInMic }
        case Self.automatic:
            // Prefer an external mic (headset / Bluetooth) when connected, else built-in.
            return inputs.first { $0.portType != .builtInMic }
                ?? inputs.first { $0.portType == .builtInMic }
        default:
            return inputs.first { $0.portName == selectedMic }
                ?? inputs.first { $0.portType == .builtInMic }
        }
    }

    /// Re-assert the chosen route after the system changed it under us — a headset
    /// being plugged in or unpaired drops the speaker override and can steal the
    /// input. Only acts when the live route actually disagrees with the preference,
    /// so it settles instead of bouncing off its own route-change notifications.
    private func reapplyRoutesIfNeeded() {
        guard sessionActive else { return }

        let outputWrong = selectedSpeaker == Self.builtInSpeaker
            && session.currentRoute.outputs.contains(where: Self.isExternalOutput)
        let wanted = preferredInput()
        let inputWrong = wanted.map { port in
            !session.currentRoute.inputs.contains { $0.uid == port.uid }
        } ?? false
        guard outputWrong || inputWrong else { return }

        // A device that appeared after `configureSession` may need different options
        // (a newly connected headset has to be shut out again when the speaker is
        // pinned), so re-derive them rather than only re-applying the routes.
        try? session.setCategory(.playAndRecord, mode: .default, options: categoryOptions())
        applyOutputRoute()
        applyInputRoute()
    }

    /// Anything that isn't the phone's own speaker or earpiece receiver.
    private nonisolated static func isExternalOutput(_ port: AVAudioSessionPortDescription) -> Bool {
        port.portType != .builtInSpeaker && port.portType != .builtInReceiver
    }

    /// Order-preserving dedupe: one device can show up twice (e.g. a headset that is
    /// both the current output and an available input).
    private nonisolated static func deduplicated(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }
}
