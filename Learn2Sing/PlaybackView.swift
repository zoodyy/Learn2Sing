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

    // Rich (piano-like) rendering. Any non-zero value switches the voice to the
    // per-partial path: independent phase, decay and detune per overtone.
    var partialDecayStretch: Double = 0  // extra decay rate per partial index (highs die faster)
    var inharmonicity: Double = 0        // B coefficient: partial k at k·f0·√(1+B·k²)
    var decayKeyTrack: Double = 0        // decay-rate octaves per octave above middle C
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
            // Starts brighter than the old mix because the upper partials decay
            // away quickly (partialDecayStretch) — bright hammer strike settling
            // into a mellow, slowly beating sustain, instead of a static organ tone.
            return InstrumentSpec(
                harmonics: [1.0, 0.62, 0.45, 0.32, 0.25, 0.18, 0.13, 0.09, 0.06, 0.04],
                attack: 0.002, decay: 0.0, sustain: 0.0, release: 0.10,
                decayToZero: true, decayRate: 0.9,
                vibratoDepth: 0, vibratoRate: 0, gain: 0.32,
                partialDecayStretch: 0.55, inharmonicity: 0.00045,
                decayKeyTrack: 0.8)
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
        var decayRate: Double = 0    // spec.decayRate scaled by the note's pitch
    }
    private static let maxVoices = 24
    private static let maxPartials = 16
    private var voices = [Voice](repeating: Voice(), count: maxVoices)
    private var spec = Instrument.current.spec
    private var lock = os_unfair_lock_s()

    // Per-voice per-partial state for the rich (piano-like) path, preallocated as
    // flat [voice × partial] arrays so the render thread never allocates.
    private var partialPhase = [Double](repeating: 0, count: maxVoices * maxPartials)
    private var partialInc   = [Double](repeating: 0, count: maxVoices * maxPartials)
    private var partialEnv   = [Double](repeating: 0, count: maxVoices * maxPartials)
    private var partialFade  = [Double](repeating: 0, count: maxVoices * maxPartials)

    // Cheap audio-thread RNG (xorshift64) for the partials' random start phases.
    private var noiseState: UInt64 = 0x9E3779B97F4A7C15
    private func nextRandom() -> Double {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 7
        noiseState ^= noiseState << 17
        return Double(Int64(bitPattern: noiseState)) / Double(Int64.max)   // -1...1
    }

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
    //
    // These three live behind `clockLock` rather than the render lock, which the audio
    // thread holds for a whole buffer at a time: the view asks for the beat on every
    // rendered frame, and making it queue behind a render pass put a jitter of up to a
    // buffer's worth of work into the notes' motion. `clockLock` is only ever held for
    // a handful of word-sized reads. When both are taken it's always render lock first.
    private var timebase = mach_timebase_info_data_t()
    private var clockLock = os_unfair_lock_s()
    private var startHostTime: UInt64 = 0
    private var startCaptured = false
    private var needsStartCapture = false

    // Extra delay between a sample leaving the engine and reaching the speaker. Read
    // from the audio session when the route settles rather than on every frame — it
    // only changes with the route, and the session's own accessor is not something to
    // call 60–120 times a second on the main thread.
    private var cachedOutputLatency: TimeInterval = 0
    private var routeObserver: NSObjectProtocol?

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

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshOutputLatency()
        }
    }

    /// Start the audio engine. Call only after the session/route is configured so the
    /// output clock anchors to the correct route from the first buffer onward.
    func begin() {
        shouldRun = true
        refreshOutputLatency()
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
        refreshOutputLatency()
        os_unfair_lock_lock(&clockLock)
        needsStartCapture = true   // next render re-anchors startHostTime to the playhead
        // Until that render happens the old anchor is stale (it would include all the
        // paused wall-clock time and read far ahead), so report "no clock" instead —
        // currentBeat returns nil and the view holds its last frame rather than
        // flicking every note to the left for a frame.
        startCaptured = false
        os_unfair_lock_unlock(&clockLock)
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

        // The engine's format is non-interleaved stereo, so this is one pointer per
        // channel. Resolved once per buffer rather than per sample, which is where the
        // list subscript and pointer rebind used to run tens of thousands of times a
        // second for no reason.
        let left = buffers.count > 0 ? buffers[0].mData?.assumingMemoryBound(to: Float.self) : nil
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        os_unfair_lock_lock(&lock)
        os_unfair_lock_lock(&clockLock)
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
        os_unfair_lock_unlock(&clockLock)
        let spec = self.spec
        let harmonics = spec.harmonics
        let invHarm = 1.0 / harmonics.reduce(0, +)
        let gain = spec.gain
        let rich = spec.partialDecayStretch > 0 || spec.inharmonicity > 0

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

                var tone = 0.0
                if rich {
                    // Per-partial rendering: each overtone has its own (inharmonic)
                    // frequency and its own decay — highs die faster — so the
                    // spectrum evolves like a struck string's.
                    let base = vi * Self.maxPartials
                    for k in 0..<min(harmonics.count, Self.maxPartials) {
                        let i = base + k
                        let env = partialEnv[i]
                        if env > 0.0001 {
                            tone += harmonics[k] * env * sin(partialPhase[i])
                            partialEnv[i] = env * partialFade[i]
                        }
                        partialPhase[i] += partialInc[i]
                        if partialPhase[i] > twoPi { partialPhase[i] -= twoPi }
                    }
                    tone *= invHarm
                } else {
                    // Frequency (with optional vibrato) → phase increment.
                    let vib = spec.vibratoDepth > 0
                        ? 1.0 + spec.vibratoDepth * sin(twoPi * spec.vibratoRate * v.age)
                        : 1.0
                    let inc = twoPi * v.freq * vib * dt

                    // Timbre from summed harmonics.
                    for k in 0..<harmonics.count {
                        tone += harmonics[k] * sin(Double(k + 1) * v.phase)
                    }
                    tone *= invHarm

                    v.phase += inc
                    if v.phase > twoPi { v.phase -= twoPi }
                }

                // Amplitude envelope.
                let base: Double
                if v.age < spec.attack {
                    base = v.age / spec.attack
                } else if spec.decayToZero {
                    base = exp(-(v.age - spec.attack) * v.decayRate)
                } else if v.age < spec.attack + spec.decay {
                    base = 1.0 - (1.0 - spec.sustain) * ((v.age - spec.attack) / spec.decay)
                } else {
                    base = spec.sustain
                }
                let rel = v.released ? exp(-v.releaseAge / spec.release) : 1.0
                let env = base * rel

                mix += tone * env

                // Advance voice.
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
            left?[frame] = sample
            right?[frame] = sample
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
              let samples = monoSamples(at: url, sampleRate: sampleRate) else { return }

        os_unfair_lock_lock(&lock)
        clickSamples = samples
        os_unfair_lock_unlock(&lock)
    }

    /// Re-read the route's output latency. Called when the engine starts, when it
    /// resumes and whenever the route changes — the only times it can differ.
    private func refreshOutputLatency() {
        cachedOutputLatency = AVAudioSession.sharedInstance().outputLatency
    }

    /// The musical beat currently being *heard*, anchored to the audio engine's own
    /// output clock (so it stays in sync regardless of how far ahead the engine
    /// buffers). Returns nil until playback has actually started.
    func currentBeat(bpm: Double, leadIn: Double) -> Double? {
        os_unfair_lock_lock(&clockLock)
        let captured = startCaptured
        let startHost = startHostTime
        os_unfair_lock_unlock(&clockLock)
        guard captured else { return nil }

        let now = mach_absolute_time()
        let elapsedTicks = now > startHost ? now - startHost : 0
        let elapsedSec = Double(elapsedTicks) * Double(timebase.numer) / Double(timebase.denom) / 1.0e9
        let audibleSec = elapsedSec - cachedOutputLatency   // account for the DAC delay
        return audibleSec * (bpm / 60.0) - leadIn
    }

    /// The beat that was being *heard from the speaker* at a given host time — the
    /// same mapping as `currentBeat` but for an arbitrary past instant. Used by the
    /// delay test: feeding it the host time at which a clap was captured yields the
    /// clap's position relative to the metronome ticks (which sit on whole beats),
    /// so the gap to the nearest tick is exactly the round-trip microphone delay.
    func beat(forHostTime hostTime: UInt64, bpm: Double, leadIn: Double) -> Double? {
        os_unfair_lock_lock(&clockLock)
        let captured = startCaptured
        let startHost = startHostTime
        os_unfair_lock_unlock(&clockLock)
        guard captured else { return nil }

        let elapsedTicks = hostTime > startHost ? hostTime - startHost : 0
        let elapsedSec = Double(elapsedTicks) * Double(timebase.numer) / Double(timebase.denom) / 1.0e9
        let audibleSec = elapsedSec - cachedOutputLatency
        return audibleSec * (bpm / 60.0) - leadIn
    }

    private func startVoiceLocked(pitch: Int) {
        let freq = 440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
        // Reuse a free voice, else steal the oldest one.
        var idx = voices.firstIndex { !$0.active }
        if idx == nil {
            idx = (0..<voices.count).max { voices[$0].age < voices[$1].age }
        }
        guard let i = idx else { return }

        // Higher notes decay faster, low notes ring longer (like real strings).
        let decayRate = spec.decayRate
            * pow(2.0, Double(pitch - 60) / 12.0 * spec.decayKeyTrack)
        voices[i] = Voice(pitch: pitch, freq: freq, phase: 0, age: 0,
                          released: false, releaseAge: 0, active: true,
                          decayRate: decayRate)

        // Set up the per-partial tables for the rich (piano-like) path: stretched
        // (inharmonic) partial frequencies, random start phases, and a per-partial
        // fade so upper partials decay away faster.
        if spec.partialDecayStretch > 0 || spec.inharmonicity > 0 {
            let dt = 1.0 / sampleRate
            let twoPi = 2.0 * Double.pi
            let base = i * Self.maxPartials
            let bCoeff = spec.inharmonicity
            for k in 0..<min(spec.harmonics.count, Self.maxPartials) {
                let n = Double(k + 1)
                let f = freq * n * (bCoeff > 0 ? (1 + bCoeff * n * n).squareRoot() : 1)
                let j = base + k
                // Partials at or above Nyquist would alias — silence them.
                if f >= sampleRate * 0.45 {
                    partialEnv[j] = 0
                    partialInc[j] = 0
                    continue
                }
                partialInc[j] = twoPi * f * dt
                partialPhase[j] = (nextRandom() + 1) * Double.pi
                partialEnv[j] = 1
                partialFade[j] = exp(-dt * decayRate * spec.partialDecayStretch * Double(k))
            }
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
                  repeatLayout: RepeatLayout = RepeatLayout(), betweenReps: Double = 0,
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

        // Preview the first note of each repetition before it begins: sound its
        // pitch for two beats, leave a one-beat pause, then let that repetition start
        // on time. These events are added only to the audio schedule (not the drawn
        // `notes`), so the preview is heard but never appears in the animation and is
        // never scored. The first repetition's preview lives inside the silent lead-in.
        // Later repetitions only get one when the gap between reps is at least three
        // beats — the preview's two-beat tone plus one-beat pause — so it fits inside
        // the silence without colliding with the previous repetition.
        if preview {
            // Earliest note of each repetition. Each repetition's first note already
            // carries that rep's transposition, so its pitch is the right one to
            // preview.
            var firstByRep: [Int: MIDINote] = [:]
            for note in notes {
                let rep = repeatLayout.index(at: note.beat)
                if let existing = firstByRep[rep], existing.beat <= note.beat { continue }
                firstByRep[rep] = note
            }
            for (rep, firstNote) in firstByRep {
                if rep >= 1 && betweenReps < 3 { continue }
                // Measured in the beats of the silence the preview sits in, so it
                // stays inside that gap however the repetitions are sped up.
                let firstBeat = firstNote.beat + leadIn
                let previewOn  = repeatLayout.beat(3.0, before: rep, startingAt: firstBeat)
                let previewOff = repeatLayout.beat(1.0, before: rep, startingAt: firstBeat)
                if previewOn >= 0 {
                    events.append(Event(sample: Int(previewOn  * secPerBeat * sampleRate),
                                        pitch: firstNote.pitch, on: true))
                    events.append(Event(sample: Int(previewOff * secPerBeat * sampleRate),
                                        pitch: firstNote.pitch, on: false))
                }
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
        os_unfair_lock_lock(&clockLock)
        self.startCaptured = false
        self.needsStartCapture = true
        os_unfair_lock_unlock(&clockLock)
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
        os_unfair_lock_lock(&clockLock)
        startCaptured = false
        needsStartCapture = false
        os_unfair_lock_unlock(&clockLock)
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
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        stop()
    }
}

// MARK: - PlaybackView

/// Holds the on-screen pitch of the singer indicator, eased toward the latest
/// microphone estimate once per rendered frame so the dot moves smoothly even
/// though new estimates arrive less often than the display refreshes.
private final class SingerIndicator {
    private var shown: Double? = nil

    /// How far the target may sit above the drawn value before the ease stops
    /// closing a fixed *fraction* of the gap and starts closing a fixed *amount*.
    ///
    /// Easing by a fraction means one wrong estimate drags the dot in proportion to
    /// how wrong it was: an octave-away reading moved it a third of an octave, and
    /// then it took another ten frames to crawl back — one bad estimate, a swoop
    /// lasting a sixth of a second. Capping the per-frame movement takes that away
    /// without slowing the singer down, because the two move at completely different
    /// speeds: over a whole run, 99% of the real frame-to-frame movement was under
    /// 1.8 semitones, while the bad estimates were 12 to 14 away. Anything inside the
    /// knee — all ordinary singing, and every note change in a normal exercise — eases
    /// exactly as it did before.
    private let knee = 3.0

    /// The last value drawn, kept across the gaps where nothing is detected so an
    /// estimate that reappears can be measured against where the singer actually was.
    private var lastShown: Double? = nil

    /// How far a reappearing estimate may sit from that before it stops being taken
    /// at face value. A note that has just started has to show at once — there is
    /// nothing to ease from, and easing in would be a delay the singer feels on every
    /// single note. But over a whole run the real re-entries all landed within 2.7
    /// semitones of the pitch before the gap, while the wrong ones landed 10 to 16
    /// away, so a bar between the two costs nothing and stops one bad estimate from
    /// throwing the dot across the screen the instant a note begins.
    private let reappearSnap = 5.0

    /// Advance one frame toward `target` and return the value to draw.
    func step(target: Double?, factor: Double) -> Double? {
        guard let target else { shown = nil; return nil }
        let from: Double
        if let current = shown {
            from = current
        } else if let last = lastShown, abs(target - last) > reappearSnap {
            from = last                     // implausible re-entry: ease in like any move
        } else {
            from = target                   // a note starting: show it where it is
        }
        let limit = factor * knee
        let next = from + min(limit, max(-limit, (target - from) * factor))
        shown = next
        lastShown = next
        return next
    }
}

/// Records the singer's pitch over time so a trailing line can show a brief
/// history of what they sang. Each sample is anchored to the musical beat at
/// which it was heard, so it scrolls left in lockstep with the notes. A `nil`
/// pitch marks a gap (no detected pitch) so the line breaks instead of jumping.
private final class PitchTrail {
    private(set) var samples: [PitchSample] = []

    /// The whole run, never pruned, so the review screen can draw the singer's
    /// complete line once the exercise has finished. `samples` above is only what
    /// is still on screen behind the indicator.
    private(set) var recording: [PitchSample] = []

    func record(beat: Double, pitch: Double?) {
        let sample = PitchSample(beat: beat, pitch: pitch)
        samples.append(sample)
        recording.append(sample)
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
    /// The tolerance the frames were scored with, remembered because `rescored`
    /// needs it and only the draw pass — which works it out from the canvas height
    /// — is in a position to know it.
    private var tolerance: Double = 0

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
        self.tolerance = tolerance
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

    /// The run just scored, scored again at a different microphone delay.
    ///
    /// `samples` is the pitch line the run recorded, which is the very `(beat,
    /// pitch)` pair `update` was handed on each frame, in order — so replaying it
    /// through a fresh scorer at `noteShift` gives exactly what the run would have
    /// scored had the setting been that all along.
    func rescored(samples: [PitchSample], notes: [MIDINote], noteShift: Double) -> Int {
        let replay = Scorer()
        for sample in samples {
            replay.update(beat: sample.beat, notes: notes, singerPitch: sample.pitch,
                          tolerance: tolerance, noteShift: noteShift)
        }
        return replay.score(notes: notes)
    }
}

/// What an exercise is measuring. A normal exercise scores the singer's pitch; the
/// two microphone-delay tests instead measure the lag between singing and detection.
enum PlaybackMode {
    case normal
    /// Times the singer's claps against a metronome and sets the delay from them.
    case clapDelayTest
    /// A normal run of one of the singer's own exercises which, instead of ending in
    /// the score, ends in the review screen with the offset controls: the singer
    /// lines their recorded line up with the notes and that offset becomes the delay.
    case sungDelayTest
}

/// Collects the beat position of each detected clap during the delay test. A class
/// (reference type) so it can be appended to from the per-frame draw pass without
/// mutating SwiftUI `@State` during a view update.
private final class ClapCollector {
    private(set) var beats: [Double] = []
    func add(_ beat: Double) { beats.append(beat) }
    func reset() { beats.removeAll() }
}

/// The beat drawn on the previous frame. While the playback clock is unanchored —
/// right after a pause is resumed, until the engine's next render pass recaptures
/// the start time — the view draws this instead of a stale or restarted beat, so
/// the notes hold still rather than flicker. A class (reference type) so the
/// per-frame draw pass can update it without mutating SwiftUI `@State` during a
/// view update.
private final class LastDrawnBeat {
    var value: Double? = nil
}

struct PlaybackView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let exercise: Exercise
    var mode: PlaybackMode = .normal
    /// What the microphone-delay result screen's Done button does instead of popping
    /// this screen — the sung test uses it to go back to the Audio settings, where
    /// the measured value is now in the delay field. nil keeps the default dismiss.
    var onDelayTestExit: (() -> Void)? = nil
    /// Title of the score screen's exit button ("Next" while a routine has more
    /// exercises to play).
    var scoreExitTitle = L("Exit")
    /// What the score screen's exit button does instead of popping this screen
    /// (routines advance to the next exercise). nil keeps the default dismiss.
    var onScoreExit: (() -> Void)? = nil
    /// Opens the intro screen of the exercise listed below this one, shown as an
    /// extra "Next" button on the score screen. nil (the last exercise of the list
    /// this one was played from) leaves the button out. Routines don't use this —
    /// there the exit button itself becomes "Next".
    var onScoreNext: (() -> Void)? = nil
    /// When set (playing from the Community tab), the score screen shows a Download
    /// button — same as the intro screen's — copying the exercise into the library.
    var onScoreDownload: (() -> Void)? = nil
    /// Public id of the community exercise being played, for the play this run
    /// posts when it finishes. Set from the Community tab, whose exercises carry
    /// their public id already; nil everywhere else, where the exercise holds the
    /// private id it is stored under and the public one is derived from it.
    var communityID: UUID? = nil

    @State private var player = ExercisePlayer()
    @StateObject private var pitchDetector = PitchDetector()
    @State private var indicator = SingerIndicator()
    @State private var trail = PitchTrail()
    @State private var scorer = Scorer()
    @State private var notes: [MIDINote] = []
    @State private var texts: [MIDIText] = []
    @State private var finalScore: Int? = nil
    /// Set while the score screen's Review button has the finished run's notes and
    /// pitch line open in place of the score.
    @State private var isReviewing = false
    /// Set when a run has played out and the microphone delay is what comes next:
    /// the same review screen takes over from playback, with the controls that dial
    /// the delay in. That is the whole point of the sung delay test, and the last
    /// step of the first run a singer scores anything on (see `MicDelayCalibration`).
    @State private var isCalibrating = false
    /// Set alongside it on that first run only, for the alert saying what the screen
    /// is for. The sung delay test was asked for and needs no explaining.
    @State private var isExplainingCalibration = false
    @State private var claps = ClapCollector()
    // DEBUG RECORDING — remove together with DebugRecording.swift.
    @State private var debugRecorder = DebugRunRecorder()
    @State private var debugRecording: DebugRunRecording? = nil
    @State private var delayResultMs: Double? = nil
    @State private var visuals = VisualSettings.current
    @State private var follower = VerticalFollower()
    /// Set while the user has playback paused via the toolbar button. Freezes the
    /// TimelineView (so the canvas holds its last frame) alongside the audio.
    @State private var isPaused = false
    /// Screen y of the pause button's frame, measured in the toolbar so the playhead
    /// line can stop level with the bar's buttons instead of at the screen edge.
    @State private var pauseButtonBottom: CGFloat? = nil
    @State private var lastDrawnBeat = LastDrawnBeat()
    // Vertical centre of each repetition's pitch range, plus where the repetitions sit
    // on the timeline — used by "follow notes vertically" to recentre once per
    // repetition, and by the repetition counter badge.
    @State private var repetitionCenters: [Double] = []
    @State private var repeatLayout = RepeatLayout()
    // Largest semitone distance from a repetition's centre to its furthest content
    // (note or text label), above or below. Constant across reps since each is the
    // same pattern transposed; used by "follow notes vertically" to zoom out when a
    // repetition is too tall to fit inside the safe area.
    @State private var repetitionMaxExtent: Double = 0
    @AppStorage(microphoneDelayKey) private var micDelayMs = 0.0
    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""
    @EnvironmentObject private var store: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    // Silent beats before the first note. Shared with `Exercise.runDuration`,
    // which measures the very run scheduled here.
    private let leadIn = Exercise.playbackLeadInBeats
    // Navigation-bar metrics for placing the top of the playhead line.
    private let navBarHeight: CGFloat = 54
    private let barButtonHeight: CGFloat = 44
    private let barButtonGlassInset: CGFloat = 4

    // Clap-test layout: a run of equally spaced metronome ticks the user claps to.
    // The first `warmupClaps` let the singer lock onto the tempo and are excluded
    // from the measurement; the next `countedClaps` are averaged into the result.
    private let warmupClaps = 4
    private let countedClaps = 16
    private var totalClaps: Int { warmupClaps + countedClaps }
    // The delay-test ticks sit on this row purely for vertical placement — it lands
    // near the middle of the visible pitch range so the cue is centred on screen.
    private let delayTestPitch = 53      // F3 by height

    private var bpm: Double { mode == .clapDelayTest ? 160 : exercise.bpm }

    /// How long a full run takes, in seconds: exactly the span the player
    /// schedules — the silent lead-in, every repetition (each already stretched
    /// to its own tempo in `notes`), and the beat it waits at the end. This is
    /// what a finished run adds to the Home tab's practice calendar.
    private var runDuration: Double {
        let lastBeat = notes.map { $0.beat + $0.length }.max() ?? 0
        return (lastBeat + leadIn + 1.0) * (60.0 / bpm)
    }

    /// Whether this run is one of the user's own exercises, played the way the
    /// Exercises tab plays it — true for a normal run and for the sung delay test,
    /// which only differs in where it goes once the exercise has played out.
    private var playsExercise: Bool { mode != .clapDelayTest }

    var body: some View {
        Group {
            if let delayResultMs {
                DelayResultView(delayMs: delayResultMs) {
                    if let onDelayTestExit { onDelayTestExit() } else { dismiss() }
                }
            } else if isCalibrating {
                // The finished run drawn as usual, with controls that slide the sung
                // line over the notes. Done saves what was dialled in; the back
                // button leaves without it. Where either goes next depends on which
                // run this was — see `calibrationDone` and `calibrationSkipped`.
                ExerciseReviewView(exercise: exercise, notes: notes, texts: texts,
                                   samples: trail.recording, bpm: bpm,
                                   repeatLayout: repeatLayout,
                                   onCalibrationDone: calibrationDone,
                                   onClose: calibrationSkipped)
            } else if let finalScore {
                if isReviewing {
                    ExerciseReviewView(exercise: exercise, notes: notes, texts: texts,
                                       samples: trail.recording, bpm: bpm,
                                       repeatLayout: repeatLayout) {
                        isReviewing = false
                    }
                } else {
                    ScoreView(score: finalScore,
                              history: ScoreHistory.entries(for: exercise.id),
                              exitTitle: scoreExitTitle,
                              // DEBUG RECORDING — remove with DebugRecording.swift
                              debugRecording: debugRecording,
                              onDownload: onScoreDownload,
                              onNext: onScoreNext,
                              onReview: { isReviewing = true },
                              onPlayAgain: {
                                  // Drop the previous run's trail/indicator so no ghost line
                                  // shows up; clearing the score remounts `playback`, whose
                                  // onAppear restarts audio and scoring from scratch.
                                  trail = PitchTrail()
                                  indicator = SingerIndicator()
                                  self.finalScore = nil
                              }) {
                        if let onScoreExit { onScoreExit() } else { dismiss() }
                    }
                }
            } else {
                playback
            }
        }
        // Kept on the whole flow (not just `playback`) so the bar doesn't pop back
        // in on the score screen between a routine's exercises.
        .toolbar(visuals.hideTabBar ? .hidden : .automatic, for: .tabBar)
        // What the calibration screen is doing there, the once it shows up
        // uninvited. Attached out here rather than to that screen so it is already
        // mounted when the flag is set, and goes up with the screen behind it.
        //
        // `L(_:)` inside the alert, per the localization notes: its button and its
        // message are built in the alert's own environment, which the locale set on
        // the tab view doesn't reach — only the title resolves against this view's.
        .alert("Microphone Delay", isPresented: $isExplainingCalibration) {
            Button(L("OK")) {}
        } message: {
            Text(L("Slide your singing until it lines up with the notes. The delay this sets only affects how your score is worked out, and you can redo it any time in Settings under Audio."))
        }
    }

    private var playback: some View {
        // The GeometryReader (which respects the safe area) reports the insets for the
        // title/back bar and bottom menu, while the Canvas inside ignores the safe area
        // and draws full-screen — so the insets tell drawScene where those bars sit.
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: nil, paused: isPaused)) { _ in
                // Drive the playhead from the audio engine's own output clock so the
                // notes light up exactly when they're heard. While the clock is
                // unanchored (before the first render, or right after resuming from a
                // pause) hold the previously drawn beat so nothing jumps.
                let beat = player.currentBeat(bpm: bpm, leadIn: leadIn)
                    ?? lastDrawnBeat.value ?? -leadIn

                // Ease the indicator toward the latest estimate every frame. A shade
                // quicker than it used to be, which pays back the little the cap in
                // `SingerIndicator` costs on the rare note change that clears its knee.
                let singerPitch = indicator.step(target: pitchDetector.currentPitch, factor: 0.35)

                Canvas { ctx, size in
                    lastDrawnBeat.value = beat
                    drawScene(ctx: ctx, size: size, beat: beat, singerPitch: singerPitch,
                              safeTop: geo.safeAreaInsets.top, safeBottom: geo.safeAreaInsets.bottom,
                              playheadTop: playheadTop(safeTop: geo.safeAreaInsets.top))
                }
                .ignoresSafeArea()
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(exercise.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // No pause during the clap test: re-anchoring the clock mid-test would
            // corrupt the beat positions of claps captured before the pause.
            if playsExercise {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        togglePause()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    }
                    .background(
                        GeometryReader { g in
                            Color.clear
                                .onAppear { pauseButtonBottom = g.frame(in: .global).maxY }
                                .onChange(of: g.frame(in: .global).maxY) { _, y in
                                    pauseButtonBottom = y
                                }
                        }
                    )
                }
            }
        }
        .onAppear {
            isPaused = false
            // A new run's clock is unanchored until its first render pass; start from
            // the lead-in again rather than holding the previous run's final beat.
            lastDrawnBeat.value = nil
            // Order matters: configure the route first, load the notes, start the
            // engine on that settled route, and only then schedule (which anchors the
            // playback clock). This keeps audio and the animation in sync and stops
            // playback from starting partway through while the exercise is still loading.
            AudioRouteManager.shared.configureSession()
            // Pick up the latest visual settings and start the vertical follower fresh.
            visuals = VisualSettings.current
            follower.reset()
            if playsExercise { loadNotes() } else { loadDelayTestNotes() }
            player.begin()
            // The clap test plays a metronome sample on every tick (in sync with the
            // engine clock) instead of a synthesised note; exercises use the user's
            // chosen instrument.
            if playsExercise {
                player.setClickMode(false)
                player.setInstrument(Instrument.current)
            } else {
                player.loadClick(named: "metronome")
                player.setClickMode(true)
            }
            scorer.reset()
            claps.reset()
            pitchDetector.detectClaps = (mode == .clapDelayTest)
            // DEBUG RECORDING — remove together with DebugRecording.swift.
            if mode == .normal {
                debugRecording = nil
                let clock = player
                debugRecorder.start(bpm: bpm) { host in
                    clock.beat(forHostTime: host, bpm: bpm, leadIn: leadIn)
                }
                pitchDetector.debugSink = debugRecorder
            }
            player.schedule(notes: notes, bpm: bpm, leadIn: leadIn,
                            preview: playsExercise,
                            repeatLayout: repeatLayout, betweenReps: exercise.beatsBetweenReps) {
                switch mode {
                case .clapDelayTest:
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
                case .sungDelayTest:
                    // Straight to the review screen, where the singer lines their own
                    // recorded line up with the notes. No score is worked out and
                    // nothing is written to the exercise's history: this run was a
                    // measurement, not practice.
                    teardownAudio()
                    isCalibrating = true
                case .normal:
                    // Tear the audio down fully before revealing the score so it has no
                    // engine running. Stopping both engines together (rather than only
                    // the mic, leaving the synth rendering on the shared playAndRecord
                    // session) is what avoids the intermittent freeze when navigating back.
                    teardownAudio()
                    let score = scorer.score(notes: notes)
                    // DEBUG RECORDING — remove together with DebugRecording.swift.
                    // After teardownAudio, so no more microphone hops can arrive.
                    debugRecording = debugRecorder.finish(
                        DebugRunContext(exercise: exercise, notes: notes, texts: texts,
                                        samples: trail.recording, bpm: bpm, leadInBeats: leadIn,
                                        repeatSpan: repeatLayout.span, micDelayMs: micDelayMs,
                                        score: score))
                    // The run played through to the end, so it counts for the
                    // Home tab's "Recent" category regardless of the score — and
                    // for its full length on the Home tab's calendar, which a
                    // run walked out of before this point never reaches.
                    store.markPlayed(exercise.id)
                    PracticeLog.record(seconds: runDuration)
                    if MicDelayCalibration.isNeeded(score: score, currentDelayMs: micDelayMs) {
                        // The first run the singer really sang along to. The score
                        // waits behind the calibration: the setting it depends on
                        // is about to become theirs, and the very first score they
                        // are shown — and that goes into the history and up to the
                        // server — should already be worked out with it.
                        MicDelayCalibration.markPrompted()
                        isCalibrating = true
                        isExplainingCalibration = true
                    } else {
                        finishRun(score: score)
                    }
                }
            }
            pitchDetector.start()
        }
        .onDisappear {
            teardownAudio()
            // DEBUG RECORDING — remove together with DebugRecording.swift.
            // A no-op once the run finished and handed its recording over; this
            // is what throws away a run the singer walked out of.
            pitchDetector.debugSink = nil
            debugRecorder.cancel()
        }
        .onChange(of: scenePhase) { _, phase in
            // The audio engine stops while the app is backgrounded but the on-screen
            // clock is wall-clock based, so without this they'd drift apart. Pause on
            // the way out and, on return, reconfigure the route and resume — which
            // re-anchors the clock to the audio playhead so they stay in sync.
            guard finalScore == nil, delayResultMs == nil else { return }   // nothing to sync on a result screen
            switch phase {
            case .active:
                guard !isPaused else { break }   // stay paused if the user paused before leaving
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

    // MARK: - Finishing a run

    /// Everything a finished run leaves behind that depends on its score, and the
    /// score screen it ends on. Held back on the run that detours through the
    /// calibration, so what the singer is shown — and what goes into the history and
    /// up to the server — is the score at the microphone delay they settled on there.
    private func finishRun(score: Int) {
        // Save before showing the result so the chart includes this run.
        ScoreHistory.record(score: score, for: exercise.id)
        // Count the run for everyone: the score goes up to the server with the play,
        // which averages it into the difficulty the intro screen's stars show. Only a
        // run that reached a score is worth posting, so this is the one place it
        // happens — a replay comes back through here with its own score.
        CommunitySync.shared.registerPlay(
            for: communityID ?? PublicIdentifier.exercise(exercise.id), score: score)
        finalScore = score
    }

    /// Done on the calibration screen: the offset the singer dialled in becomes the
    /// microphone-delay setting, whichever run took them there.
    ///
    /// The sung delay test then ends on the same result screen the clap test does —
    /// measuring that number was the whole errand. A real run instead carries on to
    /// its score, worked out again at the delay just set rather than at the one it
    /// was played under, so the number matches the line the singer has this second
    /// seen lying over the notes.
    private func calibrationDone(_ ms: Double) {
        let delay = ms.rounded()
        micDelayMs = delay
        if mode == .sungDelayTest {
            delayResultMs = delay
        } else {
            finishRun(score: scorer.rescored(samples: trail.recording, notes: notes,
                                             noteShift: micDelayBeats(delay, bpm: bpm)))
            isCalibrating = false
        }
    }

    /// The back button on the calibration screen. It abandons the sung delay test,
    /// which has nothing behind it to go back to; a real run keeps the score it
    /// earned at the delay it was played under and goes on to it — and, having been
    /// asked once, is never interrupted again.
    private func calibrationSkipped() {
        if mode == .sungDelayTest {
            dismiss()
        } else {
            finishRun(score: scorer.score(notes: notes))
            isCalibrating = false
        }
    }

    // MARK: - Drawing

    /// Y at which the playhead line starts: the bottom edge of the back/pause buttons
    /// in the navigation bar. Taken from the pause button's measured frame, grown by
    /// the inset between a bar button and the glass capsule drawn around it. The delay
    /// test has no pause button, so there it falls back to the gap the bar leaves below
    /// its buttons.
    private func playheadTop(safeTop: CGFloat) -> CGFloat {
        guard let bottom = pauseButtonBottom else {
            return max(0, safeTop - (navBarHeight - barButtonHeight))
        }
        return max(0, bottom + barButtonGlassInset)
    }

    private func drawScene(ctx: GraphicsContext, size: CGSize, beat: Double,
                           singerPitch: Double?, safeTop: CGFloat = 0, safeBottom: CGFloat = 0,
                           playheadTop: CGFloat = 0) {
        let s = visuals

        // Layout scalars from the visual settings: rows scale with vertical zoom,
        // beats with horizontal zoom, and the keyboard column vanishes when hidden.
        let baseRowH = size.height / CGFloat(hiPitch - loPitch + 1)
        var rowH = baseRowH * CGFloat(s.verticalZoom)
        let beatPxZoom = playbackBeatWidth * CGFloat(s.horizontalZoom)
        let pW: CGFloat = s.showKeyboard ? playbackKeyboardWidth : 0
        let playheadX = size.width / 3

        // Vertical centre. Normally the whole keyboard's midpoint; when "follow notes
        // vertically" is on, recentre once per repetition: take the centre of whichever
        // repetition the playhead is currently in and ease toward it, so the view holds
        // steady through a repetition and only moves when the next one begins.
        let defaultCenter = Double(hiPitch + loPitch) / 2
        let centerPitch: Double
        var centerY = size.height / 2
        if s.followNotesVertically, repeatLayout.count > 0, !repetitionCenters.isEmpty {
            let idx = min(repetitionCenters.count - 1, repeatLayout.index(at: beat))
            centerPitch = follower.step(target: repetitionCenters[idx], factor: 0.08)
            // Centre the content in the safe area — between the title/back bar at the
            // top and the menu at the bottom — and, if a repetition is too tall to fit
            // there at the chosen zoom, zoom out (never in) just enough that no note or
            // text label lands under those bars, keeping a one-row margin.
            centerY = (size.height + safeTop - safeBottom) / 2
            let usableHalf = (size.height - safeTop - safeBottom) / 2
            if repetitionMaxExtent > 0 {
                let fitRowH = usableHalf / CGFloat(repetitionMaxExtent + 1)
                rowH = min(rowH, fitRowH)
            }
        } else {
            centerPitch = defaultCenter
        }

        let layout = SceneLayout(size: size, pianoW: pW, rowH: rowH, beatPx: beatPxZoom,
                                 playheadX: playheadX, centerPitch: centerPitch, centerY: centerY)

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
        let noteShift = micDelayBeats(micDelayMs, bpm: bpm)
        // Neither delay test shows a score: the clap test has no sung notes to score,
        // and the sung one is measuring the very setting the score depends on.
        if mode == .normal {
            scorer.update(beat: beat, notes: notes, singerPitch: singerPitch,
                          tolerance: lineToleranceSemitones, noteShift: noteShift)
        }

        // Which repetition is playing, 1-based, for the optional on-screen counter.
        // Only supplied for exercises that actually repeat (repeat count > 1) and never
        // in the clap test; the renderer hides the badge when it's nil.
        let totalReps = max(1, exercise.repeatCount)
        var repetition: (current: Int, total: Int)? = nil
        if playsExercise, totalReps > 1, repeatLayout.count > 0 {
            let idx = min(totalReps - 1, repeatLayout.index(at: beat))
            repetition = (current: idx + 1, total: totalReps)
        }

        drawPlaybackScene(ctx: ctx, layout: layout, beat: beat, notes: notes, texts: texts,
                          trailPath: trailPath, singerPitch: singerPitch, settings: s,
                          repetition: repetition, safeTop: safeTop, safeBottom: safeBottom,
                          playheadTop: playheadTop, repeatLayout: repeatLayout)
    }

    // MARK: - Teardown

    /// Stop both audio engines and release the session. Idempotent — the engines'
    /// own guards make the second call (finish, then onDisappear) a no-op — so it's
    /// safe to call from the finish callback and again when the view goes away.
    /// Pause/resume from the toolbar button, reusing the backgrounding path: the
    /// engine keeps its playhead while paused, and resuming re-anchors the on-screen
    /// clock to it so audio and animation stay in sync across the gap.
    private func togglePause() {
        if isPaused {
            AudioRouteManager.shared.configureSession()
            player.resumeFromBackground()
            pitchDetector.start()
            isPaused = false
        } else {
            player.pauseForBackground()
            pitchDetector.stop()
            isPaused = true
        }
    }

    private func teardownAudio() {
        player.stop()
        pitchDetector.stop()
        AudioRouteManager.shared.deactivateSession()
    }

    // MARK: - Clap delay test

    /// Build the clap-test pattern in memory: one short metronome tick per beat,
    /// each with a "*clap*" label sitting just above it, so the existing playback
    /// screen renders the cue with no special drawing code.
    private func loadDelayTestNotes() {
        var ns: [MIDINote] = []
        var ts: [MIDIText] = []
        for i in 0..<totalClaps {
            ns.append(MIDINote(pitch: delayTestPitch, beat: Double(i), length: 0.1))
            ts.append(MIDIText(text: L("*clap*"), pitch: delayTestPitch + 3,
                               beat: midiTextBeat(centring: L("*clap*"), at: Double(i))))
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

        var savedTexts: [MIDIText] = []
        if let data = UserDefaults.standard.data(forKey: "miditext_\(exercise.id.uuidString)"),
           let decoded = try? JSONDecoder().decode([MIDIText].self, from: data) {
            savedTexts = decoded
        }

        // The same expansion the settings screen's preview draws from: every
        // repetition in its place, at its own tempo and transposition, moved to fit
        // the singer's vocal range.
        let timeline = exercise.timeline(pattern: saved, labels: savedTexts,
                                         vocalRange: VocalRange(rawValue: vocalRangeRaw))
        notes = timeline.notes
        texts = timeline.texts
        repeatLayout = timeline.repeats
        repetitionCenters = timeline.centers
        repetitionMaxExtent = timeline.maxExtent
    }
}

// MARK: - ScoreView

/// Shown after an exercise finishes: the score with a chart of this exercise's
/// past scores, plus buttons to replay the exercise or leave. Tinted from red
/// (low) through to green (high) so the result reads at a glance. In landscape
/// the score sits beside the chart instead of above it so everything stays on
/// screen.
private struct ScoreView: View {
    let score: Int
    let history: [ScoreEntry]
    var exitTitle = L("Exit")
    /// DEBUG RECORDING — remove together with DebugRecording.swift.
    /// The run's microphone capture, notes and pitch estimates, packaged for the
    /// share sheet. nil until the run has produced one.
    var debugRecording: DebugRunRecording? = nil
    /// When set (playing from the Community tab), a Download button appears above
    /// the Play Again/Exit row, copying the exercise into the user's own library.
    var onDownload: (() -> Void)? = nil
    /// When set, a "Next" button between Play Again and Exit opens the intro screen
    /// of the exercise listed below this one. nil (the last one in the list it was
    /// played from) leaves that row at two buttons.
    var onNext: (() -> Void)? = nil
    /// Opens the run just finished as a still picture of the exercise with the sung
    /// pitch line over it, to look at where the score came from.
    let onReview: () -> Void
    let onPlayAgain: () -> Void
    let onExit: () -> Void

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    /// Flips after a download so the button confirms instead of copying again.
    @State private var isDownloaded = false

    /// Red (low) through green (high). The bright end of that ramp was picked
    /// against a black screen and washes out on a light one, so light mode takes
    /// the same hue deeper — this is the biggest thing on the screen.
    private var tint: Color {
        let hue = Double(score) / 100.0 * 0.33
        return colorScheme == .dark
            ? Color(hue: hue, saturation: 0.85, brightness: 0.95)
            : Color(hue: hue, saturation: 0.95, brightness: 0.68)
    }

    private var scoreLabel: some View {
        VStack {
            Text("Score")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(verbatim: "\(score)%")
                .font(.system(size: 80, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
        }
    }

    private var chart: some View {
        ScoreHistoryChart(entries: history, tint: tint)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(swipeSpace)) } action: {
                chartFrame = $0
            }
    }

    /// Coordinate space the exit swipe and the chart's measured frame are both
    /// expressed in, so the one can be tested against the other.
    private let swipeSpace = "scoreSwipe"

    /// Where the chart ended up, so the exit swipe can leave drags that start on
    /// it alone. It has a range picker that is slid sideways and points that are
    /// tapped, and a gesture on the screen around it wins over both.
    @State private var chartFrame: CGRect = .zero

    /// Height of every button in the bottom row. Fixed rather than left to the
    /// labels' own padding, so a title that shrank to fit can't make its button
    /// shorter than the ones beside it — and it's the replay button's width too,
    /// which makes that one square.
    private let buttonHeight: CGFloat = 54

    /// One of the filled buttons along the bottom. The title shrinks rather than
    /// wraps, since a third button (Next) leaves each of them a narrow share of
    /// the row in the longer-worded languages.
    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: buttonHeight)
                .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
    }

    /// Opens the finished run for a closer look. Spelled out above the button row
    /// in portrait, where there's room for it to say what it does; landscape has no
    /// room for another full-width row, so there it joins the row as `reviewIcon`.
    private var reviewButton: some View {
        Button(action: onReview) {
            Label("Review", systemImage: "waveform.path.ecg")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.tint)
        }
    }

    private var reviewIcon: some View {
        Button(action: onReview) {
            Image(systemName: "waveform.path.ecg")
                .font(.headline)
                .frame(width: buttonHeight, height: buttonHeight)
                .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
        .accessibilityLabel(L("Review"))
    }

    /// How far a sideways drag has to travel before it counts as the exit swipe.
    private let exitSwipeDistance: CGFloat = 60

    /// A rightward flick on this screen leaves it, exactly as the Exit button does
    /// — so in a routine, where that button reads "Next", the swipe carries on to
    /// the following exercise rather than dropping out of the run. It stands in for
    /// the system's back gesture, which this screen turns off along with the back
    /// button so that leaving goes where Exit goes rather than popping the run.
    ///
    /// Only a clearly sideways drag counts, so a finger dragged down the screen
    /// can't end up leaving it, and one that starts on the chart is the chart's:
    /// this is attached around everything and would otherwise take the range
    /// picker's sideways drag off it.
    private var exitSwipe: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .named(swipeSpace))
            .onEnded { drag in
                guard !chartFrame.contains(drag.startLocation) else { return }
                let right = drag.translation.width
                guard right >= exitSwipeDistance, abs(drag.translation.height) < right else { return }
                onExit()
            }
    }

    /// Replay, as a square icon button: with three buttons in the row, spelling
    /// it out would squeeze the other two.
    private var playAgainButton: some View {
        Button(action: onPlayAgain) {
            Image(systemName: "arrow.counterclockwise")
                .font(.headline)
                .frame(width: buttonHeight, height: buttonHeight)
                .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
        .accessibilityLabel(L("Play Again"))
    }

    var body: some View {
        VStack(spacing: 16) {
            if verticalSizeClass == .compact {
                HStack(spacing: 24) {
                    scoreLabel
                    chart
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            } else {
                Spacer()
                scoreLabel
                chart
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                Spacer()
            }

            if verticalSizeClass != .compact {
                reviewButton
                    .padding(.horizontal, 40)
            }

            // DEBUG RECORDING — remove together with DebugRecording.swift.
            if let debugRecording, verticalSizeClass != .compact {
                DebugRecordingExportButton(recording: debugRecording)
                    .padding(.horizontal, 40)
            }

            if let onDownload {
                Button {
                    onDownload()
                    withAnimation { isDownloaded = true }
                } label: {
                    Label(isDownloaded ? L("Added to Exercises") : L("Download"),
                          systemImage: isDownloaded ? "checkmark" : "arrow.down.circle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.tint)
                }
                .disabled(isDownloaded)
                .padding(.horizontal, 40)
            }

            HStack(spacing: 12) {
                playAgainButton
                if verticalSizeClass == .compact {
                    reviewIcon
                }
                // DEBUG RECORDING — remove together with DebugRecording.swift.
                if let debugRecording, verticalSizeClass == .compact {
                    DebugRecordingExportButton(recording: debugRecording, compact: true)
                }
                if let onNext {
                    actionButton(L("Next"), action: onNext)
                }
                actionButton(exitTitle, action: onExit)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, verticalSizeClass == .compact ? 16 : 50)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Follows the app's theme rather than staying black behind a light UI —
        // the same surface the intro screen's chart card uses.
        .background(ScoreHistoryChart.surface(colorScheme).ignoresSafeArea())
        // Without a shape of its own the stack is only touchable where it has
        // drawn something, which would leave the swipe working over the score and
        // the buttons but not the space around them.
        .contentShape(Rectangle())
        .coordinateSpace(.named(swipeSpace))
        .gesture(exitSwipe)
        .navigationBarBackButtonHidden(true)
    }
}

// MARK: - DelayResultView

/// Shown at the end of either microphone-delay test: the delay in milliseconds —
/// measured from the claps, or dialled in on the review screen — which has already
/// replaced the saved microphone-delay setting, plus a button to leave.
private struct DelayResultView: View {
    let delayMs: Double
    let onExit: () -> Void

    var body: some View {
        VStack {
            Spacer()

            Text("Microphone Delay")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Text(L("%d ms", Int(delayMs)))
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
