//
//  AudioDebugLog.swift
//  Learn2Sing
//
//  ┌────────────────────────────────────────────────────────────────────────────┐
//  │ TEMPORARY AUDIO DEBUG LOG: REMOVE ONCE THE AUDIO BUGS ARE FOUND            │
//  │                                                                            │
//  │ Here to catch two bugs on the developer's own iPhone:                      │
//  │   1. a whole run heard late against the notes (seen with AirPods), and     │
//  │   2. a run that plays one broken sound at its start and then nothing.      │
//  │                                                                            │
//  │ Everything goes to Library/Application Support/AudioDebugLog in the app's  │
//  │ container:                                                                 │
//  │   audio.log     every audio event as one line, and a heartbeat once a      │
//  │                 second while a run is on screen                            │
//  │   flags.log     the runs flagged with the ladybug button                   │
//  │   runs/<n>_…/   one folder per run: run.json (exercise, settings, notes,   │
//  │                 result, summary), render.csv (every buffer the synth       │
//  │                 rendered), mic.csv (every microphone buffer), frames.csv   │
//  │                 (every frame drawn), schedule.csv (the notes as the synth  │
//  │                 plays them)                                                │
//  │ Tools/AudioDebugLog/pull_audio_logs.sh copies it to the Mac, and           │
//  │ Tools/AudioDebugLog/summarize_audio_logs.py lists the runs in it.          │
//  │                                                                            │
//  │ To remove all of it:                                                       │
//  │   python3 Tools/AudioDebugLog/remove_audio_debug_log.py                    │
//  │ That deletes the three AudioDebug*.swift files and undoes every hook       │
//  │ tagged `AUDIO DEBUG LOG` in the other sources: a tagged line is deleted,   │
//  │ a BEGIN…END block is deleted, and a line tagged `restore:` gets back the   │
//  │ code written after that word. Its strings are all `Text(verbatim:)` or     │
//  │ plain, so there is nothing in the string catalog to undo, and it writes no │
//  │ UserDefaults keys (which the profile backup would upload).                 │
//  └────────────────────────────────────────────────────────────────────────────┘
//

import AVFoundation
import Darwin
import Foundation
import Synchronization
import UIKit
import os

// MARK: - The calls the hooks make

