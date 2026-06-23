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

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
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
        guard n > 64 else { return }

        // RMS gate — ignore silence / background noise.
        var sumSq: Float = 0
        for i in 0..<n { sumSq += channel[i] * channel[i] }
        let rms = sqrtf(sumSq / Float(n))
        guard rms > 0.012, sumSq > 0 else { publish(nil); return }

        // Autocorrelation over the vocal range.
        let minFreq = 65.0     // ~C2
        let maxFreq = 1100.0   // ~C6
        let minLag = max(1, Int(sampleRate / maxFreq))
        let maxLag = min(n - 1, Int(sampleRate / minFreq))
        guard maxLag > minLag else { publish(nil); return }

        var bestLag = -1
        var bestCorr: Float = 0
        for lag in minLag...maxLag {
            var corr: Float = 0
            let limit = n - lag
            var i = 0
            while i < limit {
                corr += channel[i] * channel[i + lag]
                i += 1
            }
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
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
        DispatchQueue.main.async {
            // Smooth a little in pitch space to steady the indicator.
            if let v = value, let cur = self.midiPitch {
                self.midiPitch = cur * 0.6 + v * 0.4
            } else {
                self.midiPitch = value
            }
        }
    }
}
