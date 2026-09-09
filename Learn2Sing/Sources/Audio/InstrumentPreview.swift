// The speaker button on the Instruments screen: a short sample — three ascending
// notes — of how one instrument sounds. Built-in instruments are played by the
// app's own synthesiser; a custom one is its recording, resampled to each note.

import SwiftUI
import Combine
import AVFoundation

// MARK: - Sample decoding

/// Decode an audio file into a mono sample buffer at `sampleRate`, so it can be
/// mixed straight into the engine. Returns nil if the file is missing or can't be
/// decoded.
func monoSamples(at url: URL, sampleRate: Double) -> [Float]? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }

    let inFormat = file.processingFormat
    let inFrames = AVAudioFrameCount(file.length)
    guard inFrames > 0,
          let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames),
          (try? file.read(into: inBuffer)) != nil else { return nil }

    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate, channels: 1,
                                        interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }
    let outCapacity = AVAudioFrameCount(Double(inFrames) * sampleRate / inFormat.sampleRate) + 1024
    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }

    var supplied = false
    var error: NSError?
    converter.convert(to: outBuffer, error: &error) { _, status in
        if supplied { status.pointee = .noDataNow; return nil }
        supplied = true
        status.pointee = .haveData
        return inBuffer
    }
    guard error == nil, let channel = outBuffer.floatChannelData else { return nil }

    let n = Int(outBuffer.frameLength)
    var samples = [Float](repeating: 0, count: n)
    for i in 0..<n { samples[i] = channel[0][i] }
    return samples
}

// MARK: - Preview player

/// Plays the instrument samples, one at a time: starting a sample stops whatever
/// was still sounding, so the screen never plays two instruments at once.
///
/// The engines and the audio session are left running between samples so repeated
/// taps start instantly; `stop()` releases them when the screen goes away.
final class InstrumentPreviewPlayer: ObservableObject {
    static let shared = InstrumentPreviewPlayer()

    /// The instrument being heard right now, identified the way the selection is
    /// stored — `Instrument.rawValue` for a built-in, `selectionTag` for an uploaded
    /// one. nil when nothing is sounding; ask `isPlaying` rather than reading it.
    @Published private(set) var playing: String?

    /// Whether this instrument is the one currently sounding.
    func isPlaying(_ instrument: Instrument) -> Bool {
        playing == instrument.rawValue
    }

    func isPlaying(_ instrument: CustomInstrument) -> Bool {
        playing == CustomInstrumentStore.selectionTag(instrument.id)
    }

    /// The sample itself: an ascending major triad from middle C, each note held
    /// most of a beat so the three are heard separately.
    private static let bpm = 150.0
    private static let notes = [
        MIDINote(pitch: 60, beat: 0, length: 0.9),
        MIDINote(pitch: 64, beat: 1, length: 0.9),
        MIDINote(pitch: 67, beat: 2, length: 0.9),
    ]

    private static let sampleRate = 44100.0

    /// Bumped whenever a sample starts or is stopped, so the "finished" callback of
    /// a sample that has already been replaced can't clear its successor's state.
    private var generation = 0

    private var sessionConfigured = false

    // Built-in instruments: the app's synthesiser, driven the same way the exercise
    // screen drives it, so the sample sounds exactly like playback will.
    private let synth = ExercisePlayer()
    private var synthStarted = false

    // Custom instruments: the recording resampled to each note ahead of time and
    // played as one prepared buffer.
    private var sampleEngine: AVAudioEngine?
    private var sampleNode: AVAudioPlayerNode?

    /// The most recently decoded recording, so tapping the same row again doesn't
    /// decode the file over: only one is kept, since samples are played one at a time.
    private var decoded: (id: UUID, samples: [Float])?

    // MARK: Playing

    /// Play a built-in instrument's sample, replacing whatever was sounding.
    func play(_ instrument: Instrument) {
        silence()
        prepareSession()
        if !synthStarted {
            synth.begin()
            synthStarted = true
        }
        synth.setClickMode(false)
        synth.setInstrument(instrument)

        playing = instrument.rawValue
        let token = generation
        synth.schedule(notes: Self.notes, bpm: Self.bpm, leadIn: 0, preview: false) { [weak self] in
            self?.finish(token)
        }
    }

