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

    // Scratch space for the decimated copy of the window used by the coarse pitch
    // search, and for that search's correlation curve. Preallocated so the tap
    // callback never allocates.
    private var decimated = [Float](repeating: 0, count: 2048)
    private var coarseCorr = [Float](repeating: 0, count: 2048)
    /// How many coarse peaks at most get re-scored at the full sample rate. Real
    /// singing produces two or three; the cap only bounds the cost on noise.
    private let maxRefinements = 8
    /// A coarse peak this close to the tallest one is a candidate for the fine pass.
    private let candidateThreshold: Float = 0.6
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

    /// Find the lag (period) whose autocorrelation is strongest over the vocal range.
    ///
    /// Scoring every lag at the full sample rate costs upwards of a million
    /// multiply-adds per analysis, on a real-time thread, whenever the singer is
    /// making any sound at all — enough to starve the main thread and stutter the
    /// scrolling notes. Instead the window is decimated for a coarse search and only
    /// the handful of lags around the winner are re-scored at full rate, with every
    /// inner loop handed to vDSP's vector units. Same answer, a tiny fraction of the
    /// work, and no dependence on the build's optimisation level.
    private func analyze(sampleRate: Double, minFreq: Double, maxFreq: Double, maxLag: Int) {
        let count = windowSize

        // RMS gate — ignore silence / background noise.
        var sumSq: Float = 0
        vDSP_svesq(window, 1, &sumSq, vDSP_Length(count))
        let rms = sqrtf(sumSq / Float(count))
        guard rms > 0.012, sumSq > 0 else { publish(nil); return }

        let minLag = max(1, Int(sampleRate / maxFreq))
        guard maxLag > minLag else { publish(nil); return }

        // ── Coarse search on the decimated window ─────────────────────────────
        let decim = decimation
        var coarseLo = 0
        var coarseHi = -1
        var coarseMax: Float = 0
        if decim > 1 {
            let dCount = count / decim
            coarseLo = max(1, minLag / decim)
            coarseHi = min(dCount - 1, maxLag / decim)
            guard coarseHi > coarseLo else { publish(nil); return }

            window.withUnsafeBufferPointer { src in
                decimated.withUnsafeMutableBufferPointer { dst in
                    vDSP_desamp(src.baseAddress!, vDSP_Stride(decim), decimFilter,
                                dst.baseAddress!, vDSP_Length(dCount), vDSP_Length(decim))
                }
            }
            decimated.withUnsafeBufferPointer { src in
                coarseCorr.withUnsafeMutableBufferPointer { out in
                    let p = src.baseAddress!
                    for lag in coarseLo...coarseHi {
                        var c: Float = 0
                        vDSP_dotpr(p, 1, p + lag, 1, &c, vDSP_Length(dCount - lag))
                        out[lag] = c
                        if c > coarseMax { coarseMax = c }
                    }
                }
            }
            guard coarseMax > 0 else { publish(nil); return }
        }

        // ── Fine search at the full sample rate ───────────────────────────────
        var refinedLag = 0.0
        var bestCorr: Float = 0
        window.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            func corr(_ lag: Int) -> Float {
                var c: Float = 0
                vDSP_dotpr(p, 1, p + lag, 1, &c, vDSP_Length(count - lag))
                return c
            }

            var best = -1
            var bestC: Float = 0
            func score(_ lag: Int) {
                let c = corr(lag)
                if c > bestC { bestC = c; best = lag }
            }

            if decim > 1 {
                // Every *near*-tallest coarse peak gets re-scored, not just the tallest
                // one. Quantising the lag attenuates a peak whose period isn't a whole
                // number of decimated samples, and that alone can leave an exact
                // multiple of it — an octave down — looking taller. Re-scoring the
                // candidates at full rate settles it the same way an undecimated search
                // would.
                var refinements = 0
                for lag in coarseLo...coarseHi {
                    if refinements >= maxRefinements { break }
                    let c = coarseCorr[lag]
                    guard c >= coarseMax * candidateThreshold else { continue }
                    let prev = lag > coarseLo ? coarseCorr[lag - 1] : 0
                    let next = lag < coarseHi ? coarseCorr[lag + 1] : 0
                    guard c >= prev, c >= next else { continue }   // local maximum only
                    let center = lag * decim
                    for l in max(minLag, center - decim)...min(maxLag, center + decim) {
                        score(l)
                    }
                    refinements += 1
                }
            } else {
                for lag in minLag...maxLag { score(lag) }
            }
            guard best > 0 else { return }

            // Sub-sample peak position. Without it the reported pitch steps between
            // whole-sample periods, which on high notes is a sizeable fraction of a
            // semitone and makes the singer's dot twitch.
            var delta = 0.0
            if best > minLag, best < maxLag {
                let cm = Double(corr(best - 1))
                let c0 = Double(bestC)
                let cp = Double(corr(best + 1))
                let denom = cm - 2 * c0 + cp
                if denom < 0 { delta = max(-0.5, min(0.5, 0.5 * (cm - cp) / denom)) }
            }
            refinedLag = Double(best) + delta
            bestCorr = bestC
        }

        guard refinedLag > 0 else { publish(nil); return }
        // Reject weak / noisy peaks by comparing against the signal's own energy.
        guard bestCorr / sumSq > 0.25 else { publish(nil); return }

        let freq = sampleRate / refinedLag
        let midi = 69.0 + 12.0 * log2(freq / 440.0)
        publish(midi)
    }

    private func publish(_ value: Double?) {
        // Store the raw estimate; the view reads & smooths it once per rendered frame.
        os_unfair_lock_lock(&pitchLock)
        _pitch = value
        os_unfair_lock_unlock(&pitchLock)
    }
}
