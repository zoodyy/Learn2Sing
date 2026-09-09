//
//  DebugRecording.swift
//  Learn2Sing
//
//  ┌────────────────────────────────────────────────────────────────────────────┐
//  │ DEBUG-ONLY FEATURE — REMOVE BEFORE SHIPPING                                │
//  │                                                                            │
//  │ Captures the microphone through a run and exports it together with the     │
//  │ target notes, the pitch estimates that were drawn, and the settings the    │
//  │ run was made under — so a pitch-detection bug can be reproduced offline    │
//  │ from a real recording of a real voice instead of synthesised sound.        │
//  │                                                                            │
//  │ To remove the whole feature:                                               │
//  │   1. Delete this file.                                                     │
//  │   2. Delete every block tagged `DEBUG RECORDING` in the other two files    │
//  │      it touches — PitchDetector.swift and PlaybackView.swift:              │
//  │        grep -rn "DEBUG RECORDING" Learn2Sing --include="*.swift"           │
//  │      Each tag sits on the block it belongs to; nothing else has to change. │
//  │                                                                            │
//  │ Nothing else has to be undone: no localized strings (every label here      │
//  │ goes through `Text(verbatim:)`, which Tools/Localization/extract.py        │
//  │ deliberately ignores), no UserDefaults keys, no assets, no project         │
//  │ settings — the target picks Swift files up from the folder automatically.  │
//  └────────────────────────────────────────────────────────────────────────────┘
//

import AVFoundation
import Combine
import SwiftUI
import os

// MARK: - Microphone tap hook

/// What `PitchDetector` hands its microphone buffers to while a debug run
/// recording is in progress. Kept to two calls so the hook in the detector is
/// three lines that are obvious to delete.
protocol DebugAudioSink: AnyObject {
    /// The input tap has just (re)started on `format`. Main thread.
    func begin(format: AVAudioFormat)
    /// One microphone hop, straight off the audio thread — must not block.
    func append(buffer: AVAudioPCMBuffer, time: AVAudioTime)
}

// MARK: - Lock-free-ish ring buffer

/// A single-producer/single-consumer float ring. The microphone thread copies
/// hops in; a background queue drains them to disk. Storage is a raw allocation
/// rather than an `Array` because both sides touch it at once, which Swift's
/// exclusivity rules don't allow for an array's buffer.
private final class FloatRing {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    /// Monotonic totals, so the arithmetic never has to reason about wrap-around;
    /// only the indexing does.
    private var writeCount = 0
    private var readCount = 0
    private var lock = os_unfair_lock_s()
    private var droppedFrames = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var dropped: Int {
        os_unfair_lock_lock(&lock)
        let value = droppedFrames
        os_unfair_lock_unlock(&lock)
        return value
    }

    /// Producer side (audio thread). Drops the hop rather than blocking if the
    /// consumer has fallen behind — a gap in the recording is far better than a
    /// stall in the tap the recording is meant to be evidence about.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        let write = writeCount
        let free = capacity - (writeCount - readCount)
        if count > free { droppedFrames += count }
        os_unfair_lock_unlock(&lock)
        guard count <= free else { return }

        let start = write % capacity
        let first = min(count, capacity - start)
        (storage + start).update(from: src, count: first)
        if first < count { storage.update(from: src + first, count: count - first) }

        os_unfair_lock_lock(&lock)
        writeCount += count
        os_unfair_lock_unlock(&lock)
    }

    /// Consumer side (drain queue). Returns how many frames were copied out.
    func read(into dst: UnsafeMutablePointer<Float>, max limit: Int) -> Int {
        os_unfair_lock_lock(&lock)
        let read = readCount
        let available = writeCount - readCount
        os_unfair_lock_unlock(&lock)

        let n = min(available, limit)
        guard n > 0 else { return 0 }

        let start = read % capacity
        let first = min(n, capacity - start)
        dst.update(from: storage + start, count: first)
        if first < n { (dst + first).update(from: storage, count: n - first) }

        os_unfair_lock_lock(&lock)
        readCount += n
        os_unfair_lock_unlock(&lock)
        return n
    }
}

// MARK: - Recorder

