import Accelerate
import Foundation

/// Turns a stream of microphone samples into the pitch being sung, as a fractional
/// MIDI note number, or nil while nothing is being sung.
///
/// Pure signal processing with no audio framework attached, so it runs on whatever
/// thread feeds it, and offline too: every number below was tuned by replaying the
/// exported debug recordings (and synthesised voices from bass to child, clean to
/// very breathy, with background noise and the instrument leaking into the
/// microphone) through this class and comparing it with a slow, look-ahead pitch
/// track of the same audio. Nothing here allocates once it is set up.
///
/// How it works, in the order it happens:
///
/// 1. Every sample goes through a gentle high-pass (below the lowest note), into a
///    history just long enough for the lowest pitch.
/// 2. Every `analysisInterval` the most recent stretch is compared with itself one
///    period earlier, for every period in range (McLeod's normalised correlation).
///    The comparison window is `periodsCompared` periods long rather than a fixed
///    length: a fixed window has to be long enough for the lowest voice, so every
///    voice waits for it, while this one answers a 150 Hz note from the last 17 ms
///    and a 400 Hz note from the last 6 ms. The window's centre is what the estimate
///    describes, so this is what brings the delay down.
/// 3. The peaks of that curve are the candidate periods. A periodic sound also
///    repeats at two and three times its period, and a voice whose fundamental is
///    weak (common on a phone microphone) very nearly repeats at half of it, so the
///    peaks alone can't say which octave is sung. A harmonic comb on the spectrum of
///    the same few periods settles it: the true pitch has energy at every multiple
///    of itself and none halfway between them.
/// 4. The winner is shown, or not, by a small state machine that confirms a note
///    before it appears and a large jump before the line follows it. A wrong reading
///    almost never survives two analyses in a row, so asking for agreement removes
///    the one- and two-frame spikes at note starts at the cost of one interval.
nonisolated final class PitchAnalyzer {
    // MARK: Tuning

    /// The range searched, in Hz. A little below C2 and a little above C6, so a
    /// singer at either end of the app's vocal ranges, a touch flat or sharp, is
    /// still inside it.
    static let lowestFrequency = 60.0
    static let highestFrequency = 1400.0

    /// Seconds of audio between analyses. Half the phone's usual 10 ms I/O buffer, so
    /// a confirmation (which needs two analyses) usually completes within the buffer
    /// that started it.
    private static let analysisInterval = 0.005

    /// How many periods of the most recent audio each lag is compared over. Shorter
    /// answers sooner; below this the readings got noisy enough to double the spikes.
    private static let periodsCompared: Float = 1.5

    /// The comparison window never gets shorter than this, in seconds, however high
    /// the note: a handful of 1 kHz periods is too little to judge.
    private static let shortestWindow = 0.004

    /// RMS (full scale, over the last 10 ms) below which the input counts as silence.
    private static let silenceLevel: Float = 0.012

    /// A peak of the correlation curve is a candidate period when it reaches this
    /// share of the tallest one.
    private static let candidateShare: Float = 0.6
    private static let maxCandidates = 8

    /// Without a comb decision: the shortest candidate scoring this share of the best
    /// is the period (a multiple of the period scores about as well as the period).
    private static let octaveShare: Float = 0.9

    /// Candidates scoring at least this share of the best take part in the comb
    /// decision, which weighs the comb at `combWeight` against the correlation. Tuned
    /// on every analysis of the recordings with a steady reference: this picks the
    /// right octave in 99.99% of them (the correlation alone: 99.2% at best).
    private static let combShare: Float = 0.5
    private static let combWeight = 0.7
    /// The harmonics the comb looks at: primes only, so a candidate an octave or two
    /// too low can't collect the true pitch's harmonics as its own even ones.
    private static let combHarmonics: [Double] = [1, 2, 3, 5, 7]

    /// Clarity (the winning peak's height, 1 for a perfectly periodic sound) needed to
    /// start a note straight after one confirming analysis.
    private static let startClarity: Float = 0.8
    /// A breathy voice never gets there, so a lower bar also starts a note, but only
    /// after `weakStartConfirmations` more analyses agreeing within
    /// `weakStartTolerance` semitones. The ragged instant a note starts scores in the
    /// same range but never holds still that long.
    private static let weakStartClarity: Float = 0.4
    private static let weakStartConfirmations = 3
    private static let weakStartTolerance = 0.7
    /// How far apart the two analyses of an ordinary start may be, in semitones. Wide
    /// enough for the scoop most sung notes start with.
    private static let startTolerance = 1.5

    /// Clarity needed to keep showing a note. When the short window falls short, the
    /// same period is tried over `holdPeriods` periods (or as many as the history
    /// holds) against `longHoldClarity`: the longer comparison averages the breath
    /// noise out, which is what keeps a breathy note from flickering.
    private static let holdClarity: Float = 0.8
    private static let holdPeriods: Float = 6
    private static let longHoldClarity: Float = 0.3

    /// A note ends when its level falls below this share of its loudest moment. The
    /// tail of a note is where the pitch falls away and the readings wander.
    private static let releaseLevel: Float = 0.15

    /// A change of more than this many semitones inside a note is only followed once
    /// the next analysis agrees with it (within a semitone).
    private static let jumpToConfirm = 1.5

    // MARK: State

    let sampleRate: Double

    /// The pitch to show, as a fractional MIDI note number; nil while nothing is sung.
    private(set) var pitch: Double? = nil

    private let hop: Int
    private let capacity: Int
    private let minLag: Int
    private let maxLag: Int
    private let decimation: Int
    private let shortestWindowSamples: Int

    /// The most recent `capacity` samples, high-passed, newest last.
    private var history: [Float]
    private var filled = 0
    private var sinceAnalysis = 0

    // Second-order Butterworth high-pass at 50 Hz, its state, and where a block of
    // input lands after it.
    private let highPass: vDSP_biquad_Setup
    private var highPassDelay = [Float](repeating: 0, count: 4)
    private var filtered: [Float]

    // Scratch for one analysis, allocated once. The per-sample work all goes through
    // vDSP, so a debug build (no optimisation) costs about what a release one does.
    private var energy: [Double]            // energy[k] = energy of history[0..<k]
    private var squares: [Double]
    private var reduced: [Float]            // the history decimated to ~12 kHz
    private var reducedEnergy: [Double]
    private let reducer: [Float]
    private var coarse: [Float]             // correlation per decimated lag
    private var refineScores: [Float]
    private var candidateLags: [Double]
    private var candidateScores: [Float]
    private var candidateCombs: [Double]
    private var candidateCount = 0

    // Spectrum for the comb.
    private let fftLength: Int
    private let fftLog2: vDSP_Length
    private let fftSetup: FFTSetup
    private var fftInput: [Float]
    private var fftReal: [Float]
    private var fftImag: [Float]
    private var magnitude: [Float]
    private var taper: [Float]
    private var taperLength = 0

    // Tracking.
    private var showing = false
    private var pending: [Double]
    private var pendingCount = 0
    private var jumpCandidate: Double? = nil
    private var notePeak: Float = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        hop = max(1, Int(sampleRate * Self.analysisInterval))
        minLag = max(2, Int(sampleRate / Self.highestFrequency))
        maxLag = max(minLag + 4, Int(sampleRate / Self.lowestFrequency))
        capacity = Int(Float(maxLag) * (Self.periodsCompared + 1)) + 64
        decimation = max(1, min(4, Int(sampleRate / 12_000)))
        shortestWindowSamples = Int(sampleRate * Self.shortestWindow)

        history = [Float](repeating: 0, count: capacity)
        filtered = [Float](repeating: 0, count: hop)
        energy = [Double](repeating: 0, count: capacity + 1)
        squares = [Double](repeating: 0, count: capacity + 1)
        reduced = [Float](repeating: 0, count: capacity / decimation + 1)
        reducedEnergy = [Double](repeating: 0, count: capacity / decimation + 2)
        reducer = [Float](repeating: 1 / Float(decimation), count: decimation)
        coarse = [Float](repeating: 0, count: maxLag / decimation + 2)
        refineScores = [Float](repeating: 0, count: 2 * decimation + 3)
        candidateLags = [Double](repeating: 0, count: Self.maxCandidates)
        candidateScores = [Float](repeating: 0, count: Self.maxCandidates)
        candidateCombs = [Double](repeating: 0, count: Self.maxCandidates)
        pending = [Double](repeating: 0, count: Self.weakStartConfirmations + 1)

        let w0 = 2 * Double.pi * 50 / sampleRate
        let alpha = sin(w0) / sqrt(2.0)
        let a0 = 1 + alpha
        let b0 = (1 + cos(w0)) / 2 / a0
        highPass = vDSP_biquad_CreateSetup([b0, -2 * b0, b0, -2 * cos(w0) / a0, (1 - alpha) / a0], 1)!

        var length = 4096
        while length < capacity { length *= 2 }
        fftLength = length
        fftLog2 = vDSP_Length(length.trailingZeroBitCount)
        fftSetup = vDSP_create_fftsetup(fftLog2, FFTRadix(kFFTRadix2))!
        fftInput = [Float](repeating: 0, count: length)
        fftReal = [Float](repeating: 0, count: length / 2)
        fftImag = [Float](repeating: 0, count: length / 2)
        magnitude = [Float](repeating: 0, count: length / 2)
        taper = [Float](repeating: 0, count: capacity)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        vDSP_biquad_DestroySetup(highPass)
    }

    /// Feed the next `count` samples. The pitch is brought up to date as they go in.
    func process(_ samples: UnsafePointer<Float>, count: Int) {
        var done = 0
        while done < count {
            let take = min(count - done, hop - sinceAnalysis)
            append(samples + done, count: take)
            done += take
            sinceAnalysis += take
            if sinceAnalysis >= hop {
                sinceAnalysis = 0
                analyse()
            }
        }
    }

    // MARK: History

    /// Add up to `hop` samples to the history. `process` never hands over more.
    private func append(_ samples: UnsafePointer<Float>, count n: Int) {
        guard n > 0 else { return }
        vDSP_biquad(highPass, &highPassDelay, samples, 1, &filtered, 1, vDSP_Length(n))
        let keep = capacity - n
        history.withUnsafeMutableBufferPointer { h in
            let dst = h.baseAddress!
            memmove(dst, dst + n, keep * MemoryLayout<Float>.stride)
            filtered.withUnsafeBufferPointer { (dst + keep).update(from: $0.baseAddress!, count: n) }
        }
        filled = min(capacity, filled + n)
    }

    /// `totals[k]` = the energy of `values[0..<k]`, for k up to `count`. In double
    /// precision: the spans asked for are differences of totals far apart in size.
    private func runningEnergy(_ values: UnsafePointer<Float>, count: Int, into totals: UnsafeMutablePointer<Double>) {
        squares.withUnsafeMutableBufferPointer { sq in
            let s = sq.baseAddress!
            s[0] = 0
            vDSP_vspdp(values, 1, s + 1, 1, vDSP_Length(count))
            vDSP_vsqD(s + 1, 1, s + 1, 1, vDSP_Length(count))
            var one = 1.0
            vDSP_vrsumD(s, 1, &one, totals, 1, vDSP_Length(count + 1))
        }
    }

    // MARK: Analysis

    private func windowFor(lag: Int) -> Int {
        max(shortestWindowSamples, Int(Float(lag) * Self.periodsCompared))
    }

    private func silence() {
        pitch = nil
        showing = false
        pendingCount = 0
        jumpCandidate = nil
        notePeak = 0
    }

    private func analyse() {
        let n = capacity
        guard filled >= Int(Float(minLag) * (Self.periodsCompared + 1)) + 8 else { silence(); return }
        let available = filled

        let levelCount = min(available, Int(sampleRate * 0.01))
        var sumSquares: Float = 0
        history.withUnsafeBufferPointer {
            vDSP_svesq($0.baseAddress! + n - levelCount, 1, &sumSquares, vDSP_Length(levelCount))
        }
        let level = sqrtf(sumSquares / Float(levelCount))
        guard level > Self.silenceLevel else { silence(); return }

        // Running energy, so normalising any span is two lookups.
        history.withUnsafeBufferPointer { h in
            energy.withUnsafeMutableBufferPointer { runningEnergy(h.baseAddress!, count: n, into: $0.baseAddress!) }
        }

        // The coarse search runs on a copy averaged down to ~12 kHz, aligned so its
        // last sample ends where the history does.
        let d = decimation
        let reducedCount = n / d
        let offset = n - reducedCount * d
        history.withUnsafeBufferPointer { h in
            vDSP_desamp(h.baseAddress! + offset, vDSP_Stride(d), reducer, &reduced,
                        vDSP_Length(reducedCount), vDSP_Length(d))
        }
        reduced.withUnsafeBufferPointer { r in
            reducedEnergy.withUnsafeMutableBufferPointer {
                runningEnergy(r.baseAddress!, count: reducedCount, into: $0.baseAddress!)
            }
        }

        // ── Coarse search ────────────────────────────────────────────────────
        // Only lags whose whole span is in the history. Scored from lag 1 because
        // where the curve first dips below zero separates the shoulder of lag 0
        // (every sound resembles itself shifted a little) from real periods.
        let lowest = max(1, minLag / d)
        var highest = maxLag / d
        while highest > lowest && windowFor(lag: highest * d) + highest * d > available { highest -= 1 }
        guard highest > lowest + 2 else { silence(); return }

        var firstDip = -1
        reduced.withUnsafeBufferPointer { r in
            let base = r.baseAddress!
            for lag in 1...highest {
                let w = max(1, windowFor(lag: lag * d) / d)
                let start = reducedCount - w
                var dot: Float = 0
                vDSP_dotpr(base + start, 1, base + start - lag, 1, &dot, vDSP_Length(w))
                let spanEnergy = (reducedEnergy[reducedCount] - reducedEnergy[start])
                    + (reducedEnergy[reducedCount - lag] - reducedEnergy[start - lag])
                let score: Float = spanEnergy > 0 ? Float(2 * Double(dot) / spanEnergy) : 0
                coarse[lag] = score
                if firstDip < 0 && score < 0 { firstDip = lag }
            }
        }
        // Never dipping means nothing in range repeats: it's all shoulder.
        guard firstDip >= 0 else { silence(); return }
        let searchFrom = max(lowest, firstDip)
        guard searchFrom < highest else { silence(); return }
        var tallest: Float = 0
        for lag in searchFrom...highest where coarse[lag] > tallest { tallest = coarse[lag] }
        guard tallest > 0 else { silence(); return }

        // ── Candidates, refined at the full rate ─────────────────────────────
        candidateCount = 0
        for lag in searchFrom...highest {
            let score = coarse[lag]
            guard score >= tallest * Self.candidateShare else { continue }
            // A local maximum, and never the end of the range: the edge of what's
            // left of the curve is not a peak.
            let before = lag > 1 ? coarse[lag - 1] : .infinity
            let after = lag < highest ? coarse[lag + 1] : .infinity
            guard score >= before, score >= after else { continue }

            let center = lag * d
            let from = max(minLag, center - d), to = min(maxLag - 1, center + d)
            guard from <= to else { continue }
            for l in (from - 1)...(to + 1) {
                refineScores[l - from + 1] = correlation(lag: l, window: windowFor(lag: l), available: available)
            }
            var bestLag = from
            var bestScore: Float = -2
            for l in from...to where refineScores[l - from + 1] > bestScore {
                bestScore = refineScores[l - from + 1]
                bestLag = l
            }
            // Sub-sample position of the peak, so the pitch doesn't step between
            // whole-sample periods (a sizeable fraction of a semitone up high).
            let left = Double(refineScores[bestLag - from]), mid = Double(bestScore)
            let right = Double(refineScores[bestLag - from + 2])
            let curvature = left - 2 * mid + right
            var shift = 0.0
            if curvature < 0 { shift = max(-0.5, min(0.5, 0.5 * (left - right) / curvature)) }

            candidateLags[candidateCount] = Double(bestLag) + shift
            candidateScores[candidateCount] = bestScore
            candidateCount += 1
            if candidateCount == Self.maxCandidates { break }
        }
        guard candidateCount > 0 else { silence(); return }
        var best: Float = 0
        for i in 0..<candidateCount where candidateScores[i] > best { best = candidateScores[i] }
        guard best > 0 else { silence(); return }

        // ── Which one is the period ──────────────────────────────────────────
        var chosen = combChoice(best: best, available: available)
        if chosen < 0 {
            for i in 0..<candidateCount where candidateScores[i] >= best * Self.octaveShare {
                chosen = i
                break
            }
        }
        guard chosen >= 0 else { silence(); return }
        let period = candidateLags[chosen]
        let clarity = candidateScores[chosen]
        let midi = 69 + 12 * log2(sampleRate / period / 440)

        // ── Whether, and what, to show ───────────────────────────────────────
        if showing {
            var keep = clarity >= Self.holdClarity
            if !keep {
                let lag = Int(period.rounded())
                let window = min(available - lag, Int(Float(lag) * Self.holdPeriods))
                keep = window > 0 && correlation(lag: lag, window: window, available: available) >= Self.longHoldClarity
            }
            guard keep else { silence(); return }
            notePeak = max(notePeak, level)
            guard level >= notePeak * Self.releaseLevel else { silence(); return }
            if let shown = pitch, abs(midi - shown) > Self.jumpToConfirm {
                // Hold the line where it is until the next analysis agrees.
                if let waiting = jumpCandidate, abs(waiting - midi) <= 1 {
                    jumpCandidate = nil
                } else {
                    jumpCandidate = midi
                    return
                }
            } else {
                jumpCandidate = nil
            }
        } else {
            let strong = clarity >= Self.startClarity
            guard strong || clarity >= Self.weakStartClarity else { silence(); return }
            if pendingCount == pending.count {
                for i in 1..<pendingCount { pending[i - 1] = pending[i] }
                pendingCount -= 1
            }
            pending[pendingCount] = midi
            pendingCount += 1
            let needed = strong ? 1 : Self.weakStartConfirmations
            guard pendingCount > needed else { return }
            let tolerance = strong ? Self.startTolerance : Self.weakStartTolerance
            for i in (pendingCount - needed - 1)..<pendingCount where abs(pending[i] - midi) > tolerance {
                return
            }
            pendingCount = 0
            notePeak = level
        }
        pitch = midi
        showing = true
    }

    /// Normalised correlation of the newest `window` samples with the `window` samples
    /// `lag` earlier; 0 when that reaches past the audio heard so far.
    private func correlation(lag: Int, window: Int, available: Int) -> Float {
        guard lag > 0, window > 0, window + lag <= available else { return 0 }
        let n = capacity
        let start = n - window
        var dot: Float = 0
        history.withUnsafeBufferPointer { h in
            vDSP_dotpr(h.baseAddress! + start, 1, h.baseAddress! + start - lag, 1, &dot, vDSP_Length(window))
        }
        let spanEnergy = (energy[n] - energy[start]) + (energy[n - lag] - energy[start - lag])
        return spanEnergy > 0 ? Float(2 * Double(dot) / spanEnergy) : 0
    }

    // MARK: Harmonic comb

    /// The index of the candidate the comb and the correlation agree on best, or -1
    /// when there is nothing to decide between (or nothing for the comb to go on).
    private func combChoice(best: Float, available: Int) -> Int {
        var longest = 0.0
        var contenders = 0
        for i in 0..<candidateCount where candidateScores[i] >= best * Self.combShare {
            longest = max(longest, candidateLags[i])
            contenders += 1
        }
        guard contenders > 1 else { return -1 }
        // Three periods of the longest contender: enough to resolve its harmonics.
        let length = min(available, fftLength, Int(longest * 3))
        guard length > 64 else { return -1 }
        spectrum(length: length)

        var tallest = 0.0
        for i in 0..<candidateCount {
            candidateCombs[i] = comb(frequency: sampleRate / candidateLags[i])
            tallest = max(tallest, candidateCombs[i])
        }
        guard tallest > 0 else { return -1 }
        var chosen = -1
        var chosenValue = -Double.infinity
        for i in 0..<candidateCount where candidateScores[i] >= best * Self.combShare {
            let value = Double(candidateScores[i] / best) + Self.combWeight * candidateCombs[i] / tallest
            if value > chosenValue {
                chosenValue = value
                chosen = i
            }
        }
        return chosen
    }

    /// Square-root magnitude spectrum of the newest `length` samples (Hann window).
    /// The square root keeps a weak harmonic from vanishing next to a strong one.
    private func spectrum(length: Int) {
        if taperLength != length {
            vDSP_hann_window(&taper, vDSP_Length(length), Int32(vDSP_HANN_NORM))
            taperLength = length
        }
        vDSP_vclr(&fftInput, 1, vDSP_Length(fftLength))
        history.withUnsafeBufferPointer { h in
            vDSP_vmul(h.baseAddress! + capacity - length, 1, taper, 1, &fftInput, 1, vDSP_Length(length))
        }
        let half = fftLength / 2
        fftReal.withUnsafeMutableBufferPointer { re in
            fftImag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                fftInput.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, fftLog2, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(half))
            }
        }
        var count = Int32(half)
        magnitude.withUnsafeMutableBufferPointer { m in
            vvsqrtf(m.baseAddress!, m.baseAddress!, &count)
        }
    }

    /// SWIPE'-style harmonic evidence for `frequency`: the spectrum at its first prime
    /// harmonics (up to 3 kHz) minus the spectrum halfway between them, weighted by
    /// 1/√n. A pitch an octave too high loses its odd harmonics to the in-between
    /// slots; one an octave too low finds nothing at its own odd multiples.
    private func comb(frequency: Double) -> Double {
        let binWidth = sampleRate / Double(fftLength)
        let bins = fftLength / 2
        func amplitude(_ f: Double) -> Double {
            let position = f / binWidth
            let i = Int(position)
            guard i >= 0, i + 1 < bins else { return 0 }
            let fraction = position - Double(i)
            return Double(magnitude[i]) * (1 - fraction) + Double(magnitude[i + 1]) * fraction
        }
        var sum = 0.0, weights = 0.0
        for harmonic in Self.combHarmonics {
            if harmonic * frequency > 3000 { break }
            let weight = 1 / harmonic.squareRoot()
            sum += weight * (amplitude(harmonic * frequency)
                - 0.5 * (amplitude((harmonic - 0.5) * frequency) + amplitude((harmonic + 0.5) * frequency)))
            weights += weight
        }
        return weights > 0 ? sum / weights : 0
    }
}