    /// Play an uploaded instrument's sample, replacing whatever was sounding. The
    /// decoding and resampling happen off the main thread so a long recording can't
    /// stall the list; if the file has gone missing or won't decode, nothing plays.
    func play(_ instrument: CustomInstrument) {
        silence()
        playing = CustomInstrumentStore.selectionTag(instrument.id)

        let token = generation
        let id = instrument.id
        let url = CustomInstrumentStore.shared.url(for: instrument)
        let baseFrequency = instrument.baseFrequency
        let cached = decoded?.id == id ? decoded?.samples : nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let samples = cached ?? monoSamples(at: url, sampleRate: Self.sampleRate)
            var buffer: AVAudioPCMBuffer?
            if let samples {
                buffer = Self.render(samples: samples, baseFrequency: baseFrequency)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                if let samples { self.decoded = (id, samples) }
                guard let buffer else { self.playing = nil; return }
                self.start(buffer, token: token)
            }
        }
    }

    /// Stop the sample that is sounding, keeping the engines and the session ready
    /// for the next one.
    private func silence() {
        generation += 1
        synth.cancelAll()
        sampleNode?.stop()
        playing = nil
    }

    /// Stop everything and release the audio session. Called when the instruments
    /// screen goes away, so no engine is left running behind it.
    func stop() {
        silence()
        if synthStarted {
            synth.stop()
            synthStarted = false
        }
        if let sampleEngine, sampleEngine.isRunning { sampleEngine.stop() }
        decoded = nil   // a recording can be megabytes; decode it again next time
        if sessionConfigured {
            AudioRouteManager.shared.deactivateSession()
            sessionConfigured = false
        }
    }

    /// Clear the "playing" state once a sample has finished — unless another has
    /// started since, in which case that one owns the state now.
    private func finish(_ token: Int) {
        guard generation == token else { return }
        playing = nil
    }

    /// Take the audio session before the first sample, and keep it until `stop()` so
    /// later samples start immediately.
    private func prepareSession() {
        guard !sessionConfigured else { return }
        AudioRouteManager.shared.configurePlaybackSession()
        sessionConfigured = true
    }

    // MARK: Custom instrument playback

    /// Start a prepared sample buffer on the playback node.
    private func start(_ buffer: AVAudioPCMBuffer, token: Int) {
        prepareSession()
        guard let node = prepareSampleEngine(format: buffer.format) else {
            playing = nil
            return
        }
        node.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.finish(token) }
        }
        node.play()
    }

    /// The player node, with its engine built on first use and restarted if the
    /// system has torn its IO down since the last sample.
    private func prepareSampleEngine(format: AVAudioFormat) -> AVAudioPlayerNode? {
        if sampleEngine == nil {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            sampleEngine = engine
            sampleNode = node
        }
        guard let engine = sampleEngine, let node = sampleNode else { return nil }
        if !engine.isRunning {
            engine.prepare()
            guard (try? engine.start()) != nil else { return nil }
        }
        return node
    }

    /// Render the three notes of the sample into one buffer: each note is the
    /// recording read back at the ratio between the note's frequency and the
    /// recording's own pitch — reading it faster raises it, slower lowers it — cut to
    /// the note's length with a short ring-out, and fades at both ends so a recording
    /// that doesn't start or stop at silence can't click.
    private static func render(samples: [Float], baseFrequency: Double) -> AVAudioPCMBuffer? {
        guard baseFrequency > 0, samples.count > 1 else { return nil }

        let secPerBeat = 60.0 / bpm
        let attack = Int(0.005 * sampleRate)
        let ringOut = Int(0.15 * sampleRate)
        let lastBeat = notes.map { $0.beat + $0.length }.max() ?? 0
        let total = Int(lastBeat * secPerBeat * sampleRate) + ringOut + attack
        guard total > 0 else { return nil }

        var mix = [Float](repeating: 0, count: total)
        for note in notes {
            let ratio = noteFrequency(Double(note.pitch)) / baseFrequency
            let start = Int(note.beat * secPerBeat * sampleRate)
            let length = min(Int(note.length * secPerBeat * sampleRate) + ringOut, total - start)
            guard length > 0 else { continue }

            var position = 0.0
            for i in 0..<length {
                let index = Int(position)
                guard index + 1 < samples.count else { break }   // the recording ran out
                let frac = Float(position - Double(index))
                var value = samples[index] * (1 - frac) + samples[index + 1] * frac
                if i < attack { value *= Float(i) / Float(attack) }
                let remaining = length - i
                if remaining < ringOut { value *= Float(remaining) / Float(ringOut) }
                mix[start + i] += value * sampleGain
                position += ratio
            }
        }
        for i in 0..<total { mix[i] = tanhf(mix[i]) }   // soft-clip, as the synth does

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(total)),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(total)
        mix.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: total) }
        return buffer
    }

    /// Output level of a resampled recording, leaving headroom for the overlap
    /// between one note's ring-out and the next note.
    private static let sampleGain: Float = 0.8
}

// MARK: - The button

/// The speaker button on an instrument row: plays that instrument's sample, and
/// animates while it is the one being heard.
struct InstrumentSampleButton: View {
    let isPlaying: Bool
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            Image(systemName: "speaker.wave.2.fill")
                .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                .foregroundStyle(.tint)
                // A tap target of its own, so it isn't a pixel-hunt next to the row.
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        // Without this the row's own button swallows the tap and the sample never plays.
        .buttonStyle(.borderless)
        .accessibilityLabel(L("Play sample"))
    }
}