/// Everything a finished run needs to be written out. Passed in at `finish` so
/// the recorder itself doesn't have to know about the playback screen's state.
struct DebugRunContext {
    let exercise: Exercise
    /// The notes and labels as played — already expanded over the repetitions and
    /// transposed, so they are what the singer actually sang against.
    let notes: [MIDINote]
    let texts: [MIDIText]
    /// Every pitch estimate of the run, at the beat it was drawn at.
    let samples: [PitchSample]
    let bpm: Double
    let leadInBeats: Double
    let repeatSpan: Double
    let micDelayMs: Double
    let score: Int
}

/// Writes the microphone to a WAV while a run plays, and packages it with the
/// run's notes, pitch estimates and settings when the run finishes.
///
/// The tap callback only ever memcpys into a preallocated ring; the file writing
/// happens on a background queue. Recording must not change how much work the
/// audio thread does per hop, or it would change the very timing the recording
/// exists to capture.
final class DebugRunRecorder: DebugAudioSink {
    // Main-thread state.
    private var isRecording = false
    private var bpm: Double = 120
    /// Converts a microphone buffer's host time into the playback beat that was
    /// being heard at that instant. Supplied by the playback screen so this class
    /// needs no knowledge of the audio engine.
    private var beatForHostTime: ((UInt64) -> Double?)?
    private var startedAt = Date()
    private var route: RouteSnapshot?
    private var sampleRateChanged = false

    // Audio-file state, confined to `queue`.
    private let queue = DispatchQueue(label: "learn2sing.debug-recording", qos: .utility)
    private var file: AVAudioFile?
    private var writeBuffer: AVAudioPCMBuffer?
    private var framesWritten = 0
    private var drainTimer: DispatchSourceTimer?

    // Shared between the audio thread and the main thread.
    private var ring: FloatRing?
    private var sampleRate: Double = 0
    private var stateLock = os_unfair_lock_s()
    private var segments: [Segment] = []
    private var segment: Segment?
    private var framesAccepted = 0
    private var expectedSampleTime: AVAudioFramePosition?
    private var restartPending = true

    /// A stretch of microphone audio that is known to be continuous, with the
    /// beat its first frame was captured at. A run is normally one segment; a
    /// pause, a backgrounding or a dropped hop starts another, so the mapping
    /// from file frames to beats never has to assume audio that isn't there.
    private struct Segment {
        var startFrame: Int
        var frameCount: Int
        var hostTime: UInt64
        var beat: Double?
    }

    private struct RouteSnapshot {
        var inputs: [String]
        var outputs: [String]
        var inputLatency: Double
        var outputLatency: Double
        var ioBufferDuration: Double
        var sessionSampleRate: Double
    }

    // MARK: Lifecycle

    /// Arm the recorder. The file itself is opened when the tap starts and the
    /// microphone's sample rate is known.
    func start(bpm: Double, beatForHostTime: @escaping (UInt64) -> Double?) {
        cancel()
        Self.resetWorkspace()
        self.bpm = bpm
        self.beatForHostTime = beatForHostTime
        startedAt = Date()
        route = nil
        sampleRateChanged = false
        os_unfair_lock_lock(&stateLock)
        segments = []
        segment = nil
        framesAccepted = 0
        expectedSampleTime = nil
        restartPending = true
        os_unfair_lock_unlock(&stateLock)
        isRecording = true
    }

