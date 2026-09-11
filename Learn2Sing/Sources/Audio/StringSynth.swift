//
//  StringSynth.swift
//  Learn2Sing
//
//  The piano and the guitar, drawn as what they are: a string set moving by a
//  hammer or a pick, heard through a soundboard or a guitar body. Built from
//  harmonics like the other instruments, so it sounds the same on the simulator
//  and on a device, but with the things that make a real string sound like one:
//  which harmonics the strike leaves out, a spectrum that reaches up to where the
//  ear expects it whatever the note, highs that ring out first so the note mellows
//  as it sounds, and the knock of the hammer or the scratch of the pick.
//
//  What it deliberately leaves out is anything that bends the pitch. A real
//  piano's upper partials sit sharp of the harmonic series and its unison strings
//  beat against each other; here every partial is an exact whole multiple of the
//  note's own frequency, because the note is the pitch the singer is asked to hit.
//

import Foundation

/// A resonance of the instrument, baked into the loudness of the harmonics near
/// it: a guitar's air cavity and top plate make the partials that fall on them
/// ring out louder. A gain below 1 is a dip instead — the one a recording engineer
/// puts in around 300 Hz to keep a piano or a guitar from sounding muddy. Only
/// loudness: it is not a filter, so it can't move a partial by a hair.
nonisolated struct StringResonance {
    /// Centre of the resonance, in Hz.
    let frequency: Double
    /// How much louder (or, below 1, quieter) a partial right on it comes out.
    let gain: Double
    /// How narrow it is: the higher, the fewer partials it reaches.
    let q: Double
}