nonisolated enum AudioDebugLog {
    /// The installs a Release build logs on: the developer's iPhone, by its public
    /// user id. Compared by hex digits, as `DebugRecordingAccess` does. A Debug
    /// build, which is what running from Xcode makes, logs on every device.
    private static let allowed: Set<String> = [
        "e5a93d58-38d8-5f6a-821e-2bff0ea9d398",   // Artjom's iPhone
    ]

    /// Set once by `launch()`, on the main thread before any audio has run, and only
    /// read after that.
    nonisolated(unsafe) private(set) static var isEnabled = false

    /// Called first thing at launch: decides whether this install logs and, if it
    /// does, opens the log and starts listening to the audio session.
    @MainActor
    static func launch() {
        #if DEBUG
        isEnabled = true
        #else
        let list = Set(allowed.map(hexKey))
        isEnabled = [PublicIdentifier.user, DeviceIdentifier.uuidString].contains { list.contains(hexKey($0)) }
        #endif
        guard isEnabled else { return }
        AudioDebugCore.shared.start(header: launchHeader())
        AudioDebugObservers.install()
    }

    private static func hexKey(_ id: String) -> String {
        id.lowercased().filter(\.isHexDigit)
    }

    // MARK: Events

    /// When something happened: the wall clock for reading the log, and the host
    /// clock the audio timestamps are in, for lining the two up.
    nonisolated struct Stamp: Sendable {
        let date: Date
        let mach: UInt64

        static func now() -> Stamp {
            Stamp(date: Date(), mach: mach_absolute_time())
        }
    }

    /// One line in the log. Safe from any thread but the audio render thread, which
    /// goes through `AudioDebugRenderProbe` instead.
    static func event(_ name: String, _ fields: KeyValuePairs<String, Any?> = [:], extra: String? = nil) {
        guard isEnabled else { return }
        var text = format(fields)
        if let extra, !extra.isEmpty { text += text.isEmpty ? extra : " " + extra }
        if !Thread.isMainThread { text += " ~bg" }
        AudioDebugCore.shared.log(.now(), name, text)
    }

    /// Runs `body` as the `try?` it replaces would, and logs how long it took and the
    /// error it threw, if any.
    @discardableResult
    static func attempt(_ name: String, _ fields: KeyValuePairs<String, Any?> = [:],
                        _ body: () throws -> Void) -> Bool {
        guard isEnabled else { return (try? body()) != nil }
        let start = mach_absolute_time()
        do {
            try body()
            event(name, ["ok": true, "ms": milliseconds(since: start)], extra: format(fields))
            return true
        } catch {
            event(name, ["ok": false, "ms": milliseconds(since: start), "error": error],
                  extra: format(fields))
            return false
        }
    }

    // MARK: Engines

    /// Gives `engine` a name the log calls it by from then on: "player#3", "mic#1".
    @discardableResult
    static func nameEngine(_ engine: AVAudioEngine, _ role: String) -> String {
        AudioDebugEngineNames.shared.name(engine, role: role)
    }

    static func engineName(_ engine: AVAudioEngine) -> String {
        AudioDebugEngineNames.shared.nameOf(engine)
    }

    /// How many `ExercisePlayer`s have been made since launch. SwiftUI makes one
    /// every time it rebuilds a screen holding one, and keeps only the first.
    private static let playersMade = Atomic<Int>(0)

    static func playerCreated() {
        guard isEnabled else { return }
        _ = playersMade.add(1, ordering: .relaxed)
    }

    static var playersCreated: Int { playersMade.load(ordering: .relaxed) }

    /// The probe a player's render block feeds, made when the player wires up its
    /// synthesiser. nil when nothing is logged.
    static func renderProbe(for engine: AVAudioEngine, sampleRate: Double) -> AudioDebugRenderProbe? {
        guard isEnabled else { return nil }
        let probe = AudioDebugRenderProbe(name: nameEngine(engine, "player"), sampleRate: sampleRate)
        AudioDebugCore.shared.register(probe)
        return probe
    }

    /// The player has wired its synthesiser into the engine, which is what creates
    /// the engine's audio I/O unit.
    static func graphBuilt(_ engine: AVAudioEngine, format: AVAudioFormat) {
        guard isEnabled else { return }
        let output = engine.outputNode.outputFormat(forBus: 0)
        let mixer = engine.mainMixerNode.outputFormat(forBus: 0)
        event("player.graphBuilt", ["p": engineName(engine), "src": formatString(format),
                                    "mixer": formatString(mixer), "hw": formatString(output),
                                    "pres": engine.outputNode.presentationLatency,
                                    "playersMade": playersCreated])
    }

    /// The synth's view of the output latency, which the drawing is offset by.
    static func latencyRefreshed(_ engine: AVAudioEngine, old: TimeInterval, new: TimeInterval) {
        guard isEnabled else { return }
        event("player.outputLatency", ["p": engineName(engine), "old": old, "new": new,
                                       "changed": old != new])
    }

    /// The note events the player has just been handed, as it will play them.
    static func scheduled(_ engine: AVAudioEngine, events: [(sample: Int, pitch: Int, on: Bool)],
                          finishSample: Int, sampleRate: Double, bpm: Double, leadIn: Double) {
        guard isEnabled else { return }
        event("player.schedule", ["p": engineName(engine), "events": events.count,
                                  "finishSample": finishSample,
                                  "finishSec": Double(finishSample) / sampleRate,
                                  "bpm": bpm, "leadIn": leadIn])
        AudioDebugCore.shared.schedule(events, sampleRate: sampleRate)
    }

    /// A microphone capture is about to start on `format`, through the sink node or
    /// the tap. Called before its engine starts, so the marker it leaves in the
    /// microphone's trace comes ahead of the capture's first buffer.
    static func micCaptureStarting(_ format: AVAudioFormat, via route: String,
                                   _ fields: KeyValuePairs<String, Any?> = [:]) {
        guard isEnabled else { return }
        AudioDebugMicProbe.shared.captureStarted(sampleRate: format.sampleRate)
        event("mic.capture", ["fmt": formatString(format), "via": route], extra: Self.format(fields))
    }

    /// One microphone buffer, from the detector's analysis thread.
    static func micChunk(_ time: AudioTimeStamp, samples: UnsafePointer<Float>, count: Int, pitch: Double?) {
        guard isEnabled else { return }
        AudioDebugMicProbe.shared.add(time, samples: samples, count: count, pitch: pitch)
    }

    // MARK: Runs

    /// The run screen has come up and is about to start its audio. Everything logged
    /// until `runClosed` belongs to this run, and its traces go into a folder of
    /// their own.
    @MainActor
    static func runOpened(exercise: String, exerciseID: UUID, mode: String, bpm: Double,
                          leadIn: Double, repeats: Int, notes: [MIDINote], ghosts: [MIDINote],
                          player: ExercisePlayer, detector: PitchDetector,
                          settings: KeyValuePairs<String, Any?>) {
        guard isEnabled else { return }
        AudioDebugRunMonitor.current?.stop()
        let monitor = AudioDebugRunMonitor(player: player, detector: detector, bpm: bpm, leadIn: leadIn)
        AudioDebugRunMonitor.current = monitor
        let encoder = JSONEncoder()
        let info = AudioDebugRunInfo(
            stamp: .now(), exercise: exercise, exerciseID: exerciseID.uuidString, mode: mode,
            bpm: bpm, leadIn: leadIn, repeats: repeats,
            settings: format(settings) + " " + format(["playersMade": playersCreated]),
            session: sessionSnapshot(),
            notes: (try? encoder.encode(notes)) ?? Data("[]".utf8),
            ghosts: (try? encoder.encode(ghosts)) ?? Data("[]".utf8))
        AudioDebugCore.shared.openRun(info)
        monitor.start()
    }

    /// What a finished run came to, for the run's summary as well as the log.
    static func runResult(_ name: String, _ fields: KeyValuePairs<String, Any?>) {
        guard isEnabled else { return }
        let text = format(fields)
        event(name, fields)
        AudioDebugCore.shared.result(name, text)
    }

    /// The run screen has gone: to the score, to a delay result, or because the
    /// singer left it.
    @MainActor
    static func runClosed(finalScore: Int?, delayResult: Double?, calibrating: Bool) {
        guard isEnabled, let monitor = AudioDebugRunMonitor.current else { return }
        let reason = finalScore != nil ? "finished"
            : delayResult != nil ? "delayTestDone"
            : calibrating ? "calibrating"
            : "left"
        let frames = monitor.stop()
        AudioDebugRunMonitor.current = nil
        AudioDebugCore.shared.closeRun(reason: reason, score: finalScore, frames: frames, stamp: .now())
    }

    /// One frame of the run being drawn: the beat it shows and the singer's pitch.
    @MainActor
    static func frame(beat: Double, target: Double?, shown: Double?) {
        guard isEnabled else { return }
        AudioDebugRunMonitor.current?.addFrame(beat: beat, target: target, shown: shown)
    }

    /// The ladybug button: marks what went wrong, with everything about the audio
    /// right now, against the run on screen or the one that just ended.
    @MainActor
    static func flag(_ flag: AudioDebugFlag) {
        guard isEnabled else { return }
        let monitor = AudioDebugRunMonitor.current
        let text = format(["kind": flag.rawValue, "when": monitor != nil ? "duringRun" : "afterRun"])
            + " " + (monitor.map { $0.snapshot() + " " } ?? "") + sessionSnapshot()
        AudioDebugCore.shared.flag(flag.rawValue, text: text, stamp: .now())
        monitor?.heartbeat()
    }

    // MARK: Describing the audio session

    /// Everything about the session that could bear on either bug, as one line.
    static func sessionSnapshot() -> String {
        let session = AVAudioSession.sharedInstance()
        return format([
            ("cat", session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")),
            ("mode", session.mode.rawValue.replacingOccurrences(of: "AVAudioSessionMode", with: "")),
            ("opts", optionsString(session.categoryOptions)),
            ("sr", session.sampleRate),
            ("io", session.ioBufferDuration),
            ("outLat", session.outputLatency),
            ("inLat", session.inputLatency),
            ("vol", session.outputVolume),
            ("muted", session.isOutputMuted),
            ("outCh", session.outputNumberOfChannels),
            ("inCh", session.inputNumberOfChannels),
            ("otherAudio", session.isOtherAudioPlaying),
            ("silenceHint", session.secondaryAudioShouldBeSilencedHint),
            ("route", routeString(session.currentRoute)),
        ])
    }

    /// The part of the session that changes during a run, for the heartbeat.
    static func sessionHeartbeat() -> String {
        let session = AVAudioSession.sharedInstance()
        return format([
            ("s.outLat", session.outputLatency),
            ("s.io", session.ioBufferDuration),
            ("s.sr", session.sampleRate),
            ("s.vol", session.outputVolume),
            ("s.out", session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+")),
        ])
    }

    static func routeString(_ route: AVAudioSessionRouteDescription) -> String {
        let outputs = route.outputs.map(portString).joined(separator: " + ")
        let inputs = route.inputs.map(portString).joined(separator: " + ")
        return "out: \(outputs.isEmpty ? "none" : outputs) | in: \(inputs.isEmpty ? "none" : inputs)"
    }

    static func portString(_ port: AVAudioSessionPortDescription) -> String {
        var text = "\(port.portType.rawValue) '\(port.portName)'"
        if let channels = port.channels?.count { text += " ch\(channels)" }
        if port.isSpatialAudioEnabled { text += " spatial" }
        if port.hasHardwareVoiceCallProcessing { text += " hwVoice" }
        text += " uid=\(port.uid)"
        return text
    }

    static func optionsString(_ options: AVAudioSession.CategoryOptions) -> String {
        let names: [(UInt, String)] = [
            (0x1, "mix"), (0x2, "duck"), (0x4, "btHFP"), (0x8, "defaultToSpeaker"),
            (0x10, "interruptSpoken"), (0x20, "btA2DP"), (0x40, "airPlay"), (0x80, "overrideMutedMic"),
        ]
        let raw = options.rawValue
        let known = names.filter { raw & $0.0 != 0 }.map(\.1)
        return String(format: "0x%lx", raw) + (known.isEmpty ? "" : "(" + known.joined(separator: ",") + ")")
    }

    static func formatString(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))x\(format.channelCount)\(format.isInterleaved ? "i" : "")"
    }

    // MARK: Formatting

    static func format(_ fields: KeyValuePairs<String, Any?>) -> String {
        format(fields.map { ($0.key, $0.value) })
    }

    static func format(_ fields: [(String, Any?)]) -> String {
        fields.map { "\($0.0)=\(value($0.1))" }.joined(separator: " ")
    }

    static func value(_ any: Any?) -> String {
        guard let any else { return "nil" }
        switch any {
        case let value as Bool: return value ? "1" : "0"
        case let value as Double: return number(value)
        case let value as Float: return number(Double(value))
        case let value as CGFloat: return number(Double(value))
        case let value as Int: return String(value)
        case let value as any BinaryInteger: return "\(value)"
        case let value as String: return quoted(value)
        case let value as Error: return quoted(describe(value))
        default: return quoted(String(describing: any))
        }
    }

    static func number(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : value > 0 ? "inf" : "-inf" }
        if value == value.rounded(), abs(value) < 1e12 { return String(Int64(value)) }
        if abs(value) < 0.01 { return String(format: "%.3g", value) }
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func quoted(_ text: String) -> String {
        guard text.isEmpty || text.contains(where: { $0 == " " || $0 == "\"" || $0 == "=" || $0.isNewline })
        else { return text }
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"" + escaped + "\""
    }

    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain):\(error.code)\(fourCC(error.code)) \(error.localizedDescription)"
    }

    /// Core Audio's errors are four characters packed into a number ('!pri', 'what').
    private static func fourCC(_ code: Int) -> String {
        let value = UInt32(truncatingIfNeeded: code)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return "" }
        return "('" + String(decoding: bytes, as: UTF8.self) + "')"
    }

    // MARK: Time

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * secondsPerTick
    }

    /// Signed, for host times that may fall either side of a reference.
    static func seconds(_ ticks: Int64) -> Double {
        Double(ticks) * secondsPerTick
    }

    static func milliseconds(since start: UInt64) -> Double {
        let now = mach_absolute_time()
        return now > start ? seconds(now - start) * 1000 : 0
    }

    // MARK: Launch

    @MainActor
    private static func launchHeader() -> [(String, String)] {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let configuration = "Debug(-Onone)"
        #else
        let configuration = "Release"
        #endif
        let executableDate = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let process = ProcessInfo.processInfo
        let delays = UserDefaults.standard.dictionary(forKey: AutoMicDelay.historyKey) as? [String: [Double]] ?? [:]
        return [
            ("launch.app", format([
                "version": info["CFBundleShortVersionString"] as? String,
                "build": info["CFBundleVersion"] as? String,
                "config": configuration,
                "debugger": isDebuggerAttached,
                "provisioned": Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil,
                "exeBuilt": executableDate.map { ISO8601DateFormatter().string(from: $0) },
            ])),
            ("launch.device", format([
                "model": machine(),
                "ios": UIDevice.current.systemVersion,
                "lowPower": process.isLowPowerModeEnabled,
                "thermal": thermalName(process.thermalState),
            ])),
            ("launch.ids", format([
                "user": PublicIdentifier.user,
                "device": DeviceIdentifier.uuidString,
            ])),
            ("launch.settings", settingsSnapshot()),
            ("launch.delayHistory", delays.map { "\($0.key)=\($0.value.map { number($0) }.joined(separator: ","))" }
                .sorted().joined(separator: " ; ")),
            ("launch.session", sessionSnapshot()),
        ]
    }

    /// The settings a run's sound and scoring depend on.
    @MainActor
    static func settingsSnapshot() -> String {
        let defaults = UserDefaults.standard
        return format([
            "instrument": Instrument.current.rawValue,
            "micDelayMs": defaults.double(forKey: microphoneDelayKey),
            "autoDelay": AutoMicDelay.isEnabled,
            "autoEstablished": AutoMicDelay.isEstablished,
            "detection": PitchDetection.current.rawValue,
            "speaker": AudioRouteManager.shared.selectedSpeaker,
            "mic": AudioRouteManager.shared.selectedMic,
        ])
    }

    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }

    private static func machine() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Engine names