    /// Stop and throw away — a run that was left before it finished.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        stopWriting()
        Self.resetWorkspace()
    }

    /// Stop, close the WAV, write the sidecar JSON and hand back the pair.
    /// Returns nil if the run captured no audio (permission denied, say).
    func finish(_ context: DebugRunContext) -> DebugRunRecording? {
        guard isRecording else { return nil }
        isRecording = false

        os_unfair_lock_lock(&stateLock)
        if let open = segment { segments.append(open); segment = nil }
        let capturedSegments = segments
        os_unfair_lock_unlock(&stateLock)

        let audioURL = stopWriting()
        guard let audioURL, framesWritten > 0 else {
            Self.resetWorkspace()
            return nil
        }

        guard let data = metadata(context, segments: capturedSegments,
                                  audioFile: audioURL.lastPathComponent),
              (try? data.write(to: Self.runFolder.appendingPathComponent("recording.json"))) != nil
        else { return nil }

        // Give the folder the export's name before packaging, so an unzipped
        // recording says which run it is rather than "run".
        let stem = Self.exportStem(context.exercise, at: startedAt)
        let named = Self.root.appendingPathComponent(stem, isDirectory: true)
        try? FileManager.default.removeItem(at: named)
        let folder = (try? FileManager.default.moveItem(at: Self.runFolder, to: named)) != nil
            ? named : Self.runFolder
        return DebugRunRecording(
            folder: folder,
            loose: [folder.appendingPathComponent("recording.json"),
                    folder.appendingPathComponent(audioURL.lastPathComponent)],
            stem: stem)
    }

    // MARK: DebugAudioSink

    func begin(format: AVAudioFormat) {
        guard isRecording else { return }
        if file == nil {
            openFile(sampleRate: format.sampleRate)
            snapshotRoute()
        } else if format.sampleRate != sampleRate {
            // A route change mid-run would need a second file to stay honest.
            // Flagged instead, so the exported timings are never quietly wrong.
            sampleRateChanged = true
        }
        os_unfair_lock_lock(&stateLock)
        restartPending = true
        os_unfair_lock_unlock(&stateLock)
    }

    func append(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard isRecording, let ring, let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let host = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
        let sampleTime: AVAudioFramePosition? = time.isSampleTimeValid ? time.sampleTime : nil

        os_unfair_lock_lock(&stateLock)
        // Start a new segment whenever the tap's own sample clock jumps — a
        // restart after a pause, a route change, or a hop the system dropped.
        let jumped = sampleTime == nil || expectedSampleTime == nil || sampleTime != expectedSampleTime
        if restartPending || jumped {
            if let open = segment { segments.append(open) }
            segment = Segment(startFrame: framesAccepted, frameCount: 0, hostTime: host, beat: nil)
            restartPending = false
        }
        expectedSampleTime = sampleTime.map { $0 + AVAudioFramePosition(n) }
        let sinceSegmentStart = framesAccepted - (segment?.startFrame ?? framesAccepted)
        let needsAnchor = segment?.beat == nil
        os_unfair_lock_unlock(&stateLock)

        // The tap can start a hop or two before the engine's first render pass has
        // anchored the playback clock, so the anchor is resolved as soon as the
        // clock answers — wound back to where this segment actually began.
        if needsAnchor, sampleRate > 0, let beat = beatForHostTime?(host) {
            let elapsed = Double(sinceSegmentStart) / sampleRate * bpm / 60
            os_unfair_lock_lock(&stateLock)
            segment?.beat = beat - elapsed
            os_unfair_lock_unlock(&stateLock)
        }

        ring.write(channel, count: n)

        os_unfair_lock_lock(&stateLock)
        framesAccepted += n
        segment?.frameCount += n
        os_unfair_lock_unlock(&stateLock)
    }

    // MARK: File writing

    private func openFile(sampleRate rate: Double) {
        guard rate > 0 else { return }
        sampleRate = rate
        framesWritten = 0
        // Two seconds of slack between the tap and the disk, drained ten times a
        // second — far more headroom than the writes need.
        ring = FloatRing(capacity: Int(rate * 2))

        let url = Self.runFolder.appendingPathComponent("microphone.wav")
        // 16-bit PCM: the mic's usable dynamic range with room to spare (the
        // detector's own silence gate sits at 0.012 full scale), a quarter the
        // size of float32, and readable by every WAV reader worth using.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Mono, matching the one channel the detector analyses.
        guard let opened = try? AVAudioFile(forWriting: url, settings: settings,
                                            commonFormat: .pcmFormatFloat32,
                                            interleaved: false),
              let scratch = AVAudioPCMBuffer(pcmFormat: opened.processingFormat,
                                             frameCapacity: AVAudioFrameCount(rate / 4))
        else { return }
        file = opened
        writeBuffer = scratch

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in self?.drain() }
        drainTimer = timer
        timer.resume()
    }

    /// Move whatever the tap has produced into the file. Only ever runs on `queue`.
    private func drain() {
        guard let file, let buffer = writeBuffer, let ring,
              let dst = buffer.floatChannelData?[0] else { return }
        while true {
            let n = ring.read(into: dst, max: Int(buffer.frameCapacity))
            guard n > 0 else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            try? file.write(from: buffer)
            framesWritten += n
        }
    }

    /// Flush, close the file (which is what writes the WAV header) and return its
    /// URL. Safe to call when nothing is open.
    @discardableResult
    private func stopWriting() -> URL? {
        drainTimer?.cancel()
        drainTimer = nil
        var url: URL?
        queue.sync {
            drain()
            url = file?.url
            file = nil          // deinit finalises the header
            writeBuffer = nil
        }
        return url
    }

    private func snapshotRoute() {
        // Read while the session is still live: by the time the run finishes the
        // playback screen has already torn it down.
        let session = AVAudioSession.sharedInstance()
        func describe(_ ports: [AVAudioSessionPortDescription]) -> [String] {
            ports.map { "\($0.portName) [\($0.portType.rawValue)]" }
        }
        route = RouteSnapshot(inputs: describe(session.currentRoute.inputs),
                              outputs: describe(session.currentRoute.outputs),
                              inputLatency: session.inputLatency,
                              outputLatency: session.outputLatency,
                              ioBufferDuration: session.ioBufferDuration,
                              sessionSampleRate: session.sampleRate)
    }

    // MARK: Workspace

    /// Everything this feature writes lives under here, and only the most recent
    /// run's worth of it: the whole tree goes when the next run starts, so the
    /// debug feature can't quietly fill the disk.
    private static var root: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugRecordings", isDirectory: true)
    }

    /// Where the run is written while it plays. Renamed to the export's own name
    /// at the end, so unzipping the export gives a folder you can tell apart from
    /// the next one.
    private static var runFolder: URL {
        let url = root.appendingPathComponent("run", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func resetWorkspace() {
        try? FileManager.default.removeItem(at: root)
    }

    /// `Learn2Sing-<exercise>-<timestamp>`, safe to use as a file name.
    private static func exportStem(_ exercise: Exercise, at date: Date) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = String(exercise.name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .split(separator: "-").joined(separator: "-")
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return "Learn2Sing-\(name.isEmpty ? "Exercise" : name)-\(stamp.string(from: date))"
    }

    // MARK: Metadata

    private func metadata(_ context: DebugRunContext, segments: [Segment],
                          audioFile: String) -> Data? {
        let defaults = UserDefaults.standard
        let custom = VocalRange.customRange
        let iso = ISO8601DateFormatter()

        let document = DocumentJSON(
            format: "learn2sing-debug-recording",
            version: 1,
            readme: [
                "A single run of one exercise: the raw microphone audio, the notes it was sung against, and every pitch estimate the app drew.",
                "Beat 0 is the first beat of the exercise as drawn. Audio and playback both begin at -exercise.leadInBeats.",
                "audio.segments[i].beat is the playback beat that was being heard from the speaker at the instant that segment's first audio frame was captured. Frame f of a segment therefore sits at beat = segment.beat + (f - segment.startFrame) / audio.sampleRate * exercise.bpm / 60.",
                "pitchSamples[j].beat is the beat at which the app *drew* that estimate, so it already lags the audio that produced it by the microphone's round-trip latency plus the analysis window. settings.microphoneDelayMs is the user's compensation for exactly that lag: scoring treats the notes as sounding that much later, and the review screen shifts the sung line that much earlier.",
                "pitchSamples[j].pitch is a fractional MIDI note number, or null where the detector found nothing.",
                "A run is normally one audio segment. More than one means the tap restarted (a pause, a backgrounding) or the system dropped hops; audio.droppedFrames counts frames lost because the writer fell behind.",
            ],
            recordedAt: iso.string(from: startedAt),
            app: AppJSON(
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
                device: Self.hardwareModel(),
                systemVersion: UIDevice.current.systemVersion),
            exercise: ExerciseJSON(
                id: context.exercise.id.uuidString,
                name: context.exercise.name,
                bpm: context.exercise.bpm,
                pitchShift: context.exercise.pitchShift,
                repeatCount: context.exercise.repeatCount,
                transposePerRepeat: context.exercise.transposePerRepeat,
                switchDirectionAfter: context.exercise.switchDirectionAfter,
                speedPerRepeat: context.exercise.speedPerRepeat,
                beatsBetweenReps: context.exercise.beatsBetweenReps,
                repeatSpanBeats: context.repeatSpan,
                leadInBeats: context.leadInBeats),
            settings: SettingsJSON(
                microphoneDelayMs: context.micDelayMs,
                vocalRange: defaults.string(forKey: VocalRange.storageKey) ?? "",
                vocalRangeCustomLow: custom.low,
                vocalRangeCustomHigh: custom.high,
                instrument: Instrument.current.rawValue,
                selectedMicrophone: defaults.string(forKey: AudioRouteManager.micKey)
                    ?? AudioRouteManager.automatic,
                selectedSpeaker: defaults.string(forKey: AudioRouteManager.speakerKey)
                    ?? AudioRouteManager.automatic,
                language: LanguageManager.shared.language.rawValue),
            audio: AudioJSON(
                file: audioFile,
                sampleRate: sampleRate,
                channels: 1,
                bitDepth: 16,
                frameCount: framesWritten,
                durationSeconds: sampleRate > 0 ? round(Double(framesWritten) / sampleRate, 4) : 0,
                droppedFrames: ring?.dropped ?? 0,
                sampleRateChangedMidRun: sampleRateChanged,
                inputRoute: route?.inputs ?? [],
                outputRoute: route?.outputs ?? [],
                inputLatencySeconds: round(route?.inputLatency ?? 0, 6),
                outputLatencySeconds: round(route?.outputLatency ?? 0, 6),
                ioBufferDurationSeconds: round(route?.ioBufferDuration ?? 0, 6),
                sessionSampleRate: route?.sessionSampleRate ?? 0,
                segments: segments.map {
                    SegmentJSON(startFrame: $0.startFrame, frameCount: $0.frameCount,
                                hostTime: $0.hostTime, beat: $0.beat.map { round($0, 5) })
                }),
            score: context.score,
            notes: context.notes.map {
                NoteJSON(pitch: $0.pitch, beat: round($0.beat, 5), length: round($0.length, 5))
            },
            texts: context.texts.map {
                TextJSON(text: $0.text, pitch: $0.pitch, beat: round($0.beat, 5))
            },
            pitchSamples: context.samples.map {
                SampleJSON(beat: round($0.beat, 5), pitch: $0.pitch.map { round($0, 4) })
            })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try? encoder.encode(document)
    }

    private func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        let machine = info.machine
        return withUnsafePointer(to: machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: machine)) {
                String(cString: $0)
            }
        }
    }
}

