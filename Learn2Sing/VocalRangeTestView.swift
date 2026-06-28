import SwiftUI
import AVFoundation
import Combine

/// Guides the singer through two short holds — the lowest note they can sing, then
/// the highest — listens with the pitch detector, and classifies the result into a
/// `VocalRange` which it writes to Settings. Purely measures the voice; it doesn't
/// change how any exercise plays.
struct VocalRangeTestView: View {
    /// Called when the test is finished/dismissed, so the caller can pop the stack.
    let onFinish: () -> Void

    @StateObject private var pitchDetector = PitchDetector()
    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: Phase = .lowIntro
    @State private var samples: [Double] = []     // voiced pitches collected this hold
    @State private var voicedTime: Double = 0     // seconds of sustained pitch so far
    @State private var displayPitch: Double? = nil

    @State private var lowMIDI: Double? = nil
    @State private var highMIDI: Double? = nil

    /// Seconds of sustained voice required to lock in a note.
    private let holdDuration = 2.0
    private let pollInterval = 0.05
    /// Plausible sung MIDI range; readings outside it are ignored as detector noise.
    private let plausible = 28.0...95.0

    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    private enum Phase {
        case lowIntro, lowRecording
        case highIntro, highRecording
        case result
    }

    var body: some View {
        VStack {
            switch phase {
            case .lowIntro:
                intro(
                    title: "Lowest Note",
                    instruction: "When you’re ready, sing the lowest note you can and hold it steadily for 2 seconds.",
                    icon: "arrow.down.circle.fill"
                ) { beginRecording(.lowRecording) }

            case .highIntro:
                intro(
                    title: "Highest Note",
                    instruction: "Now sing the highest note you can and hold it steadily for 2 seconds.",
                    icon: "arrow.up.circle.fill"
                ) { beginRecording(.highRecording) }

            case .lowRecording:
                recording(prompt: "Sing your lowest note")

            case .highRecording:
                recording(prompt: "Sing your highest note")

            case .result:
                result
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Vocal Range Test")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { _ in collectSample() }
        .onAppear {
            AudioRouteManager.shared.configureSession()
            pitchDetector.start()
        }
        .onDisappear { teardown() }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                AudioRouteManager.shared.configureSession()
                pitchDetector.start()
            case .background:
                pitchDetector.stop()
            default:
                break
            }
        }
    }

    // MARK: - Subviews

    private func intro(title: String, instruction: String, icon: String,
                       onStart: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: icon)
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)

                    Text(title)
                        .font(.largeTitle.weight(.bold))

                    Text(instruction)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onStart) {
                Text("Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        }
    }

    private func recording(prompt: String) -> some View {
        VStack(spacing: 32) {
            Spacer()

            Text(prompt)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.25), lineWidth: 12)

                Circle()
                    .trim(from: 0, to: min(1, voicedTime / holdDuration))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: pollInterval), value: voicedTime)

                VStack(spacing: 4) {
                    Text(displayPitch.map { pitchName(Int($0.rounded())) } ?? "—")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(displayPitch == nil ? "Listening…" : "Hold it")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)

            Spacer()

            Text("Keep singing until the ring fills.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var result: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Your Voice Type")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(classifiedRange?.rawValue ?? "—")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(.tint)
                .multilineTextAlignment(.center)

            if let low = lowMIDI, let high = highMIDI {
                Text("Measured range: \(pitchName(Int(low.rounded()))) – \(pitchName(Int(high.rounded())))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                if let range = classifiedRange { vocalRangeRaw = range.rawValue }
                teardown()
                onFinish()
            } label: {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }

            Button("Try Again") { restart() }
                .padding(.bottom, 4)
        }
    }

    private var classifiedRange: VocalRange? {
        guard let low = lowMIDI, let high = highMIDI else { return nil }
        return VocalRange.classify(lowMIDI: low, highMIDI: high)
    }

    // MARK: - Recording logic

    private func beginRecording(_ next: Phase) {
        samples = []
        voicedTime = 0
        displayPitch = nil
        phase = next
    }

    /// One poll of the microphone while a hold is in progress: show the live note,
    /// and accumulate sustained voiced time until the hold completes.
    private func collectSample() {
        guard phase == .lowRecording || phase == .highRecording else { return }

        let pitch = pitchDetector.currentPitch
        displayPitch = pitch

        guard let pitch, plausible.contains(pitch) else { return }
        samples.append(pitch)
        voicedTime += pollInterval

        guard voicedTime >= holdDuration else { return }
        finishHold()
    }

    /// Lock in the held note (the median of the collected samples, robust against
    /// brief octave glitches) and advance to the next step.
    private func finishHold() {
        let note = median(samples)
        if phase == .lowRecording {
            lowMIDI = note
            phase = .highIntro
        } else {
            highMIDI = note
            // Guard against the two holds landing in the wrong order (e.g. an octave
            // error) so the classification always sees low ≤ high.
            if let low = lowMIDI, let high = highMIDI, low > high {
                lowMIDI = high
                highMIDI = low
            }
            phase = .result
        }
        samples = []
        voicedTime = 0
        displayPitch = nil
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func restart() {
        lowMIDI = nil
        highMIDI = nil
        beginRecording(.lowIntro)
    }

    private func teardown() {
        pitchDetector.stop()
        AudioRouteManager.shared.deactivateSession()
    }
}
