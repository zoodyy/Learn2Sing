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

/// The one queue every call that can hold its caller up on the audio system goes
/// through: setting the session's category, activating, routing and deactivating
/// it, and building, starting, pausing and stopping the synthesiser's engine.
///
/// Each of those is a round trip to the system's audio server, and some of them
/// wait on the hardware besides: activating the record-and-play session took about
/// 200 ms on the simulator, every time an exercise started. On the main thread that
/// was 200 ms without a frame drawn, right as the playback screen was sliding in,
/// and the engine's own start added more just as the notes were about to move.
/// Here they wait without holding anything up.
///
/// One serial queue, so they still happen in the order they are asked for: a
/// session is configured before the engine that plays through it starts, and an
/// engine stops before the session it played through is deactivated, without
/// either side having to wait for the other. Nothing on the main thread ever waits
/// for this queue, so a slow call here can't stall a frame, and the main thread
/// can't end up waiting on a queue that is itself waiting for the main thread.
nonisolated enum AudioControl {
    static let queue = DispatchQueue(label: "Learn2Sing audio control", qos: .userInitiated)

    /// Runs `work` on the main queue once everything already handed to `queue` has
    /// run: for whatever needs the session as the calls before it left it.
    static func afterPendingWork(_ work: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            DispatchQueue.main.async { work() }
        }
    }
}

final class AudioRouteManager: ObservableObject {
    static let shared = AudioRouteManager()

    static let speakerKey = "selectedSpeaker"
    static let micKey = "selectedMicrophone"

    /// Output sentinel: follow the system — use connected earphones/Bluetooth, else the speaker.
    nonisolated static let automatic = "Automatic"
    /// Output sentinel: always the phone's built-in speaker.
    nonisolated static let builtInSpeaker = "iPhone Speaker"
    /// Input sentinel: always the phone's built-in microphone.
    nonisolated static let builtInMic = "iPhone Microphone"

    /// What to show for a route in the pickers. The three sentinels double as the
    /// values stored in UserDefaults, so they're translated only on the way to the
    /// screen; everything else is a port name from the system, already localised.
    static func displayName(for option: String) -> String {
        switch option {
        case automatic, builtInSpeaker, builtInMic: L(option)
        default: option
        }
    }