// MARK: - Exported JSON

private struct DocumentJSON: Encodable {
    let format: String
    let version: Int
    let readme: [String]
    let recordedAt: String
    let app: AppJSON
    let exercise: ExerciseJSON
    let settings: SettingsJSON
    let audio: AudioJSON
    let score: Int
    let notes: [NoteJSON]
    let texts: [TextJSON]
    let pitchSamples: [SampleJSON]
}

private struct AppJSON: Encodable {
    let version: String
    let build: String
    let device: String
    let systemVersion: String
}

private struct ExerciseJSON: Encodable {
    let id: String
    let name: String
    let bpm: Double
    let pitchShift: Int
    let repeatCount: Int
    let transposePerRepeat: Int
    let switchDirectionAfter: Int
    let speedPerRepeat: Int
    let beatsBetweenReps: Double
    /// One repetition at the exercise's own tempo. With `speedPerRepeat` set the
    /// repetitions are scaled off this, so read the notes for where they landed.
    let repeatSpanBeats: Double
    let leadInBeats: Double
}

private struct SettingsJSON: Encodable {
    let microphoneDelayMs: Double
    let vocalRange: String
    let vocalRangeCustomLow: Int
    let vocalRangeCustomHigh: Int
    let instrument: String
    let selectedMicrophone: String
    let selectedSpeaker: String
    let language: String
}

