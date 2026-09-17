import Foundation

/// Deterministic RNG
struct LCG {
    var s: UInt64
    mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double { let u = max(1e-12, next()), v = next(); return sqrt(-2 * log(u)) * cos(2 * .pi * v) }
}

struct SynthConfig {
    var name: String
    var lowMidi: Int
    var highMidi: Int
    var hnrDb: Double = 30          // harmonic-to-noise
    var snrDb: Double = 60          // background noise
    var weakFundamental = false
    var vibrato = 0.3               // semitones
    var legato = false              // glide between notes without gaps
    var vowelScale = 1.0            // formant shift (1.15 for high voices)
    var seed: UInt64 = 1
    var consonants = true
    var bleed = 0.0                 // instrument playing the target note (relative level)
}

/// Returns (samples, truth frames at `step`) where truth pitch is nil when not clearly voiced.
func synthesize(_ cfg: SynthConfig, sampleRate sr: Double, seconds: Double, step: Int) -> ([Float], [RefFrame]) {
    var rng = LCG(s: cfg.seed &* 7919 &+ 17)
    let n = Int(seconds * sr)
    var out = [Float](repeating: 0, count: n)
    var f0Track = [Double](repeating: .nan, count: n)
    var env = [Double](repeating: 0, count: n)
    var truthVoiced = [Bool](repeating: false, count: n)

    // Note plan
    struct PNote { var start: Int; var end: Int; var midi: Double; var level: Double; var vowel: Int; var consonant: Int }
    var notes: [PNote] = []
    var t = Int(0.3 * sr)
    var prev = Double((cfg.lowMidi + cfg.highMidi) / 2)
    while t < n - Int(0.5 * sr) {
        let dur = Int((0.18 + rng.next() * 0.5) * sr)
        var m: Double
        let r = rng.next()
        let range = Double(cfg.highMidi - cfg.lowMidi)
        if r < 0.15 { m = prev + (rng.next() < 0.5 ? 12 : -12) }                // octave leap
        else if r < 0.5 { m = prev + Double(Int(rng.next() * 5) - 2) }           // step
        else if r < 0.75 { m = prev + Double(Int(rng.next() * 9) - 4) }          // skip
        else { m = Double(cfg.lowMidi) + rng.next() * range }
        m = m.rounded()
        if m < Double(cfg.lowMidi) { m += 12 }
        if m > Double(cfg.highMidi) { m -= 12 }
        m = min(Double(cfg.highMidi), max(Double(cfg.lowMidi), m))
        m += (rng.next() - 0.5) * 0.4                                             // singer slightly off
        let consonant = cfg.consonants ? Int(rng.next() * 3) : 0                 // 0 none, 1 plosive, 2 nasal
        notes.append(PNote(start: t, end: t + dur, midi: m, level: 0.04 + rng.next() * 0.2, vowel: Int(rng.next() * 4), consonant: consonant))
        prev = m
        let gap = cfg.legato && rng.next() < 0.7 ? 0 : Int((0.05 + rng.next() * 0.25) * sr)
        t += dur + gap
    }

    // Formants (Hz, bandwidth)
    let vowels: [[(Double, Double, Double)]] = [
        [(700, 110, 1.0), (1220, 120, 0.5), (2600, 160, 0.25)],   // a
        [(300, 60, 1.0), (2300, 150, 0.3), (3000, 200, 0.2)],     // i
        [(320, 70, 1.0), (870, 100, 0.35), (2240, 150, 0.1)],     // u
        [(500, 80, 1.0), (900, 100, 0.5), (2400, 160, 0.15)],     // o
    ]
    func formantGain(_ f: Double, _ v: Int) -> Double {
        var g = 0.02
        for (fc0, bw, a) in vowels[v] {
            let fc = fc0 * cfg.vowelScale
            let x = (f - fc) / bw
            g += a / (1 + x * x)
        }
        // mic roll-off below ~120 Hz
        let hp = (f / 120) * (f / 120)
        return g * hp / (1 + hp)
    }

    var phases = [Double](repeating: 0, count: 64)
    var jitter = 0.0
    var vibPhase = 0.0
    // noise filter state
    var nz1 = 0.0, nz2 = 0.0
    var ni = 0
    for (idx, note) in notes.enumerated() {
        let prevNote = idx > 0 ? notes[idx - 1] : nil
        let attack = Int(0.03 * sr), release = Int(0.05 * sr)
        let glide = Int(0.06 * sr)
        let isLegato = prevNote.map { $0.end == note.start } ?? false
        let consLen = note.consonant == 2 ? Int(0.07 * sr) : (note.consonant == 1 ? Int(0.02 * sr) : 0)
        for i in note.start..<min(n, note.end + release) {
            let k = i - note.start
            // f0 contour
            var m = note.midi
            if isLegato, let pn = prevNote, k < glide {
                let a = Double(k) / Double(glide)
                m = pn.midi + (note.midi - pn.midi) * (0.5 - 0.5 * cos(.pi * a))
            } else if k < glide {
                m -= 0.6 * (1 - Double(k) / Double(glide))   // scoop into the note
            }
            if k > Int(0.25 * sr) { m += cfg.vibrato * sin(vibPhase) }
            vibPhase += 2 * .pi * 5.5 / sr
            jitter = jitter * 0.999 + rng.gauss() * 0.0015
            m += jitter
            let f0 = hz(m)
            // envelope
            var e = note.level
            if !isLegato && k < attack { e *= Double(k) / Double(attack) }
            if i >= note.end { e *= max(0, 1 - Double(i - note.end) / Double(release)) }
            let nasal = note.consonant == 2 && k < consLen
            if note.consonant == 1 && k < consLen { e *= 0.0 }   // plosive closure
            // harmonics
            var v = 0.0
            let vowel = note.vowel
            let shimmer = 1 + rng.gauss() * 0.02
            for h in 1..<64 {
                let fh = f0 * Double(h)
                if fh > min(5000, sr * 0.45) { break }
                phases[h] += 2 * .pi * fh / sr
                if phases[h] > 2 * .pi { phases[h] -= 2 * .pi }
                var a = pow(Double(h), -1.1)
                if nasal { a *= fh < 400 ? 1.0 : 0.05 }
                else { a *= formantGain(fh, vowel) }
                if cfg.weakFundamental && h == 1 { a *= 0.12 }
                v += a * sin(phases[h])
            }
            v *= e * shimmer * 3
            // aspiration noise at HNR
            let noiseAmp = e * 3 * 0.3 * pow(10, -cfg.hnrDb / 20)
            var w = rng.gauss()
            if note.consonant == 1 && k >= consLen && k < consLen + Int(0.015 * sr) { w *= 8 }  // burst
            nz1 += 0.3 * (w - nz1); nz2 = w - nz1  // crude high-pass
            v += noiseAmp * nz2 * (note.consonant == 1 && k >= consLen && k < consLen + Int(0.015 * sr) ? 3 : 1)
            out[i] += Float(v)
            env[i] = max(env[i], e / note.level)
            let clearlyVoiced = !(note.consonant == 1 && k < consLen + Int(0.015 * sr)) && (e / note.level) > 0.5 && i < note.end
            if clearlyVoiced { truthVoiced[i] = true; f0Track[i] = m }
            ni += 1
        }
        // instrument bleed: plucked tone at the rounded target
        if cfg.bleed > 0 {
            let fb = hz(note.midi.rounded())
            for i in note.start..<min(n, note.start + Int(1.0 * sr)) {
                let k = Double(i - note.start) / sr
                var v = 0.0
                for h in 1...8 { v += pow(Double(h), -1.5) * sin(2 * .pi * fb * Double(h) * k) * exp(-k * (2 + Double(h))) }
                out[i] += Float(v * cfg.bleed * 0.1)
            }
        }
    }
    // background noise
    let bgAmp = 0.1 * pow(10, -cfg.snrDb / 20)
    var b0 = 0.0, b1 = 0.0
    for i in 0..<n {
        let w = rng.gauss()
        b0 = 0.99 * b0 + w * 0.1; b1 = 0.6 * b1 + w * 0.4
        out[i] += Float(bgAmp * (b0 + b1 + w * 0.2))
    }
    // truth frames
    var frames: [RefFrame] = []
    var k = 0
    while (k + 1) * step <= n {
        let c = k * step + step / 2
        let p: Double? = truthVoiced[c] ? f0Track[c] : nil
        frames.append(RefFrame(pitch: p, aperiodicity: 0, rms: 0, combStrength: 0))
        k += 1
    }
    return (out, frames)
}

