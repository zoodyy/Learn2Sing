import AVFoundation
import Combine

/// Listens to the microphone and estimates the fundamental frequency the user is
/// singing, published as a (possibly fractional) MIDI note number. Uses a simple
/// autocorrelation pitch tracker over the vocal range — light enough to run in the
/// input tap callback.
final class PitchDetector: ObservableObject {
    /// Detected pitch as a fractional MIDI note number, or `nil` when silent / unsure.
    @Published var midiPitch: Double? = nil

    private let engine = AVAudioEngine()
    private var running = false

    // Each mic hop is tiny (low latency / fast refresh), but pitch detection needs
    // a longer span to resolve low notes — so hops are accumulated into this ring
    // buffer and autocorrelation runs over the whole retained window.
    private let hopSize: AVAudioFrameCount = 256
    private let windowSize = 2048
    private var window = [Float](repeating: 0, count: 2048)
    private var filled = 0

    func start() {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        // Record + playback so the exercise audio still plays through the speaker.
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .mixWithOthers])
        try? session.setActive(true)

        session.requestRecordPermission { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.beginTap() }
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        DispatchQueue.main.async { self.midiPitch = nil }
    }

    private func beginTap() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return }

        filled = 0
        input.removeTap(onBus: 0)
        // Tiny hop so a fresh estimate lands very frequently; the view interpolates
        // between estimates so the indicator still moves every rendered frame.
        input.installTap(onBus: 0, bufferSize: hopSize, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer, sampleRate: sampleRate)
        }
        engine.prepare()
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private func process(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

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
        // Publish the raw estimate; the view smooths/interpolates it per frame.
        DispatchQueue.main.async { self.midiPitch = value }
    }
}