    private var observer: NSObjectProtocol?
    /// Whether the app currently owns the session, i.e. `configureSession` was asked
    /// for and `deactivateSession` hasn't been since. Guards the two things that must
    /// never happen mid playback: probing for devices (which widens the category) and
    /// re-asserting a route we aren't using.
    ///
    /// Main-thread state, set the moment the call is made rather than when
    /// `AudioControl.queue` gets round to it: the queue carries the calls out in the
    /// order they were made, so what was last asked for is what the session ends up
    /// as, and that is what these two have to answer for.
    private var sessionActive = false
    /// Whether the active session is the playback-only one, which must never be
    /// widened back to `.playAndRecord` behind the user's back.
    private var playbackOnly = false

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
    /// Looked up on `AudioControl.queue`, since asking the session what is connected
    /// is a round trip to the audio server, and this runs on every route change,
    /// several of which come with every exercise starting. The lists were always
    /// published a moment later rather than on the spot.
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
        let probing = probingDevices && !sessionActive
        let speaker = selectedSpeaker, mic = selectedMic
        AudioControl.queue.async { [weak self] in
            let (inputs, outputs) = Self.connectedOptions(probing: probing, speaker: speaker, mic: mic)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.inputOptions != inputs { self.inputOptions = inputs }
                if self.outputOptions != outputs { self.outputOptions = outputs }
            }
        }
    }

    /// The pickers' lists as the session has them right now. `AudioControl.queue` only.
    private nonisolated static func connectedOptions(probing: Bool, speaker: String, mic: String)
        -> (inputs: [String], outputs: [String]) {
        let session = AVAudioSession.sharedInstance()
        if probing {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: categoryOptions(speaker: speaker, mic: mic,
                                                              allowingEveryDevice: true))
        }

        let availableInputs = session.availableInputs ?? []

        // Inputs: automatic + built-in mic + every external input port (headset / Bluetooth mics).
        var ins = [automatic, builtInMic]
        for port in availableInputs where port.portType != .builtInMic {
            ins.append(port.portName)
        }

        // Outputs: automatic + built-in speaker + any connected external output (AirPods, etc.).
        var outs = [automatic, builtInSpeaker]
        for port in session.currentRoute.outputs where isExternalOutput(port) {
            outs.append(port.portName)
        }
        // A Bluetooth headset that the current route doesn't use — because the phone
        // speaker is pinned, which takes it out of the route — still appears among the
        // inputs. Take its name from there, otherwise choosing it again is impossible.
        for port in availableInputs
        where port.portType == .bluetoothHFP || port.portType == .bluetoothLE {
            outs.append(port.portName)
        }

        return (deduplicated(ins), deduplicated(outs))
    }

    /// Configure the shared session for simultaneous record + playback, honouring the
    /// user's speaker / microphone preferences. Call before starting the engine or mic tap.
    ///
    /// Returns straight away: the session is configured on `AudioControl.queue`,
    /// which is where the synthesiser's engine starts too, so an engine started
    /// after this call still starts on the configured session. Anything else that
    /// needs it finished goes through `AudioControl.afterPendingWork` (the pitch
    /// detector does), or waits for `completion`, which runs on the main queue once
    /// it is.
    func configureSession(then completion: (@MainActor @Sendable () -> Void)? = nil) {
        playbackOnly = false
        sessionActive = true
        let speaker = selectedSpeaker, mic = selectedMic
        AudioControl.queue.async {
            Self.applyRecordingSession(speaker: speaker, mic: mic)
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    /// What `configureSession` does to the session. `AudioControl.queue` only.
    private nonisolated static func applyRecordingSession(speaker: String, mic: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: categoryOptions(speaker: speaker, mic: mic))
        try? session.setActive(true)
        applyOutputRoute(session, speaker: speaker)
        applyInputRoute(session, mic: mic)
    }

    /// The longest `configureSession(whenSettled:)` waits for the route before calling
    /// back anyway. The walk to AirPods takes about a quarter of a second.
    private static let settleTimeout: TimeInterval = 1.0

    /// `configureSession`, and then `ready` once iOS has actually moved the output to
    /// where that configuration sends it. Whatever starts a run's engines goes through
    /// here rather than starting them straight after `configureSession`.
    ///
    /// Activating the session comes back before the route has got there: with AirPods
    /// connected, iOS walks the output from the receiver to the speaker to the AirPods
    /// over the next quarter of a second or so. An engine started during that walk
    /// opens its Bluetooth stream while the route is still being switched under it.
    /// Usually that does no harm, and it is the likeliest reason why, now and then, the
    /// earphones come out of their start holding far more audio than iOS reports: every
    /// note is then heard late for the whole run, and nothing the app can read shows it
    /// (2026-10-26: after such a run the AirPods reported a 336 ms delay, against 156 ms
    /// after the run before it, while iOS gave 177 ms for both). Starting once the
    /// route has arrived keeps every start clear of the switch.
    ///
    /// `ready` runs on the main queue, once, and never before the configuration
    /// (which happens on `AudioControl.queue`) has finished: straight after it when
    /// the route is already where it is going, and at the latest after
    /// `settleTimeout`, so a device that drops out half way can't hold a run up.
    /// Cancelling the wait drops it instead.
    func configureSession(whenSettled ready: @escaping () -> Void) -> RouteWait {
        let wait = RouteWait(ready: ready)
        // Listening before configuring, so a step of the walk that lands while the
        // configuration is still under way can't be missed.
        wait.listen(timeout: Self.settleTimeout)
        playbackOnly = false
        sessionActive = true
        let speaker = selectedSpeaker, mic = selectedMic
        AudioControl.queue.async {
            // Read before configuring: where the output ends up depends on what the
            // route reaches before the new category is in place.
            let destination = Self.expectedOutput(speaker: speaker)
            Self.applyRecordingSession(speaker: speaker, mic: mic)
            DispatchQueue.main.async { wait.configured(heading: destination) }
        }
        return wait
    }

    /// A `configureSession(whenSettled:)` that hasn't called back yet.
    final class RouteWait {
        private var ready: (() -> Void)?
        private var observer: NSObjectProtocol?
        private var timeout: DispatchWorkItem?
        /// Where the output is going, known once the session has been configured.
        /// Until then the route isn't judged at all: a change seen half way through
        /// the configuration can't call the run's audio up on a session that hasn't
        /// finished being set up.
        private var destination: Destination?
        /// Set when `settleTimeout` has passed: the wait is over as soon as the
        /// configuration is.
        private var timedOut = false

        fileprivate init(ready: @escaping () -> Void) {
            self.ready = ready
        }

        /// Look at the route on every change, and stop waiting for it after `seconds`.
        /// Both hold on to the wait, so it lasts until it has called back or been
        /// cancelled whether or not the caller keeps it.
        fileprivate func listen(timeout seconds: TimeInterval) {
            observer = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
            ) { _ in self.check() }
            let giveUp = DispatchWorkItem {
                self.timedOut = true
                self.check()
            }
            timeout = giveUp
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: giveUp)
        }

        /// The session is configured, and the output is on its way to `destination`.
        fileprivate func configured(heading destination: Destination) {
            self.destination = destination
            check()
        }

        private func check() {
            guard let destination else { return }
            if timedOut || AudioRouteManager.output(reaches: destination) {
                finish(callingBack: true)
            }
        }

        /// Drop the wait without calling back.
        func cancel() {
            finish(callingBack: false)
        }

        private func finish(callingBack: Bool) {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            timeout?.cancel()
            timeout = nil
            let ready = self.ready
            self.ready = nil
            if callingBack { ready?() }
        }
    }

    /// Where a route can end up, as far as waiting for it goes.
    fileprivate nonisolated enum Destination: Sendable {
        case speaker
        case external
    }

    /// Where `configureSession` will leave the output, read before it runs: the
    /// phone's speaker when the user pinned it, otherwise an external device if the
    /// route reaches one already (iOS hands the output back to it once the new
    /// category is in place), and the speaker when there is none.
    private nonisolated static func expectedOutput(speaker: String) -> Destination {
        if speaker == builtInSpeaker { return .speaker }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains(where: isExternalOutput) ? .external : .speaker
    }

    fileprivate nonisolated static func output(reaches destination: Destination) -> Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        switch destination {
        case .speaker: return outputs.contains { $0.portType == .builtInSpeaker }
        case .external: return outputs.contains(where: isExternalOutput)
        }
    }

    /// Configure the shared session for sound that never records — the instrument
    /// samples in Settings. Activating the recording category would ask a user who
    /// hasn't granted microphone access for it, which has nothing to do with
    /// listening to an instrument, so this one only plays. Pairs with
    /// `deactivateSession` like `configureSession` does, and like it, returns
    /// straight away.
    func configurePlaybackSession() {
        playbackOnly = true
        sessionActive = true
        AudioControl.queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
    }

    /// Release the shared session when playback ends. Pairs with `configureSession`
    /// so the mic/route is freed instead of being left active behind the exercise
    /// list. Call only once both audio engines have been told to stop: the
    /// synthesiser's stops on `AudioControl.queue` ahead of this, and the pitch
    /// detector's before its `stop()` returns.
    func deactivateSession() {
        sessionActive = false
        playbackOnly = false
        AudioControl.queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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
    private nonisolated static func categoryOptions(speaker: String, mic: String,
                                                    allowingEveryDevice: Bool = false)
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
        if allowingEveryDevice || speaker != builtInSpeaker {
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
        if allowingEveryDevice || mic != builtInMic {
            options.insert(.allowBluetoothHFP)
        }

        return options
    }

    private nonisolated static func applyOutputRoute(_ session: AVAudioSession, speaker: String) {
        let externalConnected = session.currentRoute.outputs.contains(where: isExternalOutput)
        if speaker == builtInSpeaker && externalConnected {
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

    private nonisolated static func applyInputRoute(_ session: AVAudioSession, mic: String) {
        if let preferred = preferredInput(session, mic: mic) { try? session.setPreferredInput(preferred) }
    }

    /// The input port matching the user's choice, falling back to the built-in mic
    /// when the chosen device isn't connected.
    private nonisolated static func preferredInput(_ session: AVAudioSession,
                                                   mic: String) -> AVAudioSessionPortDescription? {
        let inputs = session.availableInputs ?? []
        switch mic {
        case builtInMic:
            return inputs.first { $0.portType == .builtInMic }
        case automatic:
            // Prefer an external mic (headset / Bluetooth) when connected, else built-in.
            return inputs.first { $0.portType != .builtInMic }
                ?? inputs.first { $0.portType == .builtInMic }
        default:
            return inputs.first { $0.portName == mic }
                ?? inputs.first { $0.portType == .builtInMic }
        }
    }

    /// Re-assert the chosen route after the system changed it under us — a headset
    /// being plugged in or unpaired drops the speaker override and can steal the
    /// input. Only acts when the live route actually disagrees with the preference,
    /// so it settles instead of bouncing off its own route-change notifications.
    /// The route is read, and put right, on `AudioControl.queue`.
    private func reapplyRoutesIfNeeded() {
        guard sessionActive, !playbackOnly else { return }
        let speaker = selectedSpeaker, mic = selectedMic
        AudioControl.queue.async {
            Self.reapplyRoutes(speaker: speaker, mic: mic)
        }
    }

    private nonisolated static func reapplyRoutes(speaker: String, mic: String) {
        let session = AVAudioSession.sharedInstance()
        let outputWrong = speaker == builtInSpeaker
            && session.currentRoute.outputs.contains(where: isExternalOutput)
        let wanted = preferredInput(session, mic: mic)
        let inputWrong = wanted.map { port in
            !session.currentRoute.inputs.contains { $0.uid == port.uid }
        } ?? false
        guard outputWrong || inputWrong else { return }

        // A device that appeared after `configureSession` may need different options
        // (a newly connected headset has to be shut out again when the speaker is
        // pinned), so re-derive them rather than only re-applying the routes.
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: categoryOptions(speaker: speaker, mic: mic))
        applyOutputRoute(session, speaker: speaker)
        applyInputRoute(session, mic: mic)
    }

    /// The microphone and the speaker the session is routed through right now, as one
    /// key: what the automatic microphone delay keeps its history under (see
    /// `AutoMicDelay.record`), since the lag it measures belongs to that pair.
    static func devicePairKey() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        func port(_ port: AVAudioSessionPortDescription?) -> String {
            port.map { "\($0.portType.rawValue):\($0.uid)" } ?? "none"
        }
        return port(route.inputs.first) + "|" + port(route.outputs.first)
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