/// Which engine is which in the log. Held weakly, so a name dies with its engine.
nonisolated final class AudioDebugEngineNames: @unchecked Sendable {
    static let shared = AudioDebugEngineNames()

    private let lock = NSLock()
    private let names = NSMapTable<AVAudioEngine, NSString>.weakToStrongObjects()
    private var counts: [String: Int] = [:]

    func name(_ engine: AVAudioEngine, role: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = names.object(forKey: engine) { return existing as String }
        counts[role, default: 0] += 1
        let name = "\(role)#\(counts[role] ?? 0)"
        names.setObject(name as NSString, forKey: engine)
        return name
    }

    func nameOf(_ engine: AVAudioEngine) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = names.object(forKey: engine) { return existing as String }
        return "engine@" + String(UInt(bitPattern: ObjectIdentifier(engine).hashValue), radix: 16)
    }
}

// MARK: - What the system says about the audio

/// Observers for everything the system announces that could bear on the audio,
/// installed once at launch. They are delivered on whichever thread posts them,
/// so their time in the log is when the system said it, not when the main thread
/// got round to it.
nonisolated enum AudioDebugObservers {
    nonisolated(unsafe) private static var tokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private static var volume: NSKeyValueObservation?

    static func install() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        func observe(_ name: Notification.Name, object: Any? = nil,
                     _ body: @escaping @Sendable (Notification) -> Void) {
            tokens.append(center.addObserver(forName: name, object: object, queue: nil, using: body))
        }

        observe(AVAudioSession.routeChangeNotification) { note in
            let info = note.userInfo ?? [:]
            let reason = (info[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 99
            let previous = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let session = AVAudioSession.sharedInstance()
            AudioDebugLog.event("session.routeChange", [
                "reason": routeChangeReason(reason),
                "previous": previous.map(AudioDebugLog.routeString),
                "current": AudioDebugLog.routeString(session.currentRoute),
                "outLat": session.outputLatency,
                "sr": session.sampleRate,
                "io": session.ioBufferDuration,
                "opts": AudioDebugLog.optionsString(session.categoryOptions),
            ])
        }
        observe(AVAudioSession.interruptionNotification) { note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 99
            let reason = info[AVAudioSessionInterruptionReasonKey] as? UInt
            let options = info[AVAudioSessionInterruptionOptionKey] as? UInt
            AudioDebugLog.event("session.interruption", [
                "type": type == 1 ? "began" : type == 0 ? "ended" : "\(type)",
                "reason": reason.map(interruptionReason),
                "shouldResume": options.map { $0 & 1 != 0 },
            ], extra: AudioDebugLog.sessionSnapshot())
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { _ in
            AudioDebugLog.event("session.mediaServicesLost")
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { _ in
            AudioDebugLog.event("session.mediaServicesReset")
        }
        observe(AVAudioSession.silenceSecondaryAudioHintNotification) { note in
            let type = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt
            AudioDebugLog.event("session.silenceSecondaryHint", ["type": type == 1 ? "begin" : "end"])
        }
        observe(AVAudioSession.spatialPlaybackCapabilitiesChangedNotification) { note in
            AudioDebugLog.event("session.spatialCapabilities", [
                "enabled": note.userInfo?[AVAudioSessionSpatialAudioEnabledKey] as? Bool,
            ])
        }
        observe(AVAudioSession.renderingCapabilitiesChangeNotification) { _ in
            AudioDebugLog.event("session.renderingCapabilities")
        }
        observe(AVAudioSession.outputMuteStateChangeNotification) { _ in
            AudioDebugLog.event("session.outputMute", ["muted": AVAudioSession.sharedInstance().isOutputMuted])
        }
        observe(AVAudioSession.userIntentToUnmuteOutputNotification) { _ in
            AudioDebugLog.event("session.userIntentToUnmute")
        }
        // Every engine in the app, named where the hooks named it.
        observe(.AVAudioEngineConfigurationChange) { note in
            guard let engine = note.object as? AVAudioEngine else { return }
            AudioDebugLog.event("engine.configChange", [
                "engine": AudioDebugLog.engineName(engine),
                "running": engine.isRunning,
            ])
        }

        observe(UIApplication.didBecomeActiveNotification) { _ in AudioDebugLog.event("app.active") }
        observe(UIApplication.willResignActiveNotification) { _ in AudioDebugLog.event("app.resignActive") }
        observe(UIApplication.didEnterBackgroundNotification) { _ in AudioDebugLog.event("app.background") }
        observe(UIApplication.willEnterForegroundNotification) { _ in AudioDebugLog.event("app.foreground") }
        observe(UIApplication.didReceiveMemoryWarningNotification) { _ in AudioDebugLog.event("app.memoryWarning") }
        observe(UIApplication.willTerminateNotification) { _ in AudioDebugLog.event("app.terminate") }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { _ in
            AudioDebugLog.event("app.deviceLocked")
        }
        observe(ProcessInfo.thermalStateDidChangeNotification) { _ in
            AudioDebugLog.event("app.thermal", ["state": AudioDebugLog.thermalName(ProcessInfo.processInfo.thermalState)])
        }
        observe(.NSProcessInfoPowerStateDidChange) { _ in
            AudioDebugLog.event("app.lowPower", ["on": ProcessInfo.processInfo.isLowPowerModeEnabled])
        }

        volume = session.observe(\.outputVolume, options: [.new]) { _, change in
            AudioDebugLog.event("session.volume", ["vol": change.newValue])
        }
    }

    private static func routeChangeReason(_ raw: UInt) -> String {
        switch raw {
        case 0: "unknown"
        case 1: "newDeviceAvailable"
        case 2: "oldDeviceUnavailable"
        case 3: "categoryChange"
        case 4: "override"
        case 6: "wakeFromSleep"
        case 7: "noSuitableRouteForCategory"
        case 8: "routeConfigurationChange"
        default: "\(raw)"
        }
    }

    private static func interruptionReason(_ raw: UInt) -> String {
        switch raw {
        case 0: "default"
        case 1: "appWasSuspended"
        case 2: "builtInMicMuted"
        case 3: "sceneWasBackgrounded"
        case 4: "routeDisconnected"
        case 5: "deviceUnauthenticated"
        default: "\(raw)"
        }
    }
}

// MARK: - Writing it down

/// What a run is opened with.
nonisolated struct AudioDebugRunInfo: Sendable {
    let stamp: AudioDebugLog.Stamp
    let exercise: String
    let exerciseID: String
    let mode: String
    let bpm: Double
    let leadIn: Double
    let repeats: Int
    let settings: String
    let session: String
    let notes: Data
    let ghosts: Data
}

/// The log's files, and everything that writes to them. All of it runs on `queue`,
/// so the audio, the analysis and the main thread only ever hand lines over.
nonisolated final class AudioDebugCore: @unchecked Sendable {
    static let shared = AudioDebugCore()

    let queue = DispatchQueue(label: "CDE.Learn2Singg.AudioDebugLog", qos: .utility)
    private let system = Logger(subsystem: "CDE.Learn2Singg", category: "AudioDebugLog")

    private static let maxLogBytes: UInt64 = 16 << 20
    private static let maxRotatedLogs = 12
    private static let maxRunBytes: Int64 = 400 << 20

    // Everything below belongs to `queue`.
    private var root: URL?
    private var handle: FileHandle?
    private var written: UInt64 = 0
    private var launchNumber = 0
    private var runCount = 0
    private var run: AudioDebugRunTrace?
    private var lastRunFolder: URL?
    private var lastRunNumber: Int?
    private var probes: [WeakProbe] = []
    private var idleTimer: DispatchSourceTimer?
    private let wall: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private struct WeakProbe {
        weak var probe: AudioDebugRenderProbe?
    }

    func start(header: [(String, String)]) {
        let stamp = AudioDebugLog.Stamp.now()
        queue.async {
            self.openFiles()
            self.write(self.line(stamp, "==== launch", "L\(self.launchNumber) ===="))
            for (name, text) in header { self.write(self.line(stamp, name, text)) }
            self.trimRuns()
            self.startIdleTimer()
        }
    }

    func log(_ stamp: AudioDebugLog.Stamp, _ name: String, _ text: String) {
        queue.async {
            let line = self.line(stamp, name, text)
            self.write(line)
            self.system.notice("\(line, privacy: .public)")
            self.run?.count(name)
        }
    }

    func register(_ probe: AudioDebugRenderProbe) {
        queue.async { self.probes.append(WeakProbe(probe: probe)) }
    }

    // MARK: Runs

    func openRun(_ info: AudioDebugRunInfo) {
        queue.async {
            if self.run != nil { self.finishRun(reason: "superseded", score: nil, stamp: info.stamp) }
            // Whatever the probes still hold is from before this run.
            self.drainProbes(into: nil)
            _ = AudioDebugMicProbe.shared.drain()
            guard let root = self.root else { return }
            self.runCount += 1
            self.saveState()
            let trace = AudioDebugRunTrace(number: self.runCount, launch: self.launchNumber,
                                           info: info, runsFolder: root.appendingPathComponent("runs"))
            self.run = trace
            self.write(self.line(info.stamp, "run.open", AudioDebugLog.format([
                "exercise": info.exercise, "mode": info.mode, "bpm": info.bpm,
                "repeats": info.repeats, "folder": trace.folder.lastPathComponent,
            ]) + " " + info.settings))
            self.write(self.line(info.stamp, "run.session", info.session))
            self.trimRuns()
        }
    }

    func result(_ name: String, _ text: String) {
        queue.async { self.run?.results.append("\(name) \(text)") }
    }

    func schedule(_ events: [(sample: Int, pitch: Int, on: Bool)], sampleRate: Double) {
        queue.async { self.run?.writeSchedule(events, sampleRate: sampleRate) }
    }

    /// A flag goes into the log naming the run it is about (the one on screen, or
    /// else the one that just ended), into flags.log, and into that run's folder.
    func flag(_ kind: String, text: String, stamp: AudioDebugLog.Stamp) {
        queue.async {
            guard let root = self.root else { return }
            let number = self.run?.number ?? self.lastRunNumber
            let entry = self.line(stamp, "FLAG", "target=" + (number.map { "R\($0)" } ?? "none") + " " + text)
            self.write(entry)
            self.system.notice("\(entry, privacy: .public)")
            self.run?.count("FLAG")
            let target = self.run.map { "R\($0.number) (on screen)" }
                ?? self.lastRunNumber.map { "R\($0) (just ended)" } ?? "no run"
            let line = "\(self.wall.string(from: stamp.date)) \(kind) \(target)\n"
            Self.append(line, to: root.appendingPathComponent("flags.log"))
            if let run = self.run {
                run.flags.append(kind)
            } else if let folder = self.lastRunFolder {
                Self.append(line, to: folder.appendingPathComponent("flags.txt"))
            }
        }
    }

    /// The heartbeat: drains what the audio threads and the drawing have collected
    /// since the last one into the run's traces, and writes one line about it.
    func tick(main: String, frames: [AudioDebugFrameRow], stamp: AudioDebugLog.Stamp) {
        queue.async {
            guard let run = self.run else { return }
            self.drainProbes(into: run)
            self.drainMicrophone(into: run)
            run.addFrames(frames, core: self)
            let window = run.takeWindow()
            self.write(self.line(stamp, "hb", [main, window, AudioDebugLog.sessionHeartbeat()]
                .joined(separator: " ")))
        }
    }

    func closeRun(reason: String, score: Int?, frames: [AudioDebugFrameRow], stamp: AudioDebugLog.Stamp) {
        queue.async {
            guard let run = self.run else { return }
            self.drainProbes(into: run)
            self.drainMicrophone(into: run)
            run.addFrames(frames, core: self)
            self.finishRun(reason: reason, score: score, stamp: stamp)
        }
    }

    private func finishRun(reason: String, score: Int?, stamp: AudioDebugLog.Stamp) {
        guard let run else { return }
        let summary = run.summary(reason: reason, score: score, closedAt: stamp)
        write(line(stamp, "run.close", summary))
        run.finish(reason: reason, summary: summary, closedAt: stamp, wall: wall)
        lastRunFolder = run.folder
        lastRunNumber = run.number
        self.run = nil
    }

    /// Writes a line found while draining, at the time it happened rather than now.
    func anomaly(_ run: AudioDebugRunTrace, at mach: UInt64, _ name: String, _ text: String) {
        let offset = AudioDebugLog.seconds(Int64(bitPattern: mach &- run.origin))
        let stamp = AudioDebugLog.Stamp(date: run.info.stamp.date.addingTimeInterval(offset), mach: mach)
        let line = self.line(stamp, name, text)
        write(line)
        system.notice("\(line, privacy: .public)")
    }

    // MARK: Draining the audio threads

    private func drainProbes(into run: AudioDebugRunTrace?) {
        probes.removeAll { $0.probe == nil }
        for entry in probes {
            guard let probe = entry.probe else { continue }
            if let run {
                let dropped = probe.drain { row in run.addRender(row, probe: probe, core: self) }
                if dropped > 0 { run.droppedRender(dropped, probe: probe, core: self) }
            } else {
                // Not a run's: an instrument sample, or a player still running down.
                var count = 0, peak: Float = 0, nonFinite = 0
                _ = probe.drain { row in
                    count += 1
                    peak = max(peak, row.peak)
                    if !row.sumSquares.isFinite || row.nonFinite > 0 { nonFinite += 1 }
                }
                if count > 0 {
                    write(line(.now(), "render.outsideRun", AudioDebugLog.format([
                        "src": probe.name, "buffers": count, "peak": Double(peak), "nonFinite": nonFinite,
                    ])))
                }
            }
        }
    }

    private func drainMicrophone(into run: AudioDebugRunTrace) {
        for row in AudioDebugMicProbe.shared.drain() { run.addMic(row, core: self) }
    }

    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.run == nil else { return }
            self.drainProbes(into: nil)
            _ = AudioDebugMicProbe.shared.drain()
        }
        timer.resume()
        idleTimer = timer
    }

    // MARK: Sharing

    /// Zips the whole log folder for the share sheet. Calls back on the main thread.
    func packageForSharing(_ done: @escaping @MainActor (URL?) -> Void) {
        queue.async {
            var result: URL?
            if let root = self.root {
                let name = "AudioDebugLog-" + Self.fileStamp(Date()) + ".zip"
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: root, options: [.forUploading], error: &error) { zip in
                    try? FileManager.default.removeItem(at: destination)
                    if (try? FileManager.default.copyItem(at: zip, to: destination)) != nil { result = destination }
                }
            }
            let packaged = result
            DispatchQueue.main.async { done(packaged) }
        }
    }

    // MARK: Files

    private func openFiles() {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        var root = support.appendingPathComponent("AudioDebugLog", isDirectory: true)
        try? manager.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        self.root = root

        if let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Int] {
            launchNumber = state["launch"] ?? 0
            runCount = state["run"] ?? 0
        }
        launchNumber += 1
        saveState()
        openLog()
    }

    private func openLog() {
        guard let root else { return }
        let url = root.appendingPathComponent("audio.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        written = (try? handle?.seekToEnd()) ?? 0
    }

    private func saveState() {
        guard let root,
              let data = try? JSONSerialization.data(withJSONObject: ["launch": launchNumber, "run": runCount])
        else { return }
        try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }

    fileprivate func write(_ line: String) {
        guard let handle else { return }
        let data = Data((line + "\n").utf8)
        try? handle.write(contentsOf: data)
        written += UInt64(data.count)
        if written > Self.maxLogBytes { rotate() }
    }

    /// Starts a fresh audio.log once the current one is big enough, keeping the
    /// newest few of the old ones.
    private func rotate() {
        guard let root else { return }
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.moveItem(at: root.appendingPathComponent("audio.log"),
                              to: root.appendingPathComponent("audio-\(Self.fileStamp(Date())).log"))
        let old = ((try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("audio-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in old.dropLast(Self.maxRotatedLogs) { try? manager.removeItem(at: url) }
        openLog()
    }

    /// Keeps the run folders under `maxRunBytes`, oldest first out.
    private func trimRuns() {
        guard let root else { return }
        let manager = FileManager.default
        let runs = ((try? manager.contentsOfDirectory(at: root.appendingPathComponent("runs"),
                                                      includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var sizes = runs.map { folder -> Int64 in
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        var total = sizes.reduce(0, +)
        var index = 0
        while total > Self.maxRunBytes, index < runs.count - 1 {
            if runs[index] != run?.folder {
                try? manager.removeItem(at: runs[index])
                total -= sizes[index]
                sizes[index] = 0
            }
            index += 1
        }
    }

    fileprivate func line(_ stamp: AudioDebugLog.Stamp, _ name: String, _ text: String) -> String {
        var line = wall.string(from: stamp.date)
        line += String(format: " m=%.6f", AudioDebugLog.seconds(stamp.mach))
        if let run {
            line += String(format: " [R%d %+.3f]", run.number,
                           AudioDebugLog.seconds(Int64(bitPattern: stamp.mach &- run.origin)))
        } else {
            line += " [L\(launchNumber)]"
        }
        line += " " + name
        if !text.isEmpty { line += " " + text }
        return line
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func append(_ text: String, to url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
        try? handle.close()
    }
}

// MARK: - One run's traces

/// A run's folder and what is known about it so far. Belongs to the log's queue.
nonisolated final class AudioDebugRunTrace {
    let number: Int
    let launch: Int
    let info: AudioDebugRunInfo
    let folder: URL
    /// Host time the run was opened at; every time in its traces counts from here.
    let origin: UInt64

    var results: [String] = []
    var flags: [String] = []
    private var eventCounts: [String: Int] = [:]

    private var renderFile: FileHandle?
    private var micFile: FileHandle?
    private var framesFile: FileHandle?

    /// The most of one kind of finding written out per run; past it they are only
    /// counted, in the summary.
    private static let findingsPerKind = 25
    private var findings: [String: Int] = [:]

    // Whole run.
    private var renders = 0
    private var firstRenderAt: UInt64?
    private var renderGaps = 0
    private var maxRenderGapMs = 0.0
    private var slowRenders = 0
    private var overruns = 0
    private var maxRenderMs = 0.0
    private var nonFiniteBuffers = 0
    private var hotBuffers = 0
    private var catchUps = 0
    private var catchUpMs = 0.0
    private var timeJumps = 0
    private var droppedRows = 0
    private var lastAnchor: [String: UInt64] = [:]
    private var lastRender: [String: AudioDebugRenderProbe.Row] = [:]
    private var micChunks = 0
    private var micGaps = 0
    private var maxMicGapMs = 0.0
    private var micJumps = 0
    private var lastMic: AudioDebugMicProbe.Row?
    private var frameCount = 0
    private var frameHitches = 0
    private var maxFrameGapMs = 0.0
    private var lastFrame: UInt64?

    // Since the last heartbeat.
    private var window = Window()

    private struct Window {
        var renders = 0
        var maxGapMs = 0.0
        var maxDurationUs = 0.0
        var totalDurationUs = 0.0
        var peak: Float = 0
        var sumSquares: Double = 0
        var frames = 0
        var nonFinite = 0
        var voices = 0
        var playhead = 0
        var eventIndex = 0
        var eventCount = 0
        var catchUps = 0
        var minLeadMs = Double.infinity
        var maxLeadMs = -Double.infinity
        var micChunks = 0
        var micMaxGapMs = 0.0
        var micPeak: Float = 0
        var micSumSquares: Double = 0
        var micFrames = 0
        var pitched = 0
        var drawn = 0
        var drawMaxGapMs = 0.0
    }

    init(number: Int, launch: Int, info: AudioDebugRunInfo, runsFolder: URL) {
        self.number = number
        self.launch = launch
        self.info = info
        self.origin = info.stamp.mach
        let name = String(info.exercise.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        })
        folder = runsFolder.appendingPathComponent(
            String(format: "%05d_", number) + AudioDebugCore.fileStamp(info.stamp.date) + "_" + name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        renderFile = Self.open(folder.appendingPathComponent("render.csv"),
                               header: "src,host_ms,now_ms,sample_time,frames,flags,dur_us,peak,rms,preclip,nonfinite,voices,strings,pitches,playhead,event,events,catchup,anchor_ms")
        micFile = Self.open(folder.appendingPathComponent("mic.csv"),
                            header: "host_ms,handled_ms,sample_time,frames,flags,rms,peak,pitch")
        framesFile = Self.open(folder.appendingPathComponent("frames.csv"),
                               header: "now_ms,beat,target,shown")
        writeJSON(reason: nil, summary: nil, closedAt: nil, wall: nil)
    }

    func count(_ event: String) {
        eventCounts[event, default: 0] += 1
    }

    /// Milliseconds from the run's opening to a host time, empty for none.
    private func ms(_ mach: UInt64) -> String {
        guard mach != 0 else { return "" }
        return String(format: "%.3f", AudioDebugLog.seconds(Int64(bitPattern: mach &- origin)) * 1000)
    }

    private func note(_ kind: String, core: AudioDebugCore, at mach: UInt64, _ text: String) {
        let seen = findings[kind, default: 0]
        findings[kind] = seen + 1
        guard seen < Self.findingsPerKind else { return }
        core.anomaly(self, at: mach, kind, text + (seen + 1 == Self.findingsPerKind ? " (more only counted)" : ""))
    }

    // MARK: Rendering

    func addRender(_ row: AudioDebugRenderProbe.Row, probe: AudioDebugRenderProbe, core: AudioDebugCore) {
        renders += 1
        let frames = max(1, Int(row.frames))
        let bufferMs = Double(frames) / probe.sampleRate * 1000
        let durationUs = AudioDebugLog.seconds(row.duration) * 1e6
        let rms = sqrt(Double(row.sumSquares) / Double(frames))
        let leadMs = row.host != 0 ? AudioDebugLog.seconds(Int64(bitPattern: row.host &- row.now)) * 1000 : .nan

        var pitches: [String] = []
        for slot in 0..<8 {
            let pitch = (row.pitches >> UInt64(8 * slot)) & 0xFF
            if pitch != 0xFF { pitches.append(String(pitch)) }
        }
        let csv = [
            probe.name, ms(row.host), ms(row.now), String(format: "%.0f", row.sampleTime), String(row.frames),
            String(row.flags), String(format: "%.0f", durationUs), Self.fixed(Double(row.peak), 4),
            Self.fixed(rms, 5), Self.fixed(Double(row.preClip), 4), String(row.nonFinite), String(row.voices),
            String(row.strings), pitches.joined(separator: " "), String(row.playhead), String(row.eventIndex),
            String(row.eventCount), String(row.catchUp), row.anchor != 0 ? ms(row.anchor) : "",
        ].joined(separator: ",")
        Self.write(csv, to: renderFile)

        if firstRenderAt == nil {
            firstRenderAt = row.now
            note("render.first", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "leadMs": leadMs, "sampleTime": row.sampleTime, "frames": frames,
                "bufferMs": bufferMs, "flags": row.flags,
            ]))
        }
        if row.anchor != 0, row.anchor != lastAnchor[probe.name] {
            note("render.anchor", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "anchorMs": ms(row.anchor), "hostMs": ms(row.host),
                "playhead": row.playhead, "leadMs": leadMs,
            ]))
        }
        if row.anchor != 0 { lastAnchor[probe.name] = row.anchor }

        // A buffer anchored afresh is the first after a pause or a new schedule: the
        // stretch before it was meant, so it is reported as that and not as a gap.
        let reanchored = lastRender[probe.name].map { row.anchor != 0 && row.anchor != $0.anchor } ?? false
        if reanchored, let last = lastRender[probe.name] {
            note("render.resumed", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "afterMs": AudioDebugLog.seconds(Int64(bitPattern: row.now &- last.now)) * 1000,
                "playhead": row.playhead,
            ]))
        } else if let last = lastRender[probe.name] {
            let gapMs = AudioDebugLog.seconds(Int64(bitPattern: row.now &- last.now)) * 1000
            let lastBufferMs = Double(max(1, Int(last.frames))) / probe.sampleRate * 1000
            maxRenderGapMs = max(maxRenderGapMs, gapMs)
            window.maxGapMs = max(window.maxGapMs, gapMs)
            if gapMs > max(2.5 * lastBufferMs, lastBufferMs + 15) {
                renderGaps += 1
                note("render.gap", core: core, at: row.now, AudioDebugLog.format([
                    "src": probe.name, "gapMs": gapMs, "bufferMs": lastBufferMs, "playhead": row.playhead,
                ]))
            }
            let validTimes = row.flags & 3 == 3 && last.flags & 3 == 3   // sample and host time valid
            if validTimes {
                let expected = last.sampleTime + Double(last.frames)
                let jump = row.sampleTime - expected
                let hostMs = AudioDebugLog.seconds(Int64(bitPattern: row.host &- last.host)) * 1000
                let sampleMs = (row.sampleTime - last.sampleTime) / probe.sampleRate * 1000
                if abs(jump) > 1 || abs(hostMs - sampleMs) > 5 {
                    timeJumps += 1
                    note("render.timeJump", core: core, at: row.now, AudioDebugLog.format([
                        "src": probe.name, "sampleJump": jump, "hostStepMs": hostMs, "sampleStepMs": sampleMs,
                    ]))
                }
            }
        }
        lastRender[probe.name] = row

        let durationMs = durationUs / 1000
        maxRenderMs = max(maxRenderMs, durationMs)
        if durationMs > bufferMs {
            overruns += 1
            note("render.overrun", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "ms": durationMs, "bufferMs": bufferMs, "voices": row.voices,
                "strings": row.strings,
            ]))
        } else if durationMs > bufferMs / 2 {
            slowRenders += 1
            note("render.slow", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "ms": durationMs, "bufferMs": bufferMs, "voices": row.voices,
            ]))
        }
        if row.nonFinite > 0 || !row.sumSquares.isFinite {
            nonFiniteBuffers += 1
            note("render.nonFinite", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "samples": row.nonFinite, "voices": row.voices, "strings": row.strings,
                "pitches": pitches.joined(separator: " "), "playhead": row.playhead,
            ]))
        }
        if row.preClip > 2 {
            hotBuffers += 1
            note("render.hot", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "preClip": Double(row.preClip), "voices": row.voices,
                "pitches": pitches.joined(separator: " "),
            ]))
        }
        if row.catchUp > 0 {
            catchUps += 1
            let skippedMs = Double(row.catchUp) / probe.sampleRate * 1000
            catchUpMs += skippedMs
            note("render.catchUp", core: core, at: row.now, AudioDebugLog.format([
                "src": probe.name, "skippedMs": skippedMs, "playhead": row.playhead,
                "event": row.eventIndex, "events": row.eventCount,
            ]))
        }

        window.renders += 1
        window.maxDurationUs = max(window.maxDurationUs, durationUs)
        window.totalDurationUs += durationUs
        window.peak = max(window.peak, row.peak)
        if row.sumSquares.isFinite { window.sumSquares += Double(row.sumSquares) }
        window.frames += frames
        if row.nonFinite > 0 || !row.sumSquares.isFinite { window.nonFinite += 1 }
        window.voices = max(window.voices, Int(row.voices))
        window.playhead = row.playhead
        window.eventIndex = Int(row.eventIndex)
        window.eventCount = Int(row.eventCount)
        if row.catchUp > 0 { window.catchUps += 1 }
        if leadMs.isFinite {
            window.minLeadMs = min(window.minLeadMs, leadMs)
            window.maxLeadMs = max(window.maxLeadMs, leadMs)
        }
    }

    func droppedRender(_ count: Int, probe: AudioDebugRenderProbe, core: AudioDebugCore) {
        droppedRows += count
        note("render.rowsDropped", core: core, at: mach_absolute_time(),
             AudioDebugLog.format(["src": probe.name, "rows": count]))
    }

    // MARK: Microphone

    func addMic(_ row: AudioDebugMicProbe.Row, core: AudioDebugCore) {
        // The marker a new capture starts with (see `captureStarted`).
        guard row.frames > 0 else {
            lastMic = nil
            return
        }
        micChunks += 1
        let frames = max(1, row.frames)
        let csv = [
            ms(row.host), ms(row.handled), String(format: "%.0f", row.sampleTime), String(row.frames),
            String(row.flags), Self.fixed(Double(row.rms), 5), Self.fixed(Double(row.peak), 4),
            row.pitch.isFinite ? Self.fixed(Double(row.pitch), 3) : "",
        ].joined(separator: ",")
        Self.write(csv, to: micFile)

        if micChunks == 1 {
            note("mic.first", core: core, at: row.handled, AudioDebugLog.format([
                "latencyMs": row.host != 0 ? AudioDebugLog.seconds(Int64(bitPattern: row.handled &- row.host)) * 1000 : nil,
                "frames": row.frames, "sampleRate": row.sampleRate,
            ]))
        }
        if let last = lastMic, row.host != 0, last.host != 0 {
            let gapMs = AudioDebugLog.seconds(Int64(bitPattern: row.host &- last.host)) * 1000
            let bufferMs = Double(max(1, last.frames)) / max(1, row.sampleRate) * 1000
            maxMicGapMs = max(maxMicGapMs, gapMs)
            window.micMaxGapMs = max(window.micMaxGapMs, gapMs)
            if gapMs > max(2.5 * bufferMs, bufferMs + 15) {
                micGaps += 1
                note("mic.gap", core: core, at: row.handled, AudioDebugLog.format(["gapMs": gapMs, "bufferMs": bufferMs]))
            }
            let jump = row.sampleTime - (last.sampleTime + Double(last.frames))
            if row.flags & 1 != 0, last.flags & 1 != 0, abs(jump) > 1 {
                micJumps += 1
                note("mic.timeJump", core: core, at: row.handled, AudioDebugLog.format(["sampleJump": jump]))
            }
        }
        lastMic = row

        window.micChunks += 1
        window.micPeak = max(window.micPeak, row.peak)
        window.micSumSquares += Double(row.rms * row.rms) * Double(frames)
        window.micFrames += frames
        if row.pitch.isFinite { window.pitched += 1 }
    }

    // MARK: Drawing

    func addFrames(_ rows: [AudioDebugFrameRow], core: AudioDebugCore) {
        guard !rows.isEmpty else { return }
        var text = ""
        text.reserveCapacity(rows.count * 32)
        for row in rows {
            frameCount += 1
            window.drawn += 1
            if let lastFrame {
                let gapMs = AudioDebugLog.seconds(Int64(bitPattern: row.now &- lastFrame)) * 1000
                maxFrameGapMs = max(maxFrameGapMs, gapMs)
                window.drawMaxGapMs = max(window.drawMaxGapMs, gapMs)
                // Past a second it is the run paused or in the background, where the
                // drawing stops on purpose; a main thread stuck that long is reported
                // by the watchdog as `main.stuck`.
                if gapMs > 100, gapMs < 1000 {
                    frameHitches += 1
                    note("draw.hitch", core: core, at: row.now, AudioDebugLog.format(["gapMs": gapMs, "beat": row.beat]))
                }
            }
            lastFrame = row.now
            text += ms(row.now) + "," + Self.fixed(row.beat, 4) + ","
                + (row.target.isFinite ? Self.fixed(row.target, 3) : "") + ","
                + (row.shown.isFinite ? Self.fixed(row.shown, 3) : "") + "\n"
        }
        try? framesFile?.write(contentsOf: Data(text.utf8))
    }

    // MARK: Heartbeat and summary

    func takeWindow() -> String {
        let w = window
        window = Window()
        let renderRMS = w.frames > 0 ? sqrt(w.sumSquares / Double(w.frames)) : 0
        let micRMS = w.micFrames > 0 ? sqrt(w.micSumSquares / Double(w.micFrames)) : 0
        return AudioDebugLog.format([
            ("r.n", w.renders),
            ("r.gapMax", w.maxGapMs),
            ("r.durMaxUs", w.maxDurationUs),
            ("r.durAvgUs", w.renders > 0 ? w.totalDurationUs / Double(w.renders) : 0),
            ("r.pk", Double(w.peak)),
            ("r.rms", renderRMS),
            ("r.nf", w.nonFinite),
            ("r.v", w.voices),
            ("r.ph", w.playhead),
            ("r.ev", "\(w.eventIndex)/\(w.eventCount)"),
            ("r.cu", w.catchUps),
            ("r.lead", w.minLeadMs.isFinite ? "\(AudioDebugLog.number(w.minLeadMs))..\(AudioDebugLog.number(w.maxLeadMs))" : "-"),
            ("m.n", w.micChunks),
            ("m.gapMax", w.micMaxGapMs),
            ("m.rms", micRMS),
            ("m.pk", Double(w.micPeak)),
            ("m.pitched", w.micChunks > 0 ? Double(w.pitched) / Double(w.micChunks) : 0),
            ("f.n", w.drawn),
            ("f.gapMax", w.drawMaxGapMs),
        ])
    }

    func summary(reason: String, score: Int?, closedAt: AudioDebugLog.Stamp) -> String {
        let events = eventCounts.filter { $0.key != "hb" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        return AudioDebugLog.format([
            ("reason", reason),
            ("score", score),
            ("exercise", info.exercise),
            ("seconds", AudioDebugLog.seconds(Int64(bitPattern: closedAt.mach &- origin))),
            ("firstRenderMs", firstRenderAt.map(ms)),
            ("renders", renders),
            ("renderGaps", renderGaps),
            ("maxRenderGapMs", maxRenderGapMs),
            ("slowRenders", slowRenders),
            ("overruns", overruns),
            ("maxRenderMs", maxRenderMs),
            ("nonFiniteBuffers", nonFiniteBuffers),
            ("hotBuffers", hotBuffers),
            ("catchUps", catchUps),
            ("catchUpMs", catchUpMs),
            ("timeJumps", timeJumps),
            ("droppedRows", droppedRows),
            ("micChunks", micChunks),
            ("micGaps", micGaps),
            ("maxMicGapMs", maxMicGapMs),
            ("micJumps", micJumps),
            ("frames", frameCount),
            ("drawHitches", frameHitches),
            ("maxFrameGapMs", maxFrameGapMs),
            ("flags", flags.isEmpty ? nil : flags.joined(separator: ",")),
            ("events", events),
        ])
    }

    func writeSchedule(_ events: [(sample: Int, pitch: Int, on: Bool)], sampleRate: Double) {
        var text = "sample,ms,pitch,on\n"
        for event in events {
            text += "\(event.sample),\(Self.fixed(Double(event.sample) / sampleRate * 1000, 3)),\(event.pitch),\(event.on ? 1 : 0)\n"
        }
        // A run that is scheduled again (the try-out going round) keeps every pass.
        let url = folder.appendingPathComponent("schedule.csv")
        if FileManager.default.fileExists(atPath: url.path) {
            AudioDebugCore.append("\n" + text, to: url)
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    func finish(reason: String, summary: String, closedAt: AudioDebugLog.Stamp, wall: DateFormatter) {
        writeJSON(reason: reason, summary: summary, closedAt: closedAt, wall: wall)
        for file in [renderFile, micFile, framesFile] { try? file?.close() }
        renderFile = nil
        micFile = nil
        framesFile = nil
    }

    private func writeJSON(reason: String?, summary: String?, closedAt: AudioDebugLog.Stamp?, wall: DateFormatter?) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var object: [String: Any] = [
            "run": number,
            "launch": launch,
            "opened": iso.string(from: info.stamp.date),
            "originMachSeconds": AudioDebugLog.seconds(origin),
            "exercise": info.exercise,
            "exerciseID": info.exerciseID,
            "mode": info.mode,
            "bpm": info.bpm,
            "leadInBeats": info.leadIn,
            "repeats": info.repeats,
            "settings": info.settings,
            "sessionAtOpen": info.session,
            "notes": (try? JSONSerialization.jsonObject(with: info.notes)) ?? [],
            "ghosts": (try? JSONSerialization.jsonObject(with: info.ghosts)) ?? [],
            "results": results,
            "flags": flags,
        ]
        if let reason { object["closeReason"] = reason }
        if let summary { object["summary"] = summary }
        if let closedAt { object["closed"] = iso.string(from: closedAt.date) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: folder.appendingPathComponent("run.json"), options: .atomic)
    }

    // MARK: Helpers

    private static func open(_ url: URL, header: String) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: Data((header + "\n").utf8))
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    private static func write(_ line: String, to file: FileHandle?) {
        try? file?.write(contentsOf: Data((line + "\n").utf8))
    }

    static func fixed(_ value: Double, _ digits: Int) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : value > 0 ? "inf" : "-inf" }
        return String(format: "%.\(digits)f", value)
    }
}

