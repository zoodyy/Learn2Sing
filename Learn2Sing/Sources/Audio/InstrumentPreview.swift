// The speaker button on the Instruments screen: a short sample — three ascending
// notes — of how one instrument sounds, played by the app's own synthesiser.

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
/// The engine and the audio session are left running between samples so repeated
/// taps start instantly; `stop()` releases them when the screen goes away.
final class InstrumentPreviewPlayer: ObservableObject {
    static let shared = InstrumentPreviewPlayer()

    /// The instrument being heard right now, nil when nothing is sounding; ask
    /// `isPlaying` rather than reading it.
    @Published private(set) var playing: Instrument?

    /// Whether this instrument is the one currently sounding.
    func isPlaying(_ instrument: Instrument) -> Bool {
        playing == instrument
    }

    /// The sample itself: an ascending major triad from middle C, each note held
    /// most of a beat so the three are heard separately.
    private static let bpm = 150.0
    private static let notes = [
        MIDINote(pitch: 60, beat: 0, length: 0.9),
        MIDINote(pitch: 64, beat: 1, length: 0.9),
        MIDINote(pitch: 67, beat: 2, length: 0.9),
    ]

    /// Bumped whenever a sample starts or is stopped, so the "finished" callback of
    /// a sample that has already been replaced can't clear its successor's state.
    private var generation = 0

    private var sessionConfigured = false

    // The app's synthesiser, driven the same way the exercise screen drives it, so
    // the sample sounds exactly like playback will.
    private let synth = ExercisePlayer()
    private var synthStarted = false

    // MARK: Playing

    /// Play an instrument's sample, replacing whatever was sounding.
    func play(_ instrument: Instrument) {
        silence()
        prepareSession()
        if !synthStarted {
            synth.begin()
            synthStarted = true
        }
        synth.setClickMode(false)
        synth.setInstrument(instrument)

        playing = instrument
        let token = generation
        synth.schedule(notes: Self.notes, bpm: Self.bpm, leadIn: 0, preview: false) { [weak self] in
            self?.finish(token)
        }
    }

    /// Stop the sample that is sounding, keeping the engine and the session ready
    /// for the next one.
    private func silence() {
        generation += 1
        synth.cancelAll()
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
        .accessibilityLabel(L("Play Sample"))
    }
}
