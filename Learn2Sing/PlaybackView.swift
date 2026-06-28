import SwiftUI
import AVFoundation
import os

// MARK: - Instrument timbre

// Each instrument is defined purely by its harmonic content + amplitude envelope,
// so the same DSP renders identically on the simulator and on a real device — no
// external SoundFont/DLS file (which only ships on macOS) is involved.
private struct InstrumentSpec {
    let harmonics: [Double]   // relative amplitude of each overtone (1st = fundamental)
    let attack: Double        // seconds to full volume
    let decay: Double         // seconds from peak to sustain level (sustained instruments)
    let sustain: Double       // sustain level 0...1 (sustained instruments)
    let release: Double       // seconds to fade after note-off
    let decayToZero: Bool     // plucked/struck: ring out & fade even while held
    let decayRate: Double     // ring-out speed when decayToZero
    let vibratoDepth: Double   // ± fraction of frequency
    let vibratoRate: Double    // Hz
    let gain: Double          // overall output level
}

private extension Instrument {
    var spec: InstrumentSpec {
        switch self {
        case .sine:
            return InstrumentSpec(
                harmonics: [1.0],
                attack: 0.02, decay: 0.0, sustain: 1.0, release: 0.15,
                decayToZero: false, decayRate: 0,
                vibratoDepth: 0, vibratoRate: 0, gain: 0.30)
        case .piano:
            return InstrumentSpec(
                harmonics: [1.0, 0.55, 0.38, 0.22, 0.14, 0.09, 0.05, 0.03],
                attack: 0.005, decay: 0.0, sustain: 0.0, release: 0.18,
                decayToZero: true, decayRate: 2.2,
                vibratoDepth: 0, vibratoRate: 0, gain: 0.28)
        case .guitar:
            return InstrumentSpec(
                harmonics: [1.0, 0.7, 0.5, 0.45, 0.3, 0.22, 0.16, 0.1, 0.06],
                attack: 0.004, decay: 0.0, sustain: 0.0, release: 0.12,
                decayToZero: true, decayRate: 3.2,
                vibratoDepth: 0, vibratoRate: 0, gain: 0.26)
        case .voice:
            // Vowel-like formant emphasis on the 2nd/3rd harmonic + gentle vibrato.
            return InstrumentSpec(
                harmonics: [0.7, 1.0, 0.85, 0.4, 0.25, 0.15, 0.08],
                attack: 0.06, decay: 0.08, sustain: 0.85, release: 0.22,
                decayToZero: false, decayRate: 0,
                vibratoDepth: 0.012, vibratoRate: 5.5, gain: 0.30)
        }
    }
}

// MARK: - Audio engine (custom additive synthesiser)

