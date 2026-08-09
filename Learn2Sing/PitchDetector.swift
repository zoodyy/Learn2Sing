import AVFoundation
import Accelerate
import Combine
import os

/// Listens to the microphone and estimates the fundamental frequency the user is
/// singing, exposed as a (possibly fractional) MIDI note number. Uses a simple
/// autocorrelation pitch tracker over the vocal range — light enough to run in the
/// input tap callback.
final class PitchDetector: ObservableObject {
    // The latest estimate is stored behind a lock rather than published: the view
    // already redraws every frame via TimelineView and reads `currentPitch` then,
    // so publishing ~170×/sec would only flood the main thread and stutter the UI.
    private var _pitch: Double? = nil
    private var pitchLock = os_unfair_lock_s()

    /// Detected pitch as a fractional MIDI note number, or `nil` when silent / unsure.
    var currentPitch: Double? {
        os_unfair_lock_lock(&pitchLock)
        let value = _pitch
        os_unfair_lock_unlock(&pitchLock)
        return value
    }

    private let engine = AVAudioEngine()
    private var running = false

    /// DEBUG RECORDING — remove together with DebugRecording.swift.
    /// Set while a run is being recorded for debugging: every microphone hop is
    /// handed to it as it arrives, so the raw input can be written to disk.
    var debugSink: DebugAudioSink? = nil

    // MARK: Clap onset detection (used by the microphone-delay test)

    /// When enabled, sharp loud transients (claps) are timestamped so the delay
    /// test can compare when each clap was *heard* against the metronome tick that
    /// prompted it. Off for ordinary exercises so it never costs anything there.
    var detectClaps = false
    private var _claps: [UInt64] = []          // mach host times of detected onsets
    private var clapsLock = os_unfair_lock_s()
    private var lastClapHost: UInt64 = 0
    private var lastClapLevel: Float = 0       // loudness of the current clap event
    private var noiseFloor: Float = 0.01       // running estimate of the ambient level
    private var timebase = mach_timebase_info_data_t()

    // A clap is a transient that's both well above the ambient level (so it works
    // regardless of how hot or quiet a given microphone runs) and above a small
    // absolute floor (so quiet background ticks don't register). Detections within
    // `clapMergeWindow` of each other are treated as one clap event, keeping the
    // loudest onset's time — so if the metronome bleeds into the mic just before the
    // user's louder clap, the clap's timing wins instead of the tick's.
    private let clapRatio: Float = 4.0         // times the noise floor to count as a clap
    private let clapAbsMin: Float = 0.02       // absolute floor, below which nothing counts
    private let clapMergeWindow = 0.25         // seconds; onsets closer than this merge

    init() {
        mach_timebase_info(&timebase)
    }

    /// Remove and return every clap onset (mach_absolute_time) seen since last call.
    func drainClaps() -> [UInt64] {
        os_unfair_lock_lock(&clapsLock)
        let claps = _claps
        _claps.removeAll()
        os_unfair_lock_unlock(&clapsLock)
        return claps
    }

    // Each mic hop is tiny (low latency / fast refresh), but pitch detection needs
    // a longer span to resolve low notes — so hops are accumulated into this ring
    // buffer and autocorrelation runs over the whole retained window.
    private let hopSize: AVAudioFrameCount = 256
    private let windowSize = 2048
    private var window = [Float](repeating: 0, count: 2048)
    private var filled = 0