private struct AudioJSON: Encodable {
    let file: String
    let sampleRate: Double
    let channels: Int
    let bitDepth: Int
    let frameCount: Int
    let durationSeconds: Double
    let droppedFrames: Int
    let sampleRateChangedMidRun: Bool
    let inputRoute: [String]
    let outputRoute: [String]
    let inputLatencySeconds: Double
    let outputLatencySeconds: Double
    let ioBufferDurationSeconds: Double
    let sessionSampleRate: Double
    let segments: [SegmentJSON]
}

private struct SegmentJSON: Encodable {
    let startFrame: Int
    let frameCount: Int
    let hostTime: UInt64
    /// nil if the playback clock never answered for this segment, which would
    /// mean its audio can't be placed on the beat timeline.
    let beat: Double?
}

private struct NoteJSON: Encodable {
    let pitch: Int
    let beat: Double
    let length: Double
}

private struct TextJSON: Encodable {
    let text: String
    let pitch: Int
    let beat: Double
}

/// Written with an explicit null rather than an omitted key, so a gap in the
/// detection is visible in the file instead of having to be inferred.
private struct SampleJSON: Encodable {
    let beat: Double
    let pitch: Double?

    private enum CodingKeys: String, CodingKey { case beat, pitch }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(beat, forKey: .beat)
        if let pitch { try c.encode(pitch, forKey: .pitch) } else { try c.encodeNil(forKey: .pitch) }
    }
}