/// What one of the string instruments sounds like: the numbers that shape a note
/// from its spectrum at the moment it is struck to the way it dies away.
nonisolated struct StringInstrument {
    /// Where the string is set moving, as a fraction of its length from the end:
    /// a piano hammer about an eighth of the way along, a pick nearer a fifth. A
    /// string can't sound the harmonics that have a node at that point, and the
    /// ones either side of them come out weak — a large part of why a piano and a
    /// guitar sound unlike each other and unlike an organ.
    let excitationPoint: Double
    /// The least that leaves a harmonic at: a hammer or a fingertip has a width,
    /// so the ones "at" the node are softened rather than silenced.
    let excitationFloor: Double
    /// How quickly the harmonics fall away by number, amplitude ∝ 1/nᵗ.
    let harmonicTilt: Double
    /// Where the spectrum starts rolling off, in Hz, and how steeply. In Hz rather
    /// than in harmonics, so a low note keeps the upper partials that give it
    /// definition instead of stopping at its tenth harmonic and sounding dull.
    let brightness: Double
    let rolloffOrder: Double
    /// A soundboard or a guitar body radiates the lowest frequencies poorly, which
    /// is why a piano's bass notes are carried by their overtones more than by
    /// their fundamentals. The frequency, in Hz, below which that sets in. What
    /// keeps the low notes from booming.
    let radiationCutoff: Double
    /// The resonances (and dips) the instrument's sound is coloured by.
    let resonances: [StringResonance]
    /// The highest partial worth drawing, in Hz. Anything above has rolled off
    /// and rung out before it could be heard.
    let maxFrequency: Double

    /// How long the strike takes to reach full level, in seconds: a millisecond or
    /// so, just enough that the note doesn't click.
    let attackTime: Double
    /// How long a note rings, as the time constant of its decay at middle C, in
    /// seconds. One stage, and a gentle one: a real string drops away fast in its
    /// first half second before settling into a slow decay, but that makes the
    /// start of every note a burst well above the rest of it. Here a note starts at
    /// the level it goes on at.
    let decayTime: Double
    /// How much longer a lower note rings: the time is scaled by 2 to the power of
    /// this, per octave below middle C.
    let keyTracking: Double
    /// How much faster a partial dies the higher it is, per second at 1 kHz, and how
    /// that grows with frequency. The highs going first is what turns the bright
    /// strike into a warm tail instead of a buzz that never changes. The loudness
    /// they take with them is given back to the note as a whole (see
    /// `StringVoiceBank`), so it is the tone that mellows, not the level that drops.
    let partialDamping: Double
    let dampingExponent: Double
    /// Time constant of the damper (or the fretting hand) stopping the string when
    /// the note ends, in seconds.
    let releaseTime: Double

    /// The knock of the hammer or the scratch of the pick: a short burst of noise
    /// in `noiseBand` (Hz), starting at `noiseLevel` times the note's own level and
    /// gone with the time constant `noiseTime`. It has no pitch, so it can't blur
    /// the note's; it is what gives each note a front edge.
    let noiseLevel: Double
    let noiseTime: Double
    let noiseBand: ClosedRange<Double>

    /// The loudness a note at middle C starts at — and, but for its slow decay,
    /// keeps — as the RMS of the tone.
    let level: Double
    /// How that loudness changes with pitch, in dB per octave above middle C. Both
    /// instruments' higher notes ring out sooner, so the middle of a note has always
    /// sat lower the higher it is; a note now starts at the level its middle is at,
    /// so the start comes down with the pitch as well.
    let levelTracking: Double

    /// A grand piano struck at a moderate strength.
    static let piano = StringInstrument(
        excitationPoint: 0.12, excitationFloor: 0.15,
        harmonicTilt: 0.75, brightness: 2_600, rolloffOrder: 1.2,
        radiationCutoff: 160,
        resonances: [
            StringResonance(frequency: 320, gain: 0.7, q: 0.9),     // mud dip
            StringResonance(frequency: 1_800, gain: 1.2, q: 1),     // presence
        ],
        maxFrequency: 9_000,
        attackTime: 0.0015,
        decayTime: 3.5, keyTracking: 0.55,
        partialDamping: 0.8, dampingExponent: 1.2,
        releaseTime: 0.09,
        noiseLevel: 0.12, noiseTime: 0.006, noiseBand: 200...2_500,
        level: 0.042, levelTracking: -2.1)

    /// A steel-string acoustic guitar, picked.
    static let guitar = StringInstrument(
        excitationPoint: 0.18, excitationFloor: 0.1,
        harmonicTilt: 0.85, brightness: 3_500, rolloffOrder: 1.3,
        radiationCutoff: 180,
        resonances: [
            StringResonance(frequency: 100, gain: 1.8, q: 5),       // air cavity
            StringResonance(frequency: 220, gain: 1.3, q: 5),       // top plate
            StringResonance(frequency: 380, gain: 0.7, q: 1),       // mud dip
            StringResonance(frequency: 2_800, gain: 1.35, q: 1),    // presence
        ],
        maxFrequency: 8_000,
        attackTime: 0.001,
        decayTime: 1.6, keyTracking: 0.5,
        partialDamping: 1.0, dampingExponent: 1.4,
        releaseTime: 0.1,
        noiseLevel: 0.18, noiseTime: 0.004, noiseBand: 1_500...6_000,
        level: 0.0305, levelTracking: -1.4)

    /// How loud harmonic `n`, sounding at `frequency`, starts out relative to the
    /// others — before the note is levelled as a whole.
    func amplitude(harmonic n: Int, frequency f: Double) -> Double {
        let h = Double(n)
        let strike = max(abs(sin(h * .pi * excitationPoint)), excitationFloor)
        let tilt = pow(h, -harmonicTilt)
        let rolloff = 1 / (1 + pow(f / brightness, 2 * rolloffOrder)).squareRoot()
        let ratio = f / radiationCutoff
        let radiation = ratio / (1 + ratio * ratio).squareRoot()
        var colour = 1.0
        for resonance in resonances {
            let detuning = f / resonance.frequency - resonance.frequency / f
            colour *= 1 + (resonance.gain - 1) / (1 + resonance.q * resonance.q * detuning * detuning)
        }
        return strike * tilt * rolloff * radiation * colour
    }

    /// How much faster than the note as a whole a partial at `frequency` dies, per
    /// second.
    func damping(frequency f: Double) -> Double {
        partialDamping * pow(f / 1_000, dampingExponent)
    }
}