final class ExercisePlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!

    private let sampleRate: Double = 44100

    // Voice state — only touched on the audio thread except via the lock below.
    private struct Voice {
        var pitch: Int = -1
        var freq: Double = 0
        var phase: Double = 0
        var age: Double = 0          // seconds since note-on
        var released: Bool = false
        var releaseAge: Double = 0   // seconds since note-off
        var active: Bool = false
    }
    private static let maxVoices = 24
    private var voices = [Voice](repeating: Voice(), count: maxVoices)
    private var spec = Instrument.current.spec
    private var lock = os_unfair_lock_s()

    // Click playback: when `clickMode` is on, each note-on plays the loaded sample
    // (e.g. a metronome click) instead of a synthesised note. `clickCursors` holds
    // the play position of each currently sounding click so several can overlap.
    private var clickMode = false
    private var clickSamples: [Float]? = nil
    private var clickCursors: [Int] = []
    private let clickGain = 0.9

    // Sample-accurate note schedule, driven entirely from the audio render thread
    // so note durations don't drift with main-thread load (which independent
    // dispatch timers for note-on/off would suffer from).
    private struct Event {
        var sample: Int    // absolute sample index at which it fires
        var pitch: Int
        var on: Bool
    }
    private var events: [Event] = []
    private var eventIndex = 0
    private var playhead = 0        // samples elapsed since the schedule started
    private var finishSample = Int.max
    private var finished = true
    private var onFinish: (() -> Void)?

    // Host time at which sample 0 of the current schedule is played by the engine.
    // Captured in the render block so the on-screen clock can be anchored to the
    // real audio output (which the engine buffers well ahead of "now").
    private var timebase = mach_timebase_info_data_t()
    private var startHostTime: UInt64 = 0
    private var startCaptured = false
    private var needsStartCapture = false

    // The engine should be running between begin() and stop(); used to restart it
    // after the system tears down its IO (e.g. when the mic engine starts and
    // triggers a configuration change), without resurrecting it after teardown.
    private var shouldRun = false
    private var configObserver: NSObjectProtocol?

    init() {
        mach_timebase_info(&timebase)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        sourceNode = AVAudioSourceNode { [weak self] _, timestamp, frameCount, ablPointer -> OSStatus in
            self?.render(frameCount: Int(frameCount), hostTime: timestamp.pointee.mHostTime, abl: ablPointer)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        // The engine is *not* started here. It's started in begin() after the audio
        // route has been configured, so the very first rendered sample already targets
        // the final output (e.g. AirPods). Starting it earlier and then switching the
        // route mid-stream is what delayed the audio, glitched timing and stuttered.

        // iOS stops the engine when the audio IO is reconfigured — most notably when
        // the pitch detector's input engine starts a moment after this one. Without
        // restarting here the source node never renders again, so the playback clock
        // (anchored to the first rendered sample) never starts and the notes sit
        // frozen even though the mic-driven indicator keeps moving.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.shouldRun, !self.engine.isRunning else { return }
            try? self.engine.start()
        }
    }

    /// Start the audio engine. Call only after the session/route is configured so the
    /// output clock anchors to the correct route from the first buffer onward.
    func begin() {
        shouldRun = true
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    /// Stop rendering while the app is backgrounded. The playhead is preserved so the
    /// exercise resumes from the same spot; `shouldRun` stays set so the config-change
    /// observer and resume() can bring the engine back.
    func pauseForBackground() {
        if engine.isRunning { engine.pause() }
    }

    /// Restart after returning from the background and re-anchor the on-screen clock
    /// to the audio's current playhead so the two don't drift apart by the time spent
    /// away. Safe to call only between begin() and stop().
    func resumeFromBackground() {
        guard shouldRun else { return }
        os_unfair_lock_lock(&lock)
        needsStartCapture = true   // next render re-anchors startHostTime to the playhead
        os_unfair_lock_unlock(&lock)
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    // MARK: Real-time render

    private func render(frameCount: Int, hostTime: UInt64, abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let twoPi = 2.0 * Double.pi
        let dt = 1.0 / sampleRate

        os_unfair_lock_lock(&lock)
        if needsStartCapture {
            // `hostTime` is when the first sample of this buffer (sample `playhead`)
            // is played, so the host time for sample 0 is that minus the playhead's
            // duration. At the initial start playhead == 0, so this is just hostTime;
            // after a background pause the playhead has advanced, and subtracting it
            // re-anchors the on-screen clock to the audio's real position — keeping
            // visuals and audio in sync no matter how long the app was away.
            let playheadNs = Double(playhead) / sampleRate * 1.0e9
            let playheadTicks = UInt64(playheadNs * Double(timebase.denom) / Double(timebase.numer))
            startHostTime = hostTime > playheadTicks ? hostTime - playheadTicks : hostTime
            startCaptured = true
            needsStartCapture = false
        }
        let spec = self.spec
        let harmonics = spec.harmonics
        let invHarm = 1.0 / harmonics.reduce(0, +)
        let gain = spec.gain

        for frame in 0..<frameCount {
            // Fire any note-on/off events due at this exact sample.
            let currentSample = playhead + frame
            while eventIndex < events.count && events[eventIndex].sample <= currentSample {
                let e = events[eventIndex]
                if clickMode {
                    if e.on { clickCursors.append(0) }   // start a click; note-offs unused
                } else if e.on {
                    startVoiceLocked(pitch: e.pitch)
                } else {
                    releaseVoiceLocked(pitch: e.pitch)
                }
                eventIndex += 1
            }

            var mix = 0.0
            for vi in 0..<voices.count where voices[vi].active {
                var v = voices[vi]

                // Frequency (with optional vibrato) → phase increment.
                let vib = spec.vibratoDepth > 0
                    ? 1.0 + spec.vibratoDepth * sin(twoPi * spec.vibratoRate * v.age)
                    : 1.0
                let inc = twoPi * v.freq * vib * dt

                // Timbre from summed harmonics.
                var tone = 0.0
                for k in 0..<harmonics.count {
                    tone += harmonics[k] * sin(Double(k + 1) * v.phase)
                }
                tone *= invHarm

                // Amplitude envelope.
                let base: Double
                if v.age < spec.attack {
                    base = v.age / spec.attack
                } else if spec.decayToZero {
                    base = exp(-(v.age - spec.attack) * spec.decayRate)
                } else if v.age < spec.attack + spec.decay {
                    base = 1.0 - (1.0 - spec.sustain) * ((v.age - spec.attack) / spec.decay)
                } else {
                    base = spec.sustain
                }
                let rel = v.released ? exp(-v.releaseAge / spec.release) : 1.0
                let env = base * rel

                mix += tone * env

                // Advance voice.
                v.phase += inc
                if v.phase > twoPi { v.phase -= twoPi }
                v.age += dt
                if v.released { v.releaseAge += dt }
                if env < 0.0004 && (v.released || (spec.decayToZero && v.age > spec.attack)) {
                    v.active = false
                }
                voices[vi] = v
            }

            var out = mix * gain

            // Mix in any sounding clicks (the metronome), advancing each cursor.
            if clickMode, let click = clickSamples {
                var clickMix = 0.0
                for i in 0..<clickCursors.count {
                    let idx = clickCursors[i]
                    if idx < click.count {
                        clickMix += Double(click[idx])
                        clickCursors[i] = idx + 1
                    }
                }
                out += clickMix * clickGain
            }

            let sample = Float(tanh(out))   // soft-clip the summed output
            for buffer in buffers {
                let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
                ptr[frame] = sample
            }
        }
        playhead += frameCount

        // Drop clicks that have finished playing so the cursor list stays small.
        if clickMode, let count = clickSamples?.count {
            clickCursors.removeAll { $0 >= count }
        }

        // Notify completion once all events have fired and the tail has elapsed.
        if !finished && eventIndex >= events.count && playhead >= finishSample {
            finished = true
            let callback = onFinish
            onFinish = nil
            if let callback { DispatchQueue.main.async(execute: callback) }
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Note control (called from the render thread with the lock held)

    func setInstrument(_ instrument: Instrument) {
        os_unfair_lock_lock(&lock)
        spec = instrument.spec
        os_unfair_lock_unlock(&lock)
    }

    /// Turn click playback on/off. When on, note-on events trigger the loaded click
    /// sample instead of synthesised notes (used by the delay test's metronome).
    func setClickMode(_ on: Bool) {
        os_unfair_lock_lock(&lock)
        clickMode = on
        clickCursors.removeAll()
        os_unfair_lock_unlock(&lock)
    }

    /// Decode a bundled audio file into a mono sample buffer at the engine's sample
    /// rate, ready to be played on each tick in click mode. Safe to call once before
    /// scheduling; does nothing if the file is missing or can't be decoded.
    func loadClick(named name: String, ext: String = "mp3") {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let file = try? AVAudioFile(forReading: url) else { return }

        let inFormat = file.processingFormat
        let inFrames = AVAudioFrameCount(file.length)
        guard inFrames > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames),
              (try? file.read(into: inBuffer)) != nil else { return }

        // Convert to mono Float32 at the engine sample rate so it mixes directly.
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate, channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return }
        let outCapacity = AVAudioFrameCount(Double(inFrames) * sampleRate / inFormat.sampleRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, let channel = outBuffer.floatChannelData else { return }

        let n = Int(outBuffer.frameLength)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = channel[0][i] }

        os_unfair_lock_lock(&lock)
        clickSamples = samples
        os_unfair_lock_unlock(&lock)
    }

    /// Seconds between a sample being rendered and it actually being heard, so the
    /// Extra delay between a sample leaving the engine and reaching the speaker.
    private var outputLatency: TimeInterval {
        AVAudioSession.sharedInstance().outputLatency
    }

    /// The musical beat currently being *heard*, anchored to the audio engine's own
    /// output clock (so it stays in sync regardless of how far ahead the engine
    /// buffers). Returns nil until playback has actually started.
    func currentBeat(bpm: Double, leadIn: Double) -> Double? {
        os_unfair_lock_lock(&lock)
        let captured = startCaptured
        let startHost = startHostTime
        os_unfair_lock_unlock(&lock)
        guard captured else { return nil }

        let now = mach_absolute_time()
        let elapsedTicks = now > startHost ? now - startHost : 0
        let elapsedSec = Double(elapsedTicks) * Double(timebase.numer) / Double(timebase.denom) / 1.0e9
        let audibleSec = elapsedSec - outputLatency      // account for the DAC delay
        return audibleSec * (bpm / 60.0) - leadIn
    }

    /// The beat that was being *heard from the speaker* at a given host time — the
    /// same mapping as `currentBeat` but for an arbitrary past instant. Used by the
    /// delay test: feeding it the host time at which a clap was captured yields the
    /// clap's position relative to the metronome ticks (which sit on whole beats),
    /// so the gap to the nearest tick is exactly the round-trip microphone delay.
    func beat(forHostTime hostTime: UInt64, bpm: Double, leadIn: Double) -> Double? {
        os_unfair_lock_lock(&lock)
        let captured = startCaptured
        let startHost = startHostTime
        os_unfair_lock_unlock(&lock)
        guard captured else { return nil }

        let elapsedTicks = hostTime > startHost ? hostTime - startHost : 0
        let elapsedSec = Double(elapsedTicks) * Double(timebase.numer) / Double(timebase.denom) / 1.0e9
        let audibleSec = elapsedSec - outputLatency
        return audibleSec * (bpm / 60.0) - leadIn
    }

    private func startVoiceLocked(pitch: Int) {
        let freq = 440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
        // Reuse a free voice, else steal the oldest one.
        var idx = voices.firstIndex { !$0.active }
        if idx == nil {
            idx = (0..<voices.count).max { voices[$0].age < voices[$1].age }
        }
        if let i = idx {
            voices[i] = Voice(pitch: pitch, freq: freq, phase: 0, age: 0,
                              released: false, releaseAge: 0, active: true)
        }
    }

    private func releaseVoiceLocked(pitch: Int) {
        for i in 0..<voices.count where voices[i].active && !voices[i].released && voices[i].pitch == pitch {
            voices[i].released = true
            voices[i].releaseAge = 0
        }
    }

    // MARK: Scheduling

    func schedule(notes: [MIDINote], bpm: Double, leadIn: Double, preview: Bool = true,
                  onFinish: @escaping () -> Void) {
        let secPerBeat = 60.0 / bpm

        var events: [Event] = []
        events.reserveCapacity(notes.count * 2 + 2)
        for note in notes {
            let onSample  = Int((note.beat + leadIn) * secPerBeat * sampleRate)
            let offSample = Int((note.beat + note.length + leadIn) * secPerBeat * sampleRate)
            events.append(Event(sample: onSample,  pitch: note.pitch, on: true))
            events.append(Event(sample: offSample, pitch: note.pitch, on: false))
        }

        // Preview the first note before the exercise begins: sound its pitch for
        // two beats, leave a one-beat pause, then let the exercise start on time.
        // These events are added only to the audio schedule (not the drawn `notes`)
        // so the preview is heard but never appears in the animation. It lives
        // inside the silent lead-in, so the exercise itself isn't shifted.
        if preview, let firstNote = notes.min(by: { $0.beat < $1.beat }) {
            let firstBeat = firstNote.beat + leadIn
            let previewOn  = firstBeat - 3.0   // 2 beats sounding + 1 beat pause
            let previewOff = firstBeat - 1.0
            if previewOn >= 0 {
                events.append(Event(sample: Int(previewOn  * secPerBeat * sampleRate),
                                    pitch: firstNote.pitch, on: true))
                events.append(Event(sample: Int(previewOff * secPerBeat * sampleRate),
                                    pitch: firstNote.pitch, on: false))
            }
        }
        // Sort by time; at the same instant fire note-offs before note-ons so a
        // repeated pitch is released before its next strike begins.
        events.sort { $0.sample != $1.sample ? $0.sample < $1.sample : (!$0.on && $1.on) }

        let lastBeat = notes.map { $0.beat + $0.length }.max() ?? 0
        let finishSample = Int((lastBeat + leadIn + 1.0) * secPerBeat * sampleRate)

        os_unfair_lock_lock(&lock)
        self.events = events
        self.eventIndex = 0
        self.playhead = 0
        self.finishSample = finishSample
        self.finished = false
        self.onFinish = onFinish
        self.startCaptured = false
        self.needsStartCapture = true
        for i in 0..<voices.count { voices[i].active = false }
        os_unfair_lock_unlock(&lock)
    }

    func cancelAll() {
        os_unfair_lock_lock(&lock)
        events = []
        eventIndex = 0
        finishSample = Int.max
        finished = true
        onFinish = nil
        startCaptured = false
        needsStartCapture = false
        for i in 0..<voices.count { voices[i].active = false }
        os_unfair_lock_unlock(&lock)
    }

    /// Cancel the schedule and stop the engine. Idempotent: stopping an engine that
    /// isn't running is skipped so repeated teardown calls (finish, then onDisappear,
    /// then deinit) are harmless and never block on an already-stopped engine.
    func stop() {
        shouldRun = false
        cancelAll()
        if engine.isRunning { engine.stop() }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        stop()
    }
}

// MARK: - PlaybackView

/// Holds the on-screen pitch of the singer indicator, eased toward the latest
/// microphone estimate once per rendered frame so the dot moves smoothly even
/// though new estimates arrive less often than the display refreshes.
private final class SingerIndicator {
    private var shown: Double? = nil

    /// Advance one frame toward `target` and return the value to draw.
    func step(target: Double?, factor: Double) -> Double? {
        guard let target else { shown = nil; return nil }
        if let current = shown {
            shown = current + (target - current) * factor
        } else {
            shown = target
        }
        return shown
    }
}

/// Records the singer's pitch over time so a trailing line can show a brief
/// history of what they sang. Each sample is anchored to the musical beat at
/// which it was heard, so it scrolls left in lockstep with the notes. A `nil`
/// pitch marks a gap (no detected pitch) so the line breaks instead of jumping.
private final class PitchTrail {
    struct Sample { let beat: Double; let pitch: Double? }
    private(set) var samples: [Sample] = []

    func record(beat: Double, pitch: Double?) {
        samples.append(Sample(beat: beat, pitch: pitch))
    }

    /// Drop samples that have scrolled off the left edge of the note area.
    func prune(before beat: Double) {
        if let idx = samples.firstIndex(where: { $0.beat >= beat }) {
            if idx > 0 { samples.removeFirst(idx) }
        } else {
            samples.removeAll()
        }
    }
}

/// Accumulates how much of the exercise the singer covered correctly. For every
/// rendered frame it adds the elapsed beat-time of each active note during which
/// the singer's trailing pitch line lay within that note's drawn rectangle. The
/// final score is `coveredBeats / (sum of all note lengths)`, so if half of the
/// notes' combined length was sung on pitch the score is 50%.
private final class Scorer {
    private(set) var coveredBeats: Double = 0
    private var lastBeat: Double? = nil

    func reset() {
        coveredBeats = 0
        lastBeat = nil
    }

    /// Integrate one frame of coverage. `tolerance` is the vertical reach of the
    /// trailing pitch line expressed in semitones, so the score reflects exactly
    /// when the drawn line is over a note. A note counts for the frame if the
    /// singer's pitch is within `tolerance` of it while the note is sounding.
    ///
    /// `noteShift` (in beats) shifts every note later in time *for scoring only*, to
    /// compensate for the lag between singing and pitch detection: a note is treated
    /// as sounding over `[beat + noteShift, ...]`, so detection that arrives late
    /// still lines up with it. Playback and visuals are unaffected.
    func update(beat: Double, notes: [MIDINote], singerPitch: Double?, tolerance: Double, noteShift: Double) {
        defer { lastBeat = beat }
        guard let last = lastBeat else { return }
        let dt = beat - last
        // Ignore non-advancing frames and large jumps (e.g. a restart) so the
        // integral can't be corrupted by a discontinuity in the playhead.
        guard dt > 0, dt < 0.5 else { return }
        guard let pitch = singerPitch else { return }
        for note in notes where beat >= note.beat + noteShift && beat < note.beat + note.length + noteShift {
            if abs(pitch - Double(note.pitch)) <= tolerance {
                coveredBeats += dt
            }
        }
    }

    /// Final score as a whole-number percentage (0...100).
    func score(notes: [MIDINote]) -> Int {
        let total = notes.reduce(0.0) { $0 + $1.length }
        guard total > 0 else { return 0 }
        return min(100, max(0, Int((coveredBeats / total * 100).rounded())))
    }
}

/// What an exercise is measuring. A normal exercise scores the singer's pitch; the
/// delay test instead times the singer's claps against the metronome to calibrate
/// the microphone delay.
enum PlaybackMode {
    case normal
    case delayTest
}

/// Collects the beat position of each detected clap during the delay test. A class
/// (reference type) so it can be appended to from the per-frame draw pass without
/// mutating SwiftUI `@State` during a view update.
private final class ClapCollector {
    private(set) var beats: [Double] = []
    func add(_ beat: Double) { beats.append(beat) }
    func reset() { beats.removeAll() }
}

struct PlaybackView: View {
    let exercise: Exercise
    var mode: PlaybackMode = .normal

    @State private var player = ExercisePlayer()
    @StateObject private var pitchDetector = PitchDetector()
    @State private var indicator = SingerIndicator()
    @State private var trail = PitchTrail()
    @State private var scorer = Scorer()
    @State private var notes: [MIDINote] = []
    @State private var texts: [MIDIText] = []
    @State private var finalScore: Int? = nil
    @State private var claps = ClapCollector()
    @State private var delayResultMs: Double? = nil
    @State private var visuals = VisualSettings.current
    @State private var follower = VerticalFollower()
    // Vertical centre of each repetition's pitch range, plus one repetition's length
    // in beats — used by "follow notes vertically" to recentre once per repetition.
    @State private var repetitionCenters: [Double] = []
    @State private var repeatSpan: Double = 0
    @AppStorage(microphoneDelayKey) private var micDelayMs = 0.0
    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private let leadIn: Double = 6       // silent beats before first note
    private let pianoW: CGFloat = 38
    private let beatPx: CGFloat = 40     // pixels per beat in playback view

    // Delay-test layout: a run of equally spaced metronome ticks the user claps to.
    // The first `warmupClaps` let the singer lock onto the tempo and are excluded
    // from the measurement; the next `countedClaps` are averaged into the result.
    private let warmupClaps = 4
    private let countedClaps = 16
    private var totalClaps: Int { warmupClaps + countedClaps }
    // The delay-test ticks sit on this row purely for vertical placement — it lands
    // near the middle of the visible pitch range so the cue is centred on screen.
    private let delayTestPitch = 53      // F3 by height

    private var bpm: Double { mode == .delayTest ? 160 : exercise.bpm }

    var body: some View {
        Group {
            if let delayResultMs {
                DelayResultView(delayMs: delayResultMs) { dismiss() }
            } else if let finalScore {
                ScoreView(score: finalScore) { dismiss() }
            } else {
                playback
            }
        }
    }

    private var playback: some View {
        TimelineView(.animation) { _ in
            // Drive the playhead from the audio engine's own output clock so the
            // notes light up exactly when they're heard.
            let beat = player.currentBeat(bpm: bpm, leadIn: leadIn) ?? -leadIn

            // Ease the indicator toward the latest estimate every frame.
            let singerPitch = indicator.step(target: pitchDetector.currentPitch, factor: 0.3)

            Canvas { ctx, size in
                drawScene(ctx: ctx, size: size, beat: beat, singerPitch: singerPitch)
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Order matters: configure the route first, load the notes, start the
            // engine on that settled route, and only then schedule (which anchors the
            // playback clock). This keeps audio and the animation in sync and stops
            // playback from starting partway through while the exercise is still loading.
            AudioRouteManager.shared.configureSession()
            // Pick up the latest visual settings and start the vertical follower fresh.
            visuals = VisualSettings.current
            follower.reset()
            if mode == .delayTest { loadDelayTestNotes() } else { loadNotes() }
            player.begin()
            // The delay test plays a metronome sample on every tick (in sync with the
            // engine clock) instead of a synthesised note; normal exercises use the
            // user's chosen instrument.
            if mode == .delayTest {
                player.loadClick(named: "metronome")
                player.setClickMode(true)
            } else {
                player.setClickMode(false)
                player.setInstrument(Instrument.current)
            }
            scorer.reset()
            claps.reset()
            pitchDetector.detectClaps = (mode == .delayTest)
            player.schedule(notes: notes, bpm: bpm, leadIn: leadIn,
                            preview: mode == .normal) {
                if mode == .delayTest {
                    // Convert the detected claps to beat positions *before* tearing
                    // the audio down — the conversion needs the engine's still-live
                    // playback clock to anchor each clap against the metronome ticks.
                    for host in pitchDetector.drainClaps() {
                        if let clapBeat = player.beat(forHostTime: host, bpm: bpm, leadIn: leadIn) {
                            claps.add(clapBeat)
                        }
                    }
                    let ms = measuredDelayMs()
                    teardownAudio()
                    micDelayMs = ms.rounded()   // replace the setting automatically
                    delayResultMs = ms.rounded()
                } else {
                    // Tear the audio down fully before revealing the score so it has no
                    // engine running. Stopping both engines together (rather than only
                    // the mic, leaving the synth rendering on the shared playAndRecord
                    // session) is what avoids the intermittent freeze when navigating back.
                    teardownAudio()
                    finalScore = scorer.score(notes: notes)
                }
            }
            pitchDetector.start()
        }
        .onDisappear {
            teardownAudio()
        }
        .onChange(of: scenePhase) { _, phase in
            // The audio engine stops while the app is backgrounded but the on-screen
            // clock is wall-clock based, so without this they'd drift apart. Pause on
            // the way out and, on return, reconfigure the route and resume — which
            // re-anchors the clock to the audio playhead so they stay in sync.
            guard finalScore == nil, delayResultMs == nil else { return }   // nothing to sync on a result screen
            switch phase {
            case .active:
                AudioRouteManager.shared.configureSession()
                player.resumeFromBackground()
                pitchDetector.start()
            case .background:
                player.pauseForBackground()
                pitchDetector.stop()
            default:
                break
            }
        }
    }

    // MARK: - Drawing

    private func drawScene(ctx: GraphicsContext, size: CGSize, beat: Double, singerPitch: Double?) {
        let s = visuals

        // Layout scalars from the visual settings: rows scale with vertical zoom,
        // beats with horizontal zoom, and the keyboard column vanishes when hidden.
        let baseRowH = size.height / CGFloat(hiPitch - loPitch + 1)
        let rowH = baseRowH * CGFloat(s.verticalZoom)
        let beatPxZoom = beatPx * CGFloat(s.horizontalZoom)
        let pW: CGFloat = s.showKeyboard ? pianoW : 0
        let playheadX = size.width / 3

        // Vertical centre. Normally the whole keyboard's midpoint; when "follow notes
        // vertically" is on, recentre once per repetition: take the centre of whichever
        // repetition the playhead is currently in and ease toward it, so the view holds
        // steady through a repetition and only moves when the next one begins.
        let defaultCenter = Double(hiPitch + loPitch) / 2
        let centerPitch: Double
        if s.followNotesVertically, repeatSpan > 0, !repetitionCenters.isEmpty {
            let idx = max(0, min(repetitionCenters.count - 1, Int(floor(beat / repeatSpan))))
            centerPitch = follower.step(target: repetitionCenters[idx], factor: 0.08)
        } else {
            centerPitch = defaultCenter
        }

        let layout = SceneLayout(size: size, pianoW: pW, rowH: rowH, beatPx: beatPxZoom,
                                 playheadX: playheadX, centerPitch: centerPitch)

        // ── Singer's pitch history (trailing line) ───────────────────────────
        // Record this frame's pitch at the current beat, drop whatever scrolled off
        // the left edge, then build the path through the layout's coordinate mapping.
        trail.record(beat: beat, pitch: singerPitch)
        trail.prune(before: beat - Double((playheadX - pW) / beatPxZoom))

        let r = min(rowH * 0.85, 11)
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, r), size.height - r) }
        var trailPath = Path()
        var penDown = false
        for sample in trail.samples {
            guard let p = sample.pitch else { penDown = false; continue }
            let pt = CGPoint(x: layout.x(sample.beat, beat: beat), y: clampY(layout.y(p)))
            if penDown { trailPath.addLine(to: pt) } else { trailPath.move(to: pt); penDown = true }
        }

        // Score this frame from the trailing pitch line: a note counts only while the
        // line sits within its drawn rectangle. The tolerance is derived from the
        // *unzoomed* row height so the score doesn't change when the user zooms.
        let lineToleranceSemitones = Double(((baseRowH - 2) / 2 + 1.25) / baseRowH)
        // Convert the user's microphone-delay setting (ms) into beats so notes are
        // scored as if shifted that far to the right (later in time).
        let noteShift = micDelayMs / 1000.0 * bpm / 60.0
        if mode == .normal {
            scorer.update(beat: beat, notes: notes, singerPitch: singerPitch,
                          tolerance: lineToleranceSemitones, noteShift: noteShift)
        }

        drawPlaybackScene(ctx: ctx, layout: layout, beat: beat, notes: notes, texts: texts,
                          trailPath: trailPath, singerPitch: singerPitch, settings: s)
    }

    // MARK: - Teardown

    /// Stop both audio engines and release the session. Idempotent — the engines'
    /// own guards make the second call (finish, then onDisappear) a no-op — so it's
    /// safe to call from the finish callback and again when the view goes away.
    private func teardownAudio() {
        player.stop()
        pitchDetector.stop()
        AudioRouteManager.shared.deactivateSession()
    }

    // MARK: - Delay test

    /// Build the delay-test pattern in memory: one short metronome tick per beat,
    /// each with a "*clap*" label sitting just above it, so the existing playback
    /// screen renders the cue with no special drawing code.
    private func loadDelayTestNotes() {
        var ns: [MIDINote] = []
        var ts: [MIDIText] = []
        for i in 0..<totalClaps {
            ns.append(MIDINote(pitch: delayTestPitch, beat: Double(i), length: 0.1))
            ts.append(MIDIText(text: "*clap*", pitch: delayTestPitch + 3, beat: Double(i)))
        }
        notes = ns
        texts = ts
    }

    /// Average lag between each counted clap and the metronome tick that prompted it.
    /// Ticks sit on whole beats, so the nearest integer beat is the intended tick;
    /// claps near a warm-up tick or further than half a beat from any tick (stray
    /// noise) are ignored. The mean over the random human timing error cancels out,
    /// leaving the systematic microphone round-trip delay.
    private func measuredDelayMs() -> Double {
        let secPerBeat = 60.0 / bpm
        var offsets: [Double] = []
        for clapBeat in claps.beats {
            let tick = clapBeat.rounded()
            guard tick >= Double(warmupClaps), tick <= Double(totalClaps - 1) else { continue }
            let offset = clapBeat - tick
            guard abs(offset) <= 0.5 else { continue }
            offsets.append(offset * secPerBeat)
        }
        guard !offsets.isEmpty else { return 0 }
        let mean = offsets.reduce(0, +) / Double(offsets.count)
        return max(0, mean * 1000.0)   // a delay can't be negative for compensation
    }

    // MARK: - Persistence

    private func loadNotes() {
        let key = "midi_\(exercise.id.uuidString)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([MIDINote].self, from: data)
        else { return }

        // Length of one repetition, rounded up to a whole beat so repeats stay aligned,
        // plus any silent beats the user wants between repetitions.
        let patternEnd = saved.map { $0.beat + $0.length }.max() ?? 0
        let repeatSpan = patternEnd.rounded(.up) + max(0, exercise.beatsBetweenReps)
        let repeats = max(1, exercise.repeatCount)

        // Expand the pattern: each repetition is shifted later in time and
        // transposed by `transposePerRepeat` semitones. Applying the same
        // transform to the drawn notes keeps playback and animation in sync.
        var expanded: [MIDINote] = []
        for rep in 0..<repeats {
            let transpose = cumulativeTranspose(forRepetition: rep)
            for note in saved {
                var n = note
                n.id = UUID()
                n.pitch += exercise.pitchShift + transpose
                n.beat += Double(rep) * repeatSpan
                expanded.append(n)
            }
        }

        // Text labels share the note coordinate system, so apply the identical
        // expansion (beat shift + transpose per repeat) to keep them pinned to the
        // notes they annotate as the pattern repeats and scrolls.
        var savedTexts: [MIDIText] = []
        if let data = UserDefaults.standard.data(forKey: "miditext_\(exercise.id.uuidString)"),
           let decoded = try? JSONDecoder().decode([MIDIText].self, from: data) {
            savedTexts = decoded
        }
        var expandedTexts: [MIDIText] = []
        for rep in 0..<repeats {
            let transpose = cumulativeTranspose(forRepetition: rep)
            for label in savedTexts {
                var t = label
                t.id = UUID()
                t.pitch += exercise.pitchShift + transpose
                t.beat += Double(rep) * repeatSpan
                expandedTexts.append(t)
            }
        }

        // Finally, if the singer has set a vocal range, transpose the whole exercise
        // (notes and their labels together) to fit it: never let a note drop below
        // the voice's lowest note, lowering the exercise only when its top pokes
        // above the voice's highest note. Applied to the fully expanded pitches so
        // every repetition's transposition is accounted for.
        var vocalShift = 0
        if let range = VocalRange(rawValue: vocalRangeRaw),
           let lo = expanded.map(\.pitch).min(),
           let hi = expanded.map(\.pitch).max() {
            vocalShift = range.fitTranspose(low: lo, high: hi)
            if vocalShift != 0 {
                for i in expanded.indices { expanded[i].pitch += vocalShift }
                for i in expandedTexts.indices { expandedTexts[i].pitch += vocalShift }
            }
        }

        notes = expanded
        texts = expandedTexts

        // Pre-compute the vertical centre of each repetition (the midpoint of its
        // pitch range) so "follow notes vertically" can recentre once per repetition.
        // Each repetition's range is the pattern's range shifted by that repetition's
        // cumulative transpose, plus the global pitch- and vocal-range shifts.
        self.repeatSpan = repeatSpan
        if let pMin = saved.map(\.pitch).min(), let pMax = saved.map(\.pitch).max() {
            let baseMid = Double(pMin + pMax) / 2
            repetitionCenters = (0..<repeats).map { rep in
                baseMid + Double(exercise.pitchShift + cumulativeTranspose(forRepetition: rep) + vocalShift)
            }
        } else {
            repetitionCenters = []
        }
    }

    /// Cumulative semitone offset for a given repetition (0-based). Each repetition
    /// shifts by `transposePerRepeat` from the one before it. If `switchDirectionAfter`
    /// is set, the direction flips exactly once after that many repetitions — counting
    /// the untransposed first repetition — then keeps going the new way for the rest.
    /// E.g. step +1, switchAfter 1 over 5 reps gives 0, -1, -2, -3, -4 (one up step is
    /// "spent" on the first repetition, so the switch lands immediately after it).
    private func cumulativeTranspose(forRepetition rep: Int) -> Int {
        let step = exercise.transposePerRepeat
        let switchAfter = exercise.switchDirectionAfter
        guard rep > 0 else { return 0 }
        guard switchAfter > 0 else { return rep * step }   // never switches

        var offset = 0
        for r in 1...rep {
            // The first `switchAfter` repetitions (including the untransposed one at
            // r == 0) go in the initial direction; from there on it's reversed.
            let direction = r >= switchAfter ? -1 : 1
            offset += direction * step
        }
        return offset
    }
}

// MARK: - ScoreView

/// Shown after an exercise finishes: the score centred on screen with a single
/// button to leave. Tinted from red (low) through to green (high) so the result
/// reads at a glance.
private struct ScoreView: View {
    let score: Int
    let onExit: () -> Void

    private var tint: Color {
        Color(hue: Double(score) / 100.0 * 0.33, saturation: 0.85, brightness: 0.95)
    }

    var body: some View {
        VStack {
            Spacer()

            Text("Score")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text("\(score)%")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .contentTransition(.numericText())

            Spacer()

            Button(action: onExit) {
                Text("Exit")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }
}

// MARK: - DelayResultView

/// Shown after the microphone delay test: the measured delay in milliseconds, which
/// has already replaced the saved microphone-delay setting, plus a button to leave.
private struct DelayResultView: View {
    let delayMs: Double
    let onExit: () -> Void

    var body: some View {
        VStack {
            Spacer()

            Text("Microphone Delay")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text("\(Int(delayMs)) ms")
                .font(.system(size: 80, weight: .bold, design: .rounded))
                .foregroundStyle(.cyan)
                .contentTransition(.numericText())

            Text("Your microphone delay setting has been updated.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 8)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: onExit) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.cyan.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
    }
}