// MARK: - The finished recording

/// A run that has been written to disk and is being packaged for the share
/// sheet. Zipping a few megabytes takes a moment, so it happens off the main
/// thread while the score screen is already up and the button waits for it.
final class DebugRunRecording: ObservableObject {
    /// What to hand the share sheet: one zip, or — if zipping failed — the JSON
    /// and the WAV loose. Empty until packaging finishes.
    @Published private(set) var files: [URL] = []

    init(folder: URL, loose: [URL], stem: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let packaged = Self.zip(folder: folder, named: stem) ?? loose
            DispatchQueue.main.async { self?.files = packaged }
        }
    }

    /// Zip the folder using the coordinated-read trick — `.forUploading` on a
    /// directory hands back a zip of it, with no third-party code involved. The
    /// archive only exists for the length of the accessor block, so it is copied
    /// out before returning.
    private static func zip(folder: URL, named stem: String) -> [URL]? {
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &error) { temporary in
            let destination = folder.deletingLastPathComponent()
                .appendingPathComponent("\(stem).zip")
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: temporary, to: destination)) != nil {
                result = destination
            }
        }
        return result.map { [$0] }
    }
}

// MARK: - Score-screen button

/// The export button on the score screen. Deliberately not styled like the rest
/// of that screen — it's a debug affordance and should look like one.
///
/// Every label goes through `Text(verbatim:)` so `Tools/Localization/extract.py`
/// skips it and this feature never shows up as a missing translation.
struct DebugRecordingExportButton: View {
    @ObservedObject var recording: DebugRunRecording
    /// Landscape, where the score screen has no room for another full-width row
    /// and the button joins the icons at the bottom instead.
    var compact = false

    /// Matches the score screen's own button row.
    private let height: CGFloat = 54
    private let tint = Color.orange

    var body: some View {
        if recording.files.isEmpty {
            preparing
        } else if compact {
            ShareLink(items: recording.files) { icon }
                .accessibilityLabel(Text(verbatim: "Export debug recording"))
        } else {
            ShareLink(items: recording.files) { row }
        }
    }

    private var icon: some View {
        Image(systemName: "ladybug.fill")
            .font(.headline)
            .frame(width: height, height: height)
            .background(tint, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
    }

    private var row: some View {
        HStack(spacing: 8) {
            Image(systemName: "ladybug.fill")
            Text(verbatim: "Export Debug Recording")
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding()
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(tint)
    }

    private var preparing: some View {
        Group {
            if compact {
                ProgressView()
                    .frame(width: height, height: height)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(verbatim: "Packaging Recording…")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(tint)
    }
}