/// The voices of a string instrument: every partial of every sounding note, and
/// what shapes each note over time.
///
/// Played from the audio render thread one sample at a time, so nothing in here
/// allocates once it is built: the partials live in flat buffers allocated up
/// front, and each one is an oscillator turned by a fixed rotation per sample
/// rather than a `sin` call — exact to the note's frequency, and cheap enough for a
/// low note to carry the sixty-odd partials it needs. The partials are summed a
/// short block ahead, each held in locals for the length of the block, which is
/// what keeps the cost down in a Debug build too; everything that can change from
/// one sample to the next — the envelope, the damper coming down, the strike's
/// noise — is still applied sample by sample.
///
/// A note holds its loudness while its tone mellows. The level its upper partials
/// lose as they ring out is given back to it, eased in block by block, so what is
/// heard dropping away is only the note's own slow decay. Left alone, the first
/// moments of a note would stand several decibels above the rest of it — all of
/// it brightness that the ear takes for a burst at the start.
///
/// Not thread-safe on its own; the player calls it with its render lock held.
nonisolated final class StringVoiceBank {
    /// The most partials one note is drawn with. Enough for a low note to reach
    /// into the kilohertz range where its definition is; a higher note runs into
    /// the instrument's `maxFrequency` long before it runs out of these.
    static let maxPartials = 64

    /// How many samples of a note's partials are summed at a time.
    private static let blockLength = 64

    /// Below this, a partial or a note is past hearing and is let go of.
    private static let silence = 1e-6
    private static let noteSilence = 2e-4

    /// The most that loudness is given back by, as a factor. Every partial of a high
    /// note rings out in time, its fundamental included, so without a ceiling one
    /// held long enough would swell; this is past what a note of any ordinary length
    /// needs.
    private static let maxHold = 2.0

    private let voiceCount: Int
    private let sampleRate: Double

    // Per partial, one slot per voice × partial. Each oscillator is a point going
    // round the unit circle: (`real`, `imaginary`) is where it is, and
    // (`turnCos`, `turnSin`) the rotation it takes each sample. `imaginary` is what
    // is heard.
    private let real: UnsafeMutablePointer<Double>
    private let imaginary: UnsafeMutablePointer<Double>
    private let turnCos: UnsafeMutablePointer<Double>
    private let turnSin: UnsafeMutablePointer<Double>
    private let amplitude: UnsafeMutablePointer<Double>
    private let fade: UnsafeMutablePointer<Double>
    /// The partials' sum for the block being played, one block per voice.
    private let tone: UnsafeMutablePointer<Double>

    /// Everything about one note but its partials.
    private struct Note {
        /// How many of its partials are still worth drawing — the top ones die
        /// first, so the count only ever shrinks.
        var partialCount = 0
        /// Where in its block of summed partials the note has got to.
        var blockPosition = StringVoiceBank.blockLength
        /// The note's decay, and what it is multiplied by per sample.
        var decay = 1.0
        var decayFade = 1.0
        /// What the partials weighed together when the note was struck, and the
        /// gain the last block ended on, giving back what they have lost since.
        var initialPower = 0.0
        var hold = 1.0
        var attackLength = 1
        var attackPosition = 0
        var isReleased = false
        var release = 1.0
        var releaseFade = 1.0
        /// The strike's noise burst, and the two one-pole low-passes whose
        /// difference is the band it is heard in.
        var noise = 0.0
        var noiseFade = 1.0
        var noiseUpper = 0.0
        var noiseLower = 0.0
        var upperCoefficient = 0.0
        var lowerCoefficient = 0.0
        var isFinished = true
    }

    private var notes: [Note]

    /// xorshift64, for the partials' starting phases and the strike's noise.
    private var randomState: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(voices: Int, sampleRate: Double) {
        voiceCount = voices
        self.sampleRate = sampleRate
        func buffer(_ count: Int) -> UnsafeMutablePointer<Double> {
            let pointer = UnsafeMutablePointer<Double>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        let slots = voices * Self.maxPartials
        real = buffer(slots)
        imaginary = buffer(slots)
        turnCos = buffer(slots)
        turnSin = buffer(slots)
        amplitude = buffer(slots)
        fade = buffer(slots)
        tone = buffer(voices * Self.blockLength)
        notes = Array(repeating: Note(), count: voices)
    }

    deinit {
        for pointer in [real, imaginary, turnCos, turnSin, amplitude, fade] {
            pointer.deinitialize(count: voiceCount * Self.maxPartials)
            pointer.deallocate()
        }
        tone.deinitialize(count: voiceCount * Self.blockLength)
        tone.deallocate()
    }

    /// A uniformly distributed number in 0..<1.
    private func nextRandom() -> Double {
        randomState ^= randomState << 13
        randomState ^= randomState >> 7
        randomState ^= randomState << 17
        return Double(randomState >> 11) * 0x1p-53
    }

    /// Strikes `pitch` (a MIDI note number) on `voice`, replacing whatever it was
    /// sounding.
    func start(_ voice: Int, pitch: Int, instrument: StringInstrument) {
        let fundamental = 440 * pow(2, Double(pitch - 69) / 12)
        let ceiling = min(instrument.maxFrequency, sampleRate * 0.45)
        let count = max(1, min(Self.maxPartials, Int(ceiling / fundamental)))
        let base = voice * Self.maxPartials

        var power = 0.0
        for n in 1...count {
            let i = base + n - 1
            // An exact whole multiple of the note, however high the partial.
            let frequency = fundamental * Double(n)
            let turn = 2 * .pi * frequency / sampleRate
            turnCos[i] = cos(turn)
            turnSin[i] = sin(turn)
            // Each partial starts at a phase of its own, as the partials of a real
            // strike do, so they don't all peak together in one hard click.
            let phase = 2 * .pi * nextRandom()
            real[i] = cos(phase)
            imaginary[i] = sin(phase)
            let level = instrument.amplitude(harmonic: n, frequency: frequency)
            amplitude[i] = level
            power += level * level
            fade[i] = exp(-instrument.damping(frequency: frequency) / sampleRate)
        }
        // Levelled by what the note sounds like as a whole, so every note starts at
        // the loudness its pitch calls for however its harmonics are spread.
        let noteLevel = instrument.level
            * pow(10, instrument.levelTracking * Double(pitch - 60) / 12 / 20)
        let scale = power > 0 ? noteLevel / (power / 2).squareRoot() : 0
        for i in base..<(base + count) { amplitude[i] *= scale }

        let keyScale = pow(2, -Double(pitch - 60) / 12 * instrument.keyTracking)
        var note = Note()
        note.partialCount = count
        note.initialPower = power * scale * scale
        note.decayFade = exp(-1 / (instrument.decayTime * keyScale * sampleRate))
        note.attackLength = max(1, Int(instrument.attackTime * sampleRate))
        note.releaseFade = exp(-1 / (instrument.releaseTime * sampleRate))

        // The noise band is the difference of two one-pole low-passes fed the same
        // white noise. Its level follows from their coefficients, so the burst is
        // scaled to start at exactly `noiseLevel` of the tone.
        let upper = 1 - exp(-2 * .pi * instrument.noiseBand.upperBound / sampleRate)
        let lower = 1 - exp(-2 * .pi * instrument.noiseBand.lowerBound / sampleRate)
        let whiteVariance = 1.0 / 3        // uniform in -1...1
        let bandVariance = whiteVariance * (upper / (2 - upper) + lower / (2 - lower)
            - 2 * upper * lower / (1 - (1 - upper) * (1 - lower)))
        note.upperCoefficient = upper
        note.lowerCoefficient = lower
        note.noise = bandVariance > 0
            ? instrument.noiseLevel * noteLevel / bandVariance.squareRoot() : 0
        note.noiseFade = exp(-1 / (instrument.noiseTime * sampleRate))
        note.isFinished = false
        notes[voice] = note
    }

    /// Lets go of the note on `voice`: the damper comes down on it.
    func release(_ voice: Int) {
        notes[voice].isReleased = true
    }

    /// Whether the note on `voice` has died away completely.
    func isFinished(_ voice: Int) -> Bool {
        notes[voice].isFinished
    }

    /// The next sample of the note on `voice`, and the note one sample on.
    func nextSample(_ voice: Int) -> Double {
        var note = notes[voice]
        guard !note.isFinished else { return 0 }

        if note.blockPosition == Self.blockLength {
            sumPartials(voice, note: &note)
            note.blockPosition = 0
        }
        var envelope = note.decay * note.release
        if note.attackPosition < note.attackLength {
            envelope *= 0.5 - 0.5 * cos(.pi * Double(note.attackPosition) / Double(note.attackLength))
            note.attackPosition += 1
        }
        var sample = tone[voice * Self.blockLength + note.blockPosition] * envelope
        note.blockPosition += 1
        note.decay *= note.decayFade
        if note.isReleased { note.release *= note.releaseFade }

        if note.noise > Self.silence {
            let white = 2 * nextRandom() - 1
            note.noiseUpper += note.upperCoefficient * (white - note.noiseUpper)
            note.noiseLower += note.lowerCoefficient * (white - note.noiseLower)
            sample += (note.noiseUpper - note.noiseLower) * note.noise
            note.noise *= note.noiseFade
        }

        if note.decay * note.release < Self.noteSilence,
           note.noise <= Self.silence {
            note.isFinished = true
        }
        notes[voice] = note
        return sample
    }

    /// Sums the next block of the note's partials into its tone buffer, gives back
    /// the loudness they have lost to their damping, then stops drawing the
    /// partials at the top that have rung out.
    private func sumPartials(_ voice: Int, note: inout Note) {
        let out = tone + voice * Self.blockLength
        let length = Self.blockLength
        var j = 0
        while j < length { out[j] = 0; j += 1 }

        let base = voice * Self.maxPartials
        var i = base
        let end = base + note.partialCount
        var power = 0.0
        while i < end {
            var x = real[i]
            var y = imaginary[i]
            var a = amplitude[i]
            let c = turnCos[i], s = turnSin[i], f = fade[i]
            j = 0
            while j < length {
                let turned = x * c - y * s
                y = y * c + x * s
                x = turned
                out[j] += y * a
                a *= f
                j += 1
            }
            real[i] = x
            imaginary[i] = y
            amplitude[i] = a
            power += a * a
            i += 1
        }

        // The gain that puts the partials back at the weight they were struck with,
        // reached by the end of this block from where the last one left off, so it
        // moves by a hair per sample and never steps.
        let target = power > 0
            ? min(Self.maxHold, (note.initialPower / power).squareRoot()) : Self.maxHold
        let step = (target - note.hold) / Double(length)
        j = 0
        while j < length {
            out[j] *= note.hold + step * Double(j + 1)
            j += 1
        }
        note.hold = target

        while note.partialCount > 1, amplitude[base + note.partialCount - 1] < Self.silence {
            note.partialCount -= 1
        }
    }
}