    // Scratch space for the mean-free copy of the window, its decimated version used
    // by the coarse pitch search, that search's correlation curve, and the running
    // energy totals both searches normalise with. Preallocated so the tap callback
    // never allocates.
    private var analysis = [Float](repeating: 0, count: 2048)
    private var decimated = [Float](repeating: 0, count: 2048)
    private var coarseCurve = [Float](repeating: 0, count: 2048)
    private var energyPrefix = [Float](repeating: 0, count: 2049)
    private var coarseEnergyPrefix = [Float](repeating: 0, count: 2049)
    /// How many coarse peaks at most get re-scored at the full sample rate. Real
    /// singing produces two or three; the cap only bounds the cost on noise.
    private let maxRefinements = 8
    private var candidateLags = [Int](repeating: 0, count: 8)      // maxRefinements
    private var candidateScores = [Float](repeating: 0, count: 8)  // maxRefinements
    /// A coarse peak this close to the tallest one is a candidate for the fine pass.
    private let candidateThreshold: Float = 0.6
    /// A refined peak scoring this close to the best one wins if its lag is shorter,
    /// which is how an exact multiple of the period is kept from reading an octave low.
    private let octaveThreshold: Float = 0.9
    /// Normalised correlation needed to start showing a pitch, and (lower, so a held
    /// note doesn't flicker out) to keep showing one. Measured against synthesised
    /// voices from clean to very breathy: real notes score from 1.0 down to about
    /// 0.38, while the ambiguous windows at a note's edges score below 0.2, so this
    /// sits in the gap. `clarityToHold` matches the sensitivity of the plain
    /// correlation test it replaces, so nothing that used to be tracked drops out.
    private let clarityToStart: Float = 0.45
    private let clarityToHold: Float = 0.30
    /// How far the window is decimated before the coarse search — chosen in `beginTap`
    /// from the microphone's sample rate so the reduced rate stays around 12 kHz,
    /// comfortably above twice the highest pitch we look for.
    private var decimation = 1
    private var decimFilter: [Float] = [1]

    /// Analysis is rate-limited to one run per this many seconds of audio. The tap's
    /// buffer size is negotiated with the system and varies a lot between routes, so
    /// without this the analysis rate (and its CPU cost) swung by more than 10× from
    /// one run to the next. ~100 estimates a second is already far more than the
    /// display can show, and the view eases between them.
    private let analysisInterval = 0.01
    private var sinceAnalysis = 0
    /// Whether the last analysis found a pitch, so the clarity bar can be lower for
    /// keeping one than for starting one. Touched only from the tap callback (and
    /// reset in `beginTap`, before the tap exists), so it needs no lock.
    private var pitchIsShowing = false

