import SwiftUI
import AVFoundation
import Combine
import os

// MARK: - Instrument timbre

// Every instrument is synthesised, so the same DSP renders identically on the
// simulator and on a real device — no external SoundFont/DLS file (which only
// ships on macOS) is involved. The sine and the voice are a fixed blend of
// harmonics under an envelope; the piano and the guitar are modelled as the
// strings they are, in StringSynth.swift.
private struct InstrumentSpec {
    let harmonics: [Double]   // relative amplitude of each overtone (1st = fundamental)
    let attack: Double        // seconds to full volume
    let decay: Double         // seconds from peak to sustain level
    let sustain: Double       // sustain level 0...1
    let release: Double       // seconds to fade after note-off
    let vibratoDepth: Double   // ± fraction of frequency
    let vibratoRate: Double    // Hz
    let gain: Double          // overall output level

    static let sine = InstrumentSpec(
        harmonics: [1.0],
        attack: 0.02, decay: 0.0, sustain: 1.0, release: 0.15,
        vibratoDepth: 0, vibratoRate: 0, gain: 0.30)

    // Vowel-like formant emphasis on the 2nd/3rd harmonic + gentle vibrato.
    static let voice = InstrumentSpec(
        harmonics: [0.7, 1.0, 0.85, 0.4, 0.25, 0.15, 0.08],
        attack: 0.06, decay: 0.08, sustain: 0.85, release: 0.22,
        vibratoDepth: 0.012, vibratoRate: 5.5, gain: 0.30)
}

private extension Instrument {
    /// The blend of harmonics this instrument is drawn from, or nil for the two
    /// drawn as strings (see `stringModel`).
    var spec: InstrumentSpec? {
        switch self {
        case .sine: .sine
        case .voice: .voice
        case .piano, .guitar: nil
        }
    }

    /// The string the piano and the guitar are modelled as; nil for the others.
    var stringModel: StringInstrument? {
        switch self {
        case .piano: .piano
        case .guitar: .guitar
        case .sine, .voice: nil
        }
    }
}

// MARK: - Audio engine (custom additive synthesiser)

final class ExercisePlayer {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!

    private static let renderRate: Double = 44100
    private let sampleRate = renderRate

    // Voice state — only touched on the audio thread except via the lock below.
    private struct Voice {
        var pitch: Int = -1
        var freq: Double = 0
        var phase: Double = 0
        var age: Double = 0          // seconds since note-on
        var released: Bool = false
        var releaseAge: Double = 0   // seconds since note-off
        var active: Bool = false
        var isString: Bool = false   // drawn by `strings` rather than from `spec`
    }
    private static let maxVoices = 24
    private var voices = [Voice](repeating: Voice(), count: maxVoices)
    /// The harmonics the sine and the voice are drawn from. Left as it was while a
    /// string instrument is picked, so a note still ringing from before carries on.
    private var spec = Instrument.current.spec ?? .sine
    /// The string the piano or the guitar is modelled as while one of them is
    /// picked; nil otherwise. A note keeps the string it was struck with.
    private var stringModel = Instrument.current.stringModel
    /// Every note the piano or the guitar is sounding, partials, envelopes and all.
    /// Built up front, so the render thread never allocates.
    private let strings = StringVoiceBank(voices: maxVoices, sampleRate: renderRate)
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

    // How far the audio may fall behind the on-screen clock before the schedule is
    // skipped forward to meet it. What this is here to catch is an audio stall: the
    // IO thread missing its deadlines — a system client restarting the shared
    // microphone device out from under the app is enough — leaves the output behind
    // the notes for the rest of the run, because the notes are drawn straight off
    // the wall clock and nothing else ever compares the two. The tolerance sits well
    // above the drift between the host clock and the audio device's own (tens of
    // ppm, single-digit milliseconds over a long run) and above a buffer's worth of
    // timestamp jitter, so only a real stall reaches it.
    private static let driftTolerance = 0.040
    /// Consecutive over-tolerance render passes before the catch-up runs, so one
    /// jittery timestamp can never move the schedule.
    private static let lateRendersBeforeCatchUp = 3
    private var lateRenders = 0
    /// The lateness the current streak of them agrees on.
    private var lateDrift: Double = 0

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
    /// Set while playback is deliberately paused (the toolbar button, backgrounding,
    /// an interruption). Keeps the configuration-change observer from starting the
    /// engine again behind the pause — an interruption raises both at once.
    private var isSuspended = false
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
            guard let self, self.shouldRun, !self.isSuspended, !self.engine.isRunning else { return }
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
        isSuspended = false
        refreshOutputLatency()
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    /// Stop rendering while the app is backgrounded. The playhead is preserved so the
    /// exercise resumes from the same spot; `shouldRun` stays set so the config-change
    /// observer and resume() can bring the engine back.
    func pauseForBackground() {
        isSuspended = true
        if engine.isRunning { engine.pause() }
    }

