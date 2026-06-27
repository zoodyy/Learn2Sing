import AVFoundation
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
        if n >= windowSize {
            let offset = n - windowSize
            for i in 0..<windowSize { window[i] = channel[offset + i] }
            filled = windowSize
        } else {
            let keep = windowSize - n
            for i in 0..<keep { window[i] = window[i + n] }
            for i in 0..<n { window[keep + i] = channel[i] }
            filled = min(windowSize, filled + n)
        }

        // Wait until the window holds enough audio to resolve the lowest pitch.
        let minFreq = 65.0     // ~C2
        let maxFreq = 1100.0   // ~C6
        let maxLag = min(windowSize - 1, Int(sampleRate / minFreq))
        guard filled >= maxLag * 2 else { return }

        analyze(sampleRate: sampleRate, minFreq: minFreq, maxFreq: maxFreq, maxLag: maxLag)
    }

    /// Register a clap when this hop's peak rises sharply above the ambient level.
    /// Detection is relative to a slowly tracked noise floor so it adapts to each
    /// microphone's gain (a fixed threshold worked for hot mics like AirPods but
    /// missed quieter built-in mics entirely). The onset is timestamped with the
    /// buffer's own host time so it can be compared against the playback clock.
    private func detectClap(channel: UnsafePointer<Float>, count: Int, time: AVAudioTime) {
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(channel[i])) }

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

    private func analyze(sampleRate: Double, minFreq: Double, maxFreq: Double, maxLag: Int) {
        let count = windowSize

        // RMS gate — ignore silence / background noise.
        var sumSq: Float = 0
        for i in 0..<count { sumSq += window[i] * window[i] }
        let rms = sqrtf(sumSq / Float(count))
        guard rms > 0.012, sumSq > 0 else { publish(nil); return }

        // Autocorrelation over the vocal range.
        let minLag = max(1, Int(sampleRate / maxFreq))
        guard maxLag > minLag else { publish(nil); return }

        var bestLag = -1
        var bestCorr: Float = 0
        window.withUnsafeBufferPointer { buf in
            let p = buf.baseAddress!
            for lag in minLag...maxLag {
                var corr: Float = 0
                let limit = count - lag
                var i = 0
                while i < limit {
                    corr += p[i] * p[i + lag]
                    i += 1
                }
                if corr > bestCorr {
                    bestCorr = corr
                    bestLag = lag
                }
            }
        }

        guard bestLag > 0 else { publish(nil); return }
        // Reject weak / noisy peaks by comparing against the signal's own energy.
        let confidence = bestCorr / sumSq
        guard confidence > 0.25 else { publish(nil); return }

        let freq = sampleRate / Double(bestLag)
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