// MARK: - The main thread's part of a run

/// While a run is on screen: the heartbeat, the frames drawn, and a watch on the
/// main thread.
@MainActor
final class AudioDebugRunMonitor {
    static var current: AudioDebugRunMonitor?

    private weak var player: ExercisePlayer?
    private weak var detector: PitchDetector?
    private let bpm: Double
    private let leadIn: Double
    private var frames: [AudioDebugFrameRow] = []
    private var timer: Timer?
    private let watchdog = AudioDebugWatchdog()

    init(player: ExercisePlayer, detector: PitchDetector, bpm: Double, leadIn: Double) {
        self.player = player
        self.detector = detector
        self.bpm = bpm
        self.leadIn = leadIn
        frames.reserveCapacity(256)
    }

    var currentBeat: Double? {
        player?.currentBeat(bpm: bpm, leadIn: leadIn)
    }

    func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.heartbeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        watchdog.start()
    }

    /// Stops the heartbeat and hands back the frames not yet written.
    @discardableResult
    func stop() -> [AudioDebugFrameRow] {
        timer?.invalidate()
        timer = nil
        watchdog.stop()
        let rest = frames
        frames = []
        return rest
    }

    func addFrame(beat: Double, target: Double?, shown: Double?) {
        frames.append(AudioDebugFrameRow(now: mach_absolute_time(), beat: beat,
                                         target: target ?? .nan, shown: shown ?? .nan))
    }

    func heartbeat() {
        let rows = frames
        frames.removeAll(keepingCapacity: true)
        AudioDebugCore.shared.tick(main: snapshot(), frames: rows, stamp: .now())
    }

    /// The player's, the microphone's and the app's state, read on the main thread.
    func snapshot() -> String {
        [
            AudioDebugLog.format(["beat": currentBeat]),
            player?.audioDebugState ?? "p=gone",
            detector?.audioDebugState ?? "m=gone",
            AudioDebugLog.format(["app": UIApplication.shared.applicationState.rawValue]),
        ].joined(separator: " ")
    }
}

/// Notices the main thread not getting to its queue: a hang at the start of a run
/// can hold up the engine, the microphone and the drawing alike.
nonisolated final class AudioDebugWatchdog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CDE.Learn2Singg.AudioDebugLog.watchdog", qos: .userInitiated)
    // Belong to `queue`.
    private var timer: DispatchSourceTimer?
    private var pendingSince: UInt64 = 0
    private var reportedStuck = false

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func check() {
        let now = mach_absolute_time()
        if pendingSince != 0 {
            let waited = AudioDebugLog.seconds(now - pendingSince)
            if waited > 1, !reportedStuck {
                reportedStuck = true
                AudioDebugLog.event("main.stuck", ["ms": waited * 1000])
            }
            return
        }
        pendingSince = now
        DispatchQueue.main.async { [weak self] in
            let lag = AudioDebugLog.seconds(mach_absolute_time() - now)
            self?.queue.async {
                guard let self else { return }
                self.pendingSince = 0
                self.reportedStuck = false
                if lag > 0.1 { AudioDebugLog.event("main.hang", ["ms": lag * 1000]) }
            }
        }
    }
}