let synthConfigs: [SynthConfig] = [
    SynthConfig(name: "bass-clean", lowMidi: 38, highMidi: 60, seed: 1),
    SynthConfig(name: "bass-weakf0", lowMidi: 38, highMidi: 60, weakFundamental: true, seed: 2),
    SynthConfig(name: "bass-breathy", lowMidi: 40, highMidi: 60, hnrDb: 10, seed: 3),
    SynthConfig(name: "tenor-legato", lowMidi: 48, highMidi: 69, legato: true, seed: 4),
    SynthConfig(name: "tenor-noisy", lowMidi: 48, highMidi: 69, snrDb: 20, seed: 5),
    SynthConfig(name: "alto-clean", lowMidi: 55, highMidi: 77, vowelScale: 1.15, seed: 6),
    SynthConfig(name: "alto-breathy", lowMidi: 55, highMidi: 77, hnrDb: 6, vowelScale: 1.15, seed: 7),
    SynthConfig(name: "soprano-clean", lowMidi: 60, highMidi: 86, vowelScale: 1.2, seed: 8),
    SynthConfig(name: "soprano-vib", lowMidi: 60, highMidi: 86, vibrato: 0.8, legato: true, vowelScale: 1.2, seed: 9),
    SynthConfig(name: "child-high", lowMidi: 67, highMidi: 84, hnrDb: 15, vowelScale: 1.3, seed: 10),
    SynthConfig(name: "bass-bleed", lowMidi: 40, highMidi: 60, seed: 11, bleed: 1.0),
    SynthConfig(name: "alto-bleed", lowMidi: 55, highMidi: 77, vowelScale: 1.15, seed: 12, bleed: 1.0),
    SynthConfig(name: "vbreathy-noisy", lowMidi: 45, highMidi: 70, hnrDb: 3, snrDb: 25, seed: 13),
]