    /// Restart after returning from the background and re-anchor the on-screen clock
    /// to the audio's current playhead so the two don't drift apart by the time spent
    /// away. Safe to call only between begin() and stop().
    func resumeFromBackground() {
        guard shouldRun else { return }
        isSuspended = false
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
        // `hostTime` is when the first sample of this buffer (sample `playhead`) is
        // played, so the host time for sample 0 is that minus the playhead's duration.
        let playheadTicks = ticks(forSeconds: Double(playhead) / sampleRate)
        let bufferAnchor = hostTime > playheadTicks ? hostTime - playheadTicks : hostTime
        var catchUpSamples = 0
        if needsStartCapture {
            // At the initial start playhead == 0, so this is just hostTime; after a
            // background pause the playhead has advanced, and subtracting it re-anchors
            // the on-screen clock to the audio's real position — keeping visuals and
            // audio in sync no matter how long the app was away.
            startHostTime = bufferAnchor
            startCaptured = true
            needsStartCapture = false
            lateRenders = 0
        } else if startCaptured, bufferAnchor > startHostTime {
            // The anchor this buffer implies has slipped later than the one the screen
            // is drawn from, which means the audio stalled and never made the time up:
            // it is now playing behind the notes. Catch the schedule up rather than
            // moving the anchor, so the notes keep their own timing (and with it the
            // scoring the singer is measured against) and the accompaniment rejoins them.
            //
            // A stall leaves every buffer after it late by the same amount, so the
            // catch-up waits for a few in a row to agree on how late they are. A lone
            // odd timestamp — which would otherwise skip part of the exercise for no
            // reason — never gets there.
            let behind = seconds(forTicks: bufferAnchor - startHostTime)
            if behind > Self.driftTolerance,
               lateRenders == 0 || abs(behind - lateDrift) < Self.driftTolerance {
                lateRenders += 1
                lateDrift = behind
                if lateRenders >= Self.lateRendersBeforeCatchUp {
                    catchUpSamples = Int(behind * sampleRate)
                    lateRenders = 0
                }
            } else {
                lateRenders = 0
            }
        } else {
            lateRenders = 0
        }
        os_unfair_lock_unlock(&clockLock)
        if catchUpSamples > 0 { catchUpScheduleLocked(by: catchUpSamples) }
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
            var stringMix = 0.0
            for vi in 0..<voices.count where voices[vi].active {
                if voices[vi].isString {
                    // The piano and the guitar draw, shape and level their notes
                    // themselves; all the voice keeps here is its age, for stealing.
                    stringMix += strings.nextSample(vi)
                    voices[vi].age += dt
                    if strings.isFinished(vi) { voices[vi].active = false }
                    continue
                }
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

                v.phase += inc
                if v.phase > twoPi { v.phase -= twoPi }

                // Amplitude envelope.
                let base: Double
                if v.age < spec.attack {
                    base = v.age / spec.attack
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
                if env < 0.0004 && v.released {
                    v.active = false
                }
                voices[vi] = v
            }

            var out = mix * gain + stringMix

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

    /// Move the schedule forward by `samples` so the audio rejoins the on-screen
    /// clock after a stall. Runs on the render thread with `lock` already held.
    private func catchUpScheduleLocked(by samples: Int) {
        playhead += samples
        // Step over the events the jump passed rather than letting the render loop
        // fire them all at the same sample, which would strike every note in that
        // stretch as one chord.
        while eventIndex < events.count && events[eventIndex].sample <= playhead {
            eventIndex += 1
        }
        // Release whatever the jump left sounding so it fades instead of hanging on
        // past the note it belongs to; the next note-on starts a fresh voice.
        for i in 0..<voices.count where voices[i].active && !voices[i].released {
            voices[i].released = true
            voices[i].releaseAge = 0
            if voices[i].isString { strings.release(i) }
        }
        clickCursors.removeAll(keepingCapacity: true)
    }

    /// Host-clock ticks for a duration, and back. `timebase` is filled in once at
    /// init and never written again, so both are safe on the render thread.
    private func ticks(forSeconds seconds: Double) -> UInt64 {
        guard seconds > 0 else { return 0 }
        return UInt64(seconds * 1.0e9 * Double(timebase.denom) / Double(timebase.numer))
    }

    private func seconds(forTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1.0e9
    }

    // MARK: Note control (called from the render thread with the lock held)

    func setInstrument(_ instrument: Instrument) {
        os_unfair_lock_lock(&lock)
        stringModel = instrument.stringModel
        if let spec = instrument.spec { self.spec = spec }
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

        voices[i] = Voice(pitch: pitch, freq: freq, phase: 0, age: 0,
                          released: false, releaseAge: 0, active: true,
                          isString: stringModel != nil)
        if let stringModel { strings.start(i, pitch: pitch, instrument: stringModel) }
    }

    private func releaseVoiceLocked(pitch: Int) {
        for i in 0..<voices.count where voices[i].active && !voices[i].released && voices[i].pitch == pitch {
            voices[i].released = true
            voices[i].releaseAge = 0
            if voices[i].isString { strings.release(i) }
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
/// the singer's trailing pitch line lay within that note's drawn rectangle.
///
/// Each note is then marked against what it actually asks for, which is its length
/// less the time the voice needs to arrive on it from the note before (see
/// `PitchTravel`): cover that much and the note counts in full, cover half of it and
/// the note counts half. The score is those marks weighted by note length, so a note
/// still counts for as long as it lasts, and a run that was on pitch for every note's
/// full length still scores 100.
private final class Scorer {
    /// Beats each note was covered for, in the order the notes were handed to
    /// `update` — the same array all run long, and the one `score` marks against.
    private(set) var coveredBeats: [Double] = []
    private var lastBeat: Double? = nil
    /// The tolerance the frames were scored with, remembered because `rescored`
    /// needs it and only the draw pass — which works it out from the canvas height
    /// — is in a position to know it.
    private var tolerance: Double = 0

    func reset() {
        coveredBeats = []
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
        if coveredBeats.count != notes.count {
            coveredBeats = Array(repeating: 0, count: notes.count)
        }
        guard let last = lastBeat else { return }
        let dt = beat - last
        // Ignore non-advancing frames and large jumps (e.g. a restart) so the
        // integral can't be corrupted by a discontinuity in the playhead.
        guard dt > 0, dt < 0.5 else { return }
        guard let pitch = singerPitch else { return }
        for (i, note) in notes.enumerated()
        where beat >= note.beat + noteShift && beat < note.beat + note.length + noteShift {
            if abs(pitch - Double(note.pitch)) <= tolerance {
                coveredBeats[i] += dt
            }
        }
    }

    /// Final score as a whole-number percentage (0...100): every note marked against
    /// what it asks for, weighted by how long the note is.
    func score(notes: [MIDINote], bpm: Double) -> Int {
        let total = notes.reduce(0.0) { $0 + max(0, $1.length) }
        guard total > 0 else { return 0 }
        let required = PitchTravel.requiredBeats(notes: notes, bpm: bpm)
        var earned = 0.0
        for (i, note) in notes.enumerated() {
            let covered = i < coveredBeats.count ? coveredBeats[i] : 0
            // A note that asks for nothing is one shorter than the travel that reaches
            // it: there is no length of it a singer could hold, so it goes all or
            // nothing on whether they got to it at all.
            let hit = required[i] > 0 ? min(1, covered / required[i]) : (covered > 0 ? 1 : 0)
            earned += max(0, note.length) * hit
        }
        return min(100, max(0, Int((earned / total * 100).rounded())))
    }

    /// The run just scored, scored again at a different microphone delay.
    ///
    /// `samples` is the pitch line the run recorded, which is the very `(beat,
    /// pitch)` pair `update` was handed on each frame, in order — so replaying it
    /// through a fresh scorer at `noteShift` gives exactly what the run would have
    /// scored had the setting been that all along.
    func rescored(samples: [PitchSample], notes: [MIDINote], noteShift: Double, bpm: Double) -> Int {
        let replay = Scorer()
        for sample in samples {
            replay.update(beat: sample.beat, notes: notes, singerPitch: sample.pitch,
                          tolerance: tolerance, noteShift: noteShift)
        }
        return replay.score(notes: notes, bpm: bpm)
    }

    /// The microphone delay this run would have scored highest at, in whole
    /// milliseconds, searching every delay from none up to `maxMs`. nil when there is
    /// nothing to search — no notes, no singing, or no room above zero.
    ///
    /// Rescoring the run once per candidate would be the obvious way to do it and far
    /// too slow: a two-minute run at 120 Hz leaves 14,000 samples, and two thousand
    /// replays over a hundred notes is hundreds of millions of comparisons in the
    /// moment the singer is waiting for their score. This costs one pass instead,
    /// because a sample doesn't need scoring at every delay to say which delays it
    /// counts at. A sample is inside a note exactly while the shifted note is still
    /// sounding under it, which is one contiguous run of candidate delays, so each
    /// (note, sample) pair is added once at the delay that run starts and taken away
    /// again where it ends. Running totals down the array then give what every note
    /// was covered for at every delay at once.
    ///
    /// The score at a candidate is marked exactly as `score` marks it, so the answer
    /// is the same one rescoring would have given, and the caller rescores at the
    /// delay this returns to get the number it shows.
    func bestDelayMs(samples: [PitchSample], notes: [MIDINote], bpm: Double,
                     upTo maxMs: Double) -> Double? {
        let steps = Int(maxMs.rounded(.down))          // one candidate per millisecond
        guard steps > 0, !notes.isEmpty, bpm > 0 else { return nil }
        let total = notes.reduce(0.0) { $0 + max(0, $1.length) }
        guard total > 0 else { return nil }
        let beatsPerMs = micDelayBeats(1, bpm: bpm)

        // The samples that count towards a score, with the slice of time each one
        // stands for: the same `dt` and the same guards on it as `update`, which
        // measures the gap back to the previous sample whether or not that one had a
        // pitch of its own.
        var heard: [(beat: Double, pitch: Double, dt: Double)] = []
        heard.reserveCapacity(samples.count)
        var previousBeat: Double? = nil
        for sample in samples {
            defer { previousBeat = sample.beat }
            guard let previous = previousBeat, let pitch = sample.pitch else { continue }
            let dt = sample.beat - previous
            guard dt > 0, dt < 0.5 else { continue }
            heard.append((beat: sample.beat, pitch: pitch, dt: dt))
        }
        guard !heard.isEmpty else { return nil }

        let required = PitchTravel.requiredBeats(notes: notes, bpm: bpm)
        // What the whole run has earned at each candidate delay, built up a note at a
        // time, and the note being worked on: how its coverage changes from one
        // candidate to the next.
        var earned = [Double](repeating: 0, count: steps + 1)
        var change = [Double](repeating: 0, count: steps + 2)

        for (i, note) in notes.enumerated() {
            let length = max(0, note.length)
            guard length > 0 else { continue }         // weightless: nothing to earn
            for index in change.indices { change[index] = 0 }

            for sample in heard where abs(sample.pitch - Double(note.pitch)) <= tolerance {
                // Shifted by `d` beats the note sounds over [beat + d, beat + length + d),
                // so this sample is inside it for every delay from just above
                // `sampleBeat - noteEnd` up to and including `sampleBeat - noteBeat`.
                let highest = (sample.beat - note.beat) / beatsPerMs
                let lowest = (sample.beat - note.beat - length) / beatsPerMs
                guard highest >= 0, lowest < Double(steps) else { continue }
                let last = min(steps, Int(highest.rounded(.down)))
                let first = max(0, Int(lowest.rounded(.down)) + 1)
                guard first <= last else { continue }
                change[first] += sample.dt
                change[last + 1] -= sample.dt
            }

            var covered = 0.0
            for ms in 0...steps {
                covered += change[ms]
                // Marked as `score` marks it, including the all-or-nothing case for a
                // note that asks for nothing. The tolerance there is what is left of a
                // sample after it has been added and taken away again.
                let hit = required[i] > 0
                    ? min(1, max(0, covered) / required[i])
                    : (covered > 1e-9 ? 1 : 0)
                earned[ms] += length * hit
            }
        }

        // The lowest delay that earns the most: a stretch of equally good offsets means
        // the singer was inside the notes throughout it, and the near end of that
        // stretch is the one that doesn't push the last note off the end of the run.
        var best = 0
        for ms in 1...steps where earned[ms] > earned[best] { best = ms }
        return Double(best)
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
    /// Set alongside it when that score beat every earlier one for this exercise,
    /// which the score screen says out loud. Worked out in `finishRun`, before the
    /// run joins the history it is measured against.
    @State private var isPersonalRecord = false
    /// Set while the score screen's Review button has the finished run's notes and
    /// pitch line open in place of the score.
    @State private var isReviewing = false
    /// Set when a run has played out and the microphone delay is what comes next:
    /// the same review screen takes over from playback, with the controls that dial
    /// the delay in. That is the whole point of the sung delay test, and nothing else
    /// reaches it.
    @State private var isCalibrating = false
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
    /// How much of a note counts as hit, read here so the draw pass — which is where
    /// the score is integrated — picks a change up without going back to UserDefaults
    /// on every frame.
    @AppStorage(ScoreTargetWindow.storageKey) private var scoreTargetWindow = ScoreTargetWindow.defaultPercent
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

    /// Whether what is on screen is one of the full-screen drawings of the
    /// exercise: the run itself, or the review screen in either of its jobs —
    /// looking back over a finished run, and dialling the microphone delay in on
    /// one. The score and delay-result screens are the two that are not. Mirrors
    /// the branches of `body`, in the same order.
    private var showsRunCanvas: Bool {
        if delayResultMs != nil { return false }
        if isCalibrating { return true }
        if finalScore != nil { return isReviewing }
        return true
    }

    var body: some View {
        Group {
            if let delayResultMs {
                DelayResultView(delayMs: delayResultMs) {
                    if let onDelayTestExit { onDelayTestExit() } else { dismiss() }
                }
            } else if isCalibrating {
                // The sung delay test's last step: the finished run drawn as usual,
                // with controls that slide the sung line over the notes. Done saves
                // what was dialled in and shows it; the back button leaves without it.
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
                              isPersonalRecord: isPersonalRecord,
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
        // Hidden for as long as the exercise is drawn across the whole screen —
        // the run and the review — and back on the score screen the run ends on,
        // which is an ordinary screen of buttons and has the room for it.
        //
        // Attached out here rather than inside the branches so there is one
        // toolbar modifier that stays put across them, rather than one appearing
        // as another goes and the bar animating on whichever wins.
        .toolbar(visuals.hideTabBar && showsRunCanvas ? .hidden : .automatic, for: .tabBar)
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
                    .explain(L("Pauses the exercise. Tap again to carry on from where you stopped."))
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
            // The allowlist is checked here rather than at the button: an install
            // that isn't on it never arms the recorder, so it does none of the
            // capture work either, and `debugRecording` stays nil - which is what
            // keeps the export button off its score screen.
            if mode == .normal, DebugRecordingAccess.isAllowed {
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
                    // The run played through to the end, which is the only kind of run
                    // the delay can be recognised from: one walked out of half way
                    // never gets here, and its part-sung line would put the best offset
                    // anywhere.
                    let score = recogniseDelay(scoring: scorer.score(notes: notes, bpm: bpm))
                    // DEBUG RECORDING — remove together with DebugRecording.swift.
                    // After teardownAudio, so no more microphone hops can arrive.
                    debugRecording = debugRecorder.finish(
                        DebugRunContext(exercise: exercise, notes: notes, texts: texts,
                                        samples: trail.recording, bpm: bpm, leadInBeats: leadIn,
                                        repeatSpan: repeatLayout.span, micDelayMs: micDelayMs,
                                        score: score))
                    // It counts for the Home tab's "Recent" category regardless of the
                    // score — and for its full length on the Home tab's calendar, which
                    // a run walked out of before this point never reaches. It is a
                    // finished exercise for the exercise list's one-off hint too.
                    store.markPlayed(exercise.id)
                    PracticeLog.record(seconds: runDuration)
                    CategoryHint.recordFinishedExercise()
                    finishRun(score: score)
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
        // A call, Siri, or another app taking the microphone stops both engines
        // behind the app's back, and `.began` is the only warning it gets.
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            pauseForInterruption()
        }
    }

    // MARK: - Finishing a run

    /// Everything a finished run leaves behind that depends on its score, and the
    /// score screen it ends on. The score handed in is the one the delay recognition
    /// settled on (see `recogniseDelay`), so what the singer is shown — and what goes
    /// into the history and up to the server — is all the same number.
    private func finishRun(score: Int) {
        // Asked before saving: once this run is in the history, it ties with
        // itself and nothing is ever a record.
        isPersonalRecord = ScoreHistory.isPersonalRecord(score: score, for: exercise.id)
        // Save before showing the result so the chart includes this run.
        ScoreHistory.record(score: score, for: exercise.id)
        // Count the run for everyone: the score goes up to the server with the play,
        // which averages it into the difficulty the intro screen's stars show. Only a
        // run that reached a score is worth posting, so this is the one place it
        // happens — a replay comes back through here with its own score. A 0% run
        // stays off the server, as it stays out of the history (see `registerPlay`).
        CommunitySync.shared.registerPlay(
            for: communityID ?? PublicIdentifier.exercise(exercise.id), score: score)
        finalScore = score
    }

    /// Works the microphone delay out from the run that has just played and adopts it,
    /// returning the score the singer is shown: the one at the delay this leaves set.
    /// `played` is what the run scored at the delay it was actually played under, and
    /// is what comes back whenever nothing is adopted.
    ///
    /// The delay is only moved when the run says something about the microphone worth
    /// hearing. That means a score above `AutoMicDelay.minimumScore` at the offset
    /// found, except while no run has ever cleared that bar with this switch on: a
    /// singer whose delay is badly wrong cannot score well until it is roughly right,
    /// so the first runs take the best offset going and the bar takes over once there
    /// is a delay worth keeping.
    private func recogniseDelay(scoring played: Int) -> Int {
        guard AutoMicDelay.isEnabled else { return played }
        guard let best = scorer.bestDelayMs(
            samples: trail.recording, notes: notes, bpm: bpm,
            upTo: AutoMicDelay.maxDelayMs(notes: notes, samples: trail.recording, bpm: bpm))
        else { return played }

        let found = scorer.rescored(samples: trail.recording, notes: notes,
                                    noteShift: micDelayBeats(best, bpm: bpm), bpm: bpm)
        // `found` beats `played` on any run whose delay was inside the range searched,
        // which is all of them bar a delay set higher than the last note leaves room
        // for; that one keeps the score it was played at.
        let adopt = found >= played
            && (found > AutoMicDelay.minimumScore || !AutoMicDelay.isEstablished)
        if adopt { micDelayMs = best }
        let score = adopt ? found : played
        if score > AutoMicDelay.minimumScore { AutoMicDelay.markEstablished() }
        return score
    }

    /// Done on the sung delay test's last screen: the offset the singer dialled in
    /// becomes the microphone-delay setting, and the test ends on the same result
    /// screen the clap test does. Measuring that number was the whole errand, so there
    /// is no score behind it.
    private func calibrationDone(_ ms: Double) {
        let delay = ms.rounded()
        micDelayMs = delay
        delayResultMs = delay
    }

    /// Its back button, which abandons the test. Nothing was scored and nothing was
    /// saved, and there is no screen behind it to go back to.
    private func calibrationSkipped() {
        dismiss()
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
        //
        // The target-window setting shrinks the note towards its middle for this
        // comparison alone — the note is still drawn full height — so at 40% only the
        // middle 40% of it counts. The pitch line's own 1.25pt reach is added on top
        // either way: what counts is the drawn line *touching* the window, which at
        // 100% leaves the reach exactly as it always was.
        let targetHalfHeight = (baseRowH - 2) / 2 * CGFloat(ScoreTargetWindow.fraction(percent: scoreTargetWindow))
        let lineToleranceSemitones = Double((targetHalfHeight + 1.25) / baseRowH)
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

    /// Pause the run when the system interrupts the audio session. iOS deactivates
    /// the session and stops both engines without asking, so without this the notes
    /// would carry on scrolling against silence and everything that passed during
    /// the interruption would be scored as unsung. Picking the run back up is left
    /// to the singer: the toolbar's play button reconfigures the session and resumes
    /// from where it stopped, the same as any other pause.
    private func pauseForInterruption() {
        guard finalScore == nil, delayResultMs == nil, !isCalibrating, !isPaused else { return }
        player.pauseForBackground()
        pitchDetector.stop()
        isPaused = true
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
    /// True when this run beat every earlier score for the exercise, which the
    /// screen says between the score and the chart. Worked out before the run was
    /// recorded, so `history` — which already includes it — can't be used for it.
    let isPersonalRecord: Bool
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
    /// the same hue deeper — the score is the biggest thing on the screen.
    private func rampColor(_ percent: Int) -> Color {
        let hue = Double(percent) / 100.0 * 0.33
        return colorScheme == .dark
            ? Color(hue: hue, saturation: 0.85, brightness: 0.95)
            : Color(hue: hue, saturation: 0.95, brightness: 0.68)
    }

    /// Where this run's score sits on that ramp: the colour of the number itself
    /// and of the line the chart draws.
    private var tint: Color { rampColor(score) }

    /// The good news, said in the green end of that same ramp rather than a green
    /// of its own — a personal record at 60% is still a record, and the two
    /// colours on the screen then belong to one another.
    private var personalRecordLabel: some View {
        Text("Personal Record!")
            .font(.title3.weight(.bold))
            .foregroundStyle(rampColor(100))
            .explain(L("Your highest score on this exercise so far. This run beat your previous best."))
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
        .explain(L("How much of the run you sang on pitch. Red is low, green is high."))
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

    /// A `.headline` line at whatever size the reader has text set to, which is
    /// all `buttonHeight` needs from the type system to come out at the intro
    /// screen's Start button's height at any of them.
    @ScaledMetric(relativeTo: .headline) private var headlineLine: CGFloat = 20.33

    /// Height of every button in the bottom row: a headline line inside the same
    /// default 16pt padding the intro screen's Start button is built from, so the
    /// two rows are exactly the same size as well as at the same height, and
    /// starting the exercise again doesn't shift the button under the finger.
    /// Spelled out rather than left to the labels' own padding, so a title that
    /// shrank to fit can't make its button shorter than the ones beside it — and
    /// it's the replay button's width too, which makes that one square.
    private var buttonHeight: CGFloat { headlineLine + 32 }

    /// One of the filled buttons along the bottom. The title shrinks rather than
    /// wraps, since a third button (Next) leaves each of them a narrow share of
    /// the row in the longer-worded languages.
    private func actionButton(_ title: String, help: String,
                              action: @escaping () -> Void) -> some View {
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
        .explain(help)
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
        .explain(reviewHelp)
    }

    /// What the Review button does, said the same way in both of its shapes.
    /// Computed, not stored: a stored one would hold whatever language it was
    /// first read in.
    private var reviewHelp: String {
        L("Opens the run you just sang as a still picture: your pitch drawn over the notes, so you can see where it went.")
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
        .explain(reviewHelp)
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
        .explain(L("Sings this exercise again from the beginning."))
    }

    var body: some View {
        VStack(spacing: 16) {
            if verticalSizeClass == .compact {
                HStack(spacing: 24) {
                    // Landscape has no room for a row of its own, so the record
                    // line goes under the score, still between it and the chart.
                    VStack(spacing: 8) {
                        scoreLabel
                        if isPersonalRecord { personalRecordLabel }
                    }
                    chart
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
            } else {
                Spacer()
                scoreLabel
                if isPersonalRecord { personalRecordLabel }
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
                .explain(L("Copies this exercise into your own library, where you can change it and keep your scores for it."))
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
                    actionButton(L("Next"),
                                 help: L("Opens the exercise listed after this one."),
                                 action: onNext)
                }
                actionButton(exitTitle,
                             help: L("Finishes with this exercise. Flicking right across the screen does the same."),
                             action: onExit)
            }
            .padding(.horizontal, 40)
            // The plain default padding the intro screen's Start button sits on,
            // rather than a number of its own: with `buttonHeight` matching that
            // button too, the row lands in exactly the place it was tapped from.
            .padding(.bottom)
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
                .explain(L("How long your microphone takes to hear you. Your scores are worked out with this taken off, and you can change it in Settings under Audio."))

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