    func start() {
        guard !running else { return }
        // The audio session / route is configured once by PlaybackView before this
        // is called, so we must not reconfigure it here — doing so would switch the
        // route out from under the already-running playback engine.
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.beginTap() }
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        publish(nil)
    }

    private func beginTap() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return }

        filled = 0
        sinceAnalysis = 0
        pitchIsShowing = false
        // Reduce to ~12 kHz for the coarse search (the fine pass runs at full rate),
        // averaging the samples that are folded together so nothing aliases down.
        decimation = max(1, min(4, Int(sampleRate / 12_000.0)))
        decimFilter = [Float](repeating: 1 / Float(decimation), count: decimation)
        lastClapHost = 0
        lastClapLevel = 0
        noiseFloor = 0.01
        os_unfair_lock_lock(&clapsLock)
        _claps.removeAll()
        os_unfair_lock_unlock(&clapsLock)
        debugSink?.begin(format: format)   // DEBUG RECORDING — remove with DebugRecording.swift
        input.removeTap(onBus: 0)
        // Tiny hop so a fresh estimate lands very frequently; the view interpolates
        // between estimates so the indicator still moves every rendered frame.
        input.installTap(onBus: 0, bufferSize: hopSize, format: format) { [weak self] buffer, time in
            self?.process(buffer: buffer, time: time, sampleRate: sampleRate)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private func process(buffer: AVAudioPCMBuffer, time: AVAudioTime, sampleRate: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        debugSink?.append(buffer: buffer, time: time)   // DEBUG RECORDING — remove with DebugRecording.swift

        if detectClaps { detectClap(channel: channel, count: n, time: time) }

        // Slide the new hop into the ring buffer, keeping the most recent `windowSize`.
        window.withUnsafeMutableBufferPointer { w in
            let dst = w.baseAddress!
            if n >= windowSize {
                dst.update(from: channel + (n - windowSize), count: windowSize)
            } else {
                let keep = windowSize - n
                memmove(dst, dst + n, keep * MemoryLayout<Float>.stride)
                (dst + keep).update(from: channel, count: n)
            }
        }
        filled = n >= windowSize ? windowSize : min(windowSize, filled + n)

        // Wait until the window holds enough audio to resolve the lowest pitch.
        let minFreq = 65.0     // ~C2
        let maxFreq = 1100.0   // ~C6
        let maxLag = min(windowSize - 1, Int(sampleRate / minFreq))
        guard filled >= maxLag * 2 else { return }

        // Analysing on every hop re-scores an 87%-overlapping window and burns CPU the
        // main thread needs to keep the notes scrolling; once every `analysisInterval`
        // is plenty.
        sinceAnalysis += n
        guard sinceAnalysis >= max(1, Int(sampleRate * analysisInterval)) else { return }
        sinceAnalysis = 0

        analyze(sampleRate: sampleRate, minFreq: minFreq, maxFreq: maxFreq, maxLag: maxLag)
    }

    /// Register a clap when this hop's peak rises sharply above the ambient level.
    /// Detection is relative to a slowly tracked noise floor so it adapts to each
    /// microphone's gain (a fixed threshold worked for hot mics like AirPods but
    /// missed quieter built-in mics entirely). The onset is timestamped with the
    /// buffer's own host time so it can be compared against the playback clock.
    private func detectClap(channel: UnsafePointer<Float>, count: Int, time: AVAudioTime) {
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(count))

        // Track the ambient level slowly so a single loud clap barely moves it.
        noiseFloor = max(0.005, noiseFloor * 0.995 + peak * 0.005)

        guard peak > clapAbsMin, peak > noiseFloor * clapRatio else { return }

        let host = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
        if lastClapHost != 0 {
            let elapsed = Double(host &- lastClapHost) * Double(timebase.numer)
                / Double(timebase.denom) / 1.0e9
            if elapsed < clapMergeWindow {
                // Same clap event: if this onset is louder, it's closer to the true
                // attack, so move the recorded time to it. Otherwise ignore it.
                guard peak > lastClapLevel else { return }
                lastClapHost = host
                lastClapLevel = peak
                os_unfair_lock_lock(&clapsLock)
                if !_claps.isEmpty { _claps[_claps.count - 1] = host }
                os_unfair_lock_unlock(&clapsLock)
                return
            }
        }
        lastClapHost = host
        lastClapLevel = peak
        os_unfair_lock_lock(&clapsLock)
        _claps.append(host)
        os_unfair_lock_unlock(&clapsLock)
    }

    /// Find the lag (period) whose normalised correlation is strongest over the vocal
    /// range.
    ///
    /// Scoring every lag at the full sample rate costs upwards of a million
    /// multiply-adds per analysis, on a real-time thread, whenever the singer is
    /// making any sound at all — enough to starve the main thread and stutter the
    /// scrolling notes. Instead the window is decimated for a coarse search and only
    /// the handful of lags around the winner are re-scored at full rate, with every
    /// inner loop handed to vDSP's vector units. Same answer, a tiny fraction of the
    /// work, and no dependence on the build's optimisation level.
    ///
    /// Lags are scored as a *normalised* correlation (McLeod's NSDF: twice the
    /// correlation over the energy of the two spans it overlaps) rather than a bare
    /// dot product. A bare dot product is biased towards short lags — it sums fewer
    /// terms the further it reaches, and, more damagingly, when the window is not
    /// stationary the sound only overlaps itself at short lags at all. That is exactly
    /// the situation at the moment a note starts or stops: the voice fills one end of
    /// the window and silence the other, so the tallest raw peak sits on the shoulder
    /// of lag 0 and the note reads back an octave or more too high. Normalising takes
    /// the energy of each span out of the comparison, so a half-filled window scores
    /// what it actually contains.
    private func analyze(sampleRate: Double, minFreq: Double, maxFreq: Double, maxLag: Int) {
        let count = windowSize
        let hadPitch = pitchIsShowing
        func emit(_ value: Double?) {
            pitchIsShowing = value != nil
            publish(value)
        }

        // RMS gate — ignore silence / background noise.
        var sumSq: Float = 0
        vDSP_svesq(window, 1, &sumSq, vDSP_Length(count))
        let rms = sqrtf(sumSq / Float(count))
        guard rms > 0.012, sumSq > 0 else { emit(nil); return }

        let minLag = max(1, Int(sampleRate / maxFreq))
        guard maxLag > minLag else { emit(nil); return }

        // Analyse a mean-free copy: any DC offset keeps the correlation curve positive
        // at every lag, and the candidate gate below needs to see where it dips.
        var mean: Float = 0
        vDSP_meanv(window, 1, &mean, vDSP_Length(count))
        var negMean = -mean
        vDSP_vsadd(window, 1, &negMean, &analysis, 1, vDSP_Length(count))

        // Reduce for the coarse search, averaging the samples that are folded together
        // so nothing aliases down. (A decimation of 1 makes this a plain copy, which
        // keeps slow sample rates on the same code path.)
        let decim = decimation
        let dCount = count / decim
        vDSP_desamp(analysis, vDSP_Stride(decim), decimFilter, &decimated,
                    vDSP_Length(dCount), vDSP_Length(decim))

        // Running energy totals, so normalising a lag costs two lookups.
        fillEnergyPrefix(analysis, count: count, into: &energyPrefix)
        fillEnergyPrefix(decimated, count: dCount, into: &coarseEnergyPrefix)

        let coarseLo = max(1, minLag / decim)
        let coarseHi = min(dCount - 1, maxLag / decim)
        guard coarseHi > coarseLo else { emit(nil); return }

        // ── Coarse search on the decimated window ─────────────────────────────
        // Scored from lag 1 — below the shortest period we look for — because where
        // the curve first crosses zero is what separates the descending shoulder of
        // lag 0 (every signal correlates with a slightly shifted copy of itself) from
        // a genuine period peak. Only lags past that crossing can be periods.
        var gate = -1
        decimated.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            for lag in 1...coarseHi {
                var dot: Float = 0
                vDSP_dotpr(p, 1, p + lag, 1, &dot, vDSP_Length(dCount - lag))
                let energy = coarseEnergyPrefix[dCount - lag]
                    + (coarseEnergyPrefix[dCount] - coarseEnergyPrefix[lag])
                let score = energy > 0 ? 2 * dot / energy : 0
                coarseCurve[lag] = score
                if gate < 0, score < 0 { gate = lag }
            }
        }
        // Never dipping means nothing in the window repeats at a period we care about
        // — it's all still shoulder, which is what an onset or a release looks like.
        guard gate >= 0 else { emit(nil); return }

        let searchLo = max(coarseLo, gate)
        guard searchLo < coarseHi else { emit(nil); return }
        var coarseMax: Float = 0
        for lag in searchLo...coarseHi where coarseCurve[lag] > coarseMax {
            coarseMax = coarseCurve[lag]
        }
        guard coarseMax > 0 else { emit(nil); return }

        // Every *near*-tallest coarse peak is kept, not just the tallest one.
        // Quantising the lag attenuates a peak whose period isn't a whole number of
        // decimated samples, and that alone can leave an exact multiple of it — an
        // octave down — looking taller. Re-scoring the candidates at full rate settles
        // it the same way an undecimated search would.
        var candidates = 0
        for lag in searchLo...coarseHi {
            if candidates >= maxRefinements { break }
            let score = coarseCurve[lag]
            guard score >= coarseMax * candidateThreshold else { continue }
            // The bottom of the range is deliberately not allowed to count as a peak:
            // a boundary is a local maximum of whatever is left of the curve, and the
            // shoulder only ever descends, so it would hand back the highest pitch in
            // range every time the window was anything but steady.
            let prev = lag > 1 ? coarseCurve[lag - 1] : .infinity
            let next = lag < coarseHi ? coarseCurve[lag + 1] : -.infinity
            guard score >= prev, score >= next else { continue }   // local maximum only
            candidateLags[candidates] = lag
            candidates += 1
        }
        guard candidates > 0 else { emit(nil); return }

        // ── Fine search at the full sample rate ───────────────────────────────
        var refinedLag = 0.0
        var clarity: Float = 0
        analysis.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            func score(_ lag: Int) -> Float {
                var dot: Float = 0
                vDSP_dotpr(p, 1, p + lag, 1, &dot, vDSP_Length(count - lag))
                let energy = energyPrefix[count - lag] + (energyPrefix[count] - energyPrefix[lag])
                return energy > 0 ? 2 * dot / energy : 0
            }

            var bestScore: Float = 0
            for i in 0..<candidates {
                let center = candidateLags[i] * decim
                let lo = max(minLag, center - decim)
                let hi = min(maxLag, center + decim)
                guard lo <= hi else { candidateScores[i] = 0; continue }
                var peakLag = lo
                var peakScore = -Float.greatestFiniteMagnitude
                for lag in lo...hi {
                    let s = score(lag)
                    if s > peakScore { peakScore = s; peakLag = lag }
                }
                candidateLags[i] = peakLag                 // now a full-rate lag
                candidateScores[i] = peakScore
                if peakScore > bestScore { bestScore = peakScore }
            }
            guard bestScore > 0 else { return }

            // Of the peaks that score about as well as the best one, take the one at
            // the shortest lag. A whole multiple of the period correlates nearly as
            // well as the period itself, so picking the tallest outright reads an
            // octave (or a twelfth) low now and then.
            var best = 0
            var bestClarity: Float = 0
            for i in 0..<candidates where candidateScores[i] >= bestScore * octaveThreshold {
                best = candidateLags[i]
                bestClarity = candidateScores[i]
                break
            }
            guard best > 0 else { return }

            // Sub-sample peak position. Without it the reported pitch steps between
            // whole-sample periods, which on high notes is a sizeable fraction of a
            // semitone and makes the singer's dot twitch.
            var delta = 0.0
            if best > minLag, best < maxLag {
                let cm = Double(score(best - 1))
                let c0 = Double(bestClarity)
                let cp = Double(score(best + 1))
                let denom = cm - 2 * c0 + cp
                if denom < 0 { delta = max(-0.5, min(0.5, 0.5 * (cm - cp) / denom)) }
            }
            refinedLag = Double(best) + delta
            clarity = bestClarity
        }

        guard refinedLag > 0 else { emit(nil); return }
        // Reject weak / noisy peaks. Starting a note takes a clearer peak than keeping
        // one does, so the ragged instant where a note is only part-way into the window
        // shows nothing rather than a guess, while a held note doesn't drop out.
        guard clarity >= (hadPitch ? clarityToHold : clarityToStart) else { emit(nil); return }

        let freq = sampleRate / refinedLag
        let midi = 69.0 + 12.0 * log2(freq / 440.0)
        emit(midi)
    }

    /// Fill `dst[k]` with the energy of the first `k` samples of `src`, so the energy
    /// of any span of the window is a single subtraction. Accumulated in double
    /// precision because the spans the normalisation asks for are differences between
    /// totals that can be far apart in size.
    private func fillEnergyPrefix(_ src: UnsafePointer<Float>, count: Int,
                                  into dst: UnsafeMutablePointer<Float>) {
        var running = 0.0
        dst[0] = 0
        for i in 0..<count {
            let sample = Double(src[i])
            running += sample * sample
            dst[i + 1] = Float(running)
        }
    }

    private func publish(_ value: Double?) {
        // Store the raw estimate; the view reads & smooths it once per rendered frame.
        os_unfair_lock_lock(&pitchLock)
        _pitch = value
        os_unfair_lock_unlock(&pitchLock)
    }
}
