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
    private var workItems: [DispatchWorkItem] = []

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

    init() {
        // playAndRecord (rather than .playback) so the mic-based pitch detector can
        // run alongside playback; .defaultToSpeaker keeps output on the speaker.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default,
                                                         options: [.defaultToSpeaker, .mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, ablPointer -> OSStatus in
            self?.render(frameCount: Int(frameCount), abl: ablPointer)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    // MARK: Real-time render

    private func render(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let twoPi = 2.0 * Double.pi
        let dt = 1.0 / sampleRate

        os_unfair_lock_lock(&lock)
        let spec = self.spec
        let harmonics = spec.harmonics
        let invHarm = 1.0 / harmonics.reduce(0, +)
        let gain = spec.gain

        for frame in 0..<frameCount {
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

            let sample = Float(tanh(mix * gain))   // soft-clip the polyphonic sum
            for buffer in buffers {
                let ptr = buffer.mData!.assumingMemoryBound(to: Float.self)
                ptr[frame] = sample
            }
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Note control

    func setInstrument(_ instrument: Instrument) {
        os_unfair_lock_lock(&lock)
        spec = instrument.spec
        os_unfair_lock_unlock(&lock)
    }

    private func noteOn(_ pitch: Int) {
        let freq = 440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
        os_unfair_lock_lock(&lock)
        // Reuse a free voice, else steal the oldest one.
        var idx = voices.firstIndex { !$0.active }
        if idx == nil {
            idx = (0..<voices.count).max { voices[$0].age < voices[$1].age }
        }
        if let i = idx {
            voices[i] = Voice(pitch: pitch, freq: freq, phase: 0, age: 0,
                              released: false, releaseAge: 0, active: true)
        }
        os_unfair_lock_unlock(&lock)
    }

    private func noteOff(_ pitch: Int) {
        os_unfair_lock_lock(&lock)
        for i in 0..<voices.count where voices[i].active && !voices[i].released && voices[i].pitch == pitch {
            voices[i].released = true
            voices[i].releaseAge = 0
        }
        os_unfair_lock_unlock(&lock)
    }

    private func allNotesOff() {
        os_unfair_lock_lock(&lock)
        for i in 0..<voices.count { voices[i].active = false }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: Scheduling

    func schedule(notes: [MIDINote], bpm: Double, leadIn: Double, onFinish: @escaping () -> Void) {
        cancelAll()
        let secPerBeat = 60.0 / bpm

        for note in notes {
            let pitch    = note.pitch
            let onDelay  = (note.beat + leadIn) * secPerBeat
            let offDelay = (note.beat + note.length + leadIn) * secPerBeat

            let onItem  = DispatchWorkItem { [weak self] in self?.noteOn(pitch) }
            let offItem = DispatchWorkItem { [weak self] in self?.noteOff(pitch) }
            workItems += [onItem, offItem]
            DispatchQueue.main.asyncAfter(deadline: .now() + onDelay,  execute: onItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + offDelay, execute: offItem)
        }

        let lastBeat    = notes.map { $0.beat + $0.length }.max() ?? 0
        let finishDelay = (lastBeat + leadIn + 1.0) * secPerBeat
        let finishItem  = DispatchWorkItem { onFinish() }
        workItems.append(finishItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + finishDelay, execute: finishItem)
    }

    func cancelAll() {
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        allNotesOff()
    }

    deinit {
        cancelAll()
        engine.stop()
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

struct PlaybackView: View {
    let exercise: Exercise

    @State private var player = ExercisePlayer()
    @StateObject private var pitchDetector = PitchDetector()
    @State private var indicator = SingerIndicator()
    @State private var notes: [MIDINote] = []
    @State private var startDate: Date? = nil
    @Environment(\.dismiss) private var dismiss

    private let leadIn: Double = 2       // silent beats before first note
    private let pianoW: CGFloat = 38
    private let beatPx: CGFloat = 80     // pixels per beat in playback view

    private var bpm: Double { 120.0 * (exercise.speed / 100.0) }

    var body: some View {
        TimelineView(.animation) { tl in
            let beat: Double = {
                guard let s = startDate else { return -leadIn }
                return tl.date.timeIntervalSince(s) * (bpm / 60.0) - leadIn
            }()

            // Ease the indicator toward the latest estimate every frame.
            let singerPitch = indicator.step(target: pitchDetector.midiPitch, factor: 0.3)

            Canvas { ctx, size in
                drawScene(ctx: ctx, size: size, beat: beat, singerPitch: singerPitch)
            }
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadNotes()
            player.setInstrument(Instrument.current)
            startDate = Date()
            player.schedule(notes: notes, bpm: bpm, leadIn: leadIn) {
                dismiss()
            }
            pitchDetector.start()
        }
        .onDisappear {
            player.cancelAll()
            pitchDetector.stop()
        }
    }

    // MARK: - Drawing

    private func drawScene(ctx: GraphicsContext, size: CGSize, beat: Double, singerPitch: Double?) {
        let rows    = hiPitch - loPitch + 1
        let rowH    = size.height / CGFloat(rows)
        let phX     = size.width / 3       // playhead at 1/3 from the left

        let activePitches = Set(
            notes.filter { beat >= $0.beat && beat < $0.beat + $0.length }.map { $0.pitch }
        )

        // ── Piano key column ────────────────────────────────────────────
        for row in 0..<rows {
            let pitch = hiPitch - row
            let y = CGFloat(row) * rowH
            let active = activePitches.contains(pitch)
            let bg: Color = active ? .yellow : (isBlack(pitch) ? Color(white: 0.07) : Color(white: 0.82))
            ctx.fill(Path(CGRect(x: 0, y: y, width: pianoW - 1, height: rowH)), with: .color(bg))
        }

        var colBorder = Path()
        colBorder.move(to: CGPoint(x: pianoW - 0.5, y: 0))
        colBorder.addLine(to: CGPoint(x: pianoW - 0.5, y: size.height))
        ctx.stroke(colBorder, with: .color(.gray.opacity(0.4)), lineWidth: 1)

        // ── Note area row backgrounds ────────────────────────────────────
        for row in 0..<rows {
            let pitch = hiPitch - row
            let y = CGFloat(row) * rowH
            ctx.fill(
                Path(CGRect(x: pianoW, y: y, width: size.width - pianoW, height: rowH)),
                with: .color(isBlack(pitch) ? Color(white: 0.08) : Color(white: 0.14))
            )
        }

        // Horizontal separators
        var hLines = Path()
        for row in 0...rows {
            let y = CGFloat(row) * rowH
            hLines.move(to: CGPoint(x: pianoW, y: y))
            hLines.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(hLines, with: .color(white: 0.2), lineWidth: 0.5)

        // ── Notes ────────────────────────────────────────────────────────
        for note in notes {
            let noteX = phX + CGFloat(note.beat - beat) * beatPx
            let noteW = CGFloat(note.length) * beatPx

            let leftEdge  = max(noteX, pianoW)
            let rightEdge = min(noteX + noteW, size.width)
            guard rightEdge > leftEdge else { continue }

            let row  = hiPitch - note.pitch
            let y    = CGFloat(row) * rowH + 1
            let rect = CGRect(x: leftEdge, y: y, width: rightEdge - leftEdge - 1, height: rowH - 2)
            let path = Path(roundedRect: rect, cornerRadius: 2)

            let isActive = activePitches.contains(note.pitch) && beat >= note.beat
            if isActive {
                ctx.fill(path, with: .color(.white))
                ctx.stroke(path, with: .color(.yellow), lineWidth: 1.5)
            } else {
                ctx.fill(path, with: .color(.green.opacity(0.85)))
                ctx.stroke(path, with: .color(.green), lineWidth: 1)
            }
        }

        // ── Playhead ─────────────────────────────────────────────────────
        var glow = Path()
        glow.move(to: CGPoint(x: phX, y: 0))
        glow.addLine(to: CGPoint(x: phX, y: size.height))
        ctx.stroke(glow, with: .color(.white.opacity(0.12)), lineWidth: 10)

        var line = Path()
        line.move(to: CGPoint(x: phX, y: 0))
        line.addLine(to: CGPoint(x: phX, y: size.height))
        ctx.stroke(line, with: .color(.white), lineWidth: 2)

        // ── Singer's current pitch (from the microphone) ─────────────────────
        if let pitch = singerPitch {
            // Centre of the row for this (fractional) MIDI pitch, clamped to view.
            let rowFloat = Double(hiPitch) - pitch
            var y = (CGFloat(rowFloat) + 0.5) * rowH
            let r: CGFloat = min(rowH * 0.85, 11)
            y = min(max(y, r), size.height - r)

            let dot = Path(ellipseIn: CGRect(x: phX - r, y: y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(.cyan))
            ctx.stroke(dot, with: .color(.white), lineWidth: 1.5)
        }
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
            for note in saved {
                var n = note
                n.id = UUID()
                n.pitch += exercise.pitchShift + rep * exercise.transposePerRepeat
                n.beat += Double(rep) * repeatSpan
                expanded.append(n)
            }
        }
        notes = expanded
    }
}
