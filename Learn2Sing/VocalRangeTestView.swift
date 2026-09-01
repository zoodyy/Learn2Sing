import SwiftUI
import AVFoundation
import Combine

/// Guides the singer through two short holds — the lowest note they can sing, then
/// the highest — listens with the pitch detector, and saves the measured notes as
/// the singer's custom `VocalRange` in Settings. Purely measures the voice; it
/// doesn't change how any exercise plays.
struct VocalRangeTestView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// Called when the test is finished/dismissed, so the caller can pop the stack.
    let onFinish: () -> Void

    @StateObject private var pitchDetector = PitchDetector()
    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""
    @AppStorage(VocalRange.customLowKey)  private var customLow  = VocalRange.customDefault.low
    @AppStorage(VocalRange.customHighKey) private var customHigh = VocalRange.customDefault.high
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: Phase = .lowIntro
    @State private var samples: [Double] = []     // voiced pitches collected this hold
    @State private var voicedTime: Double = 0     // seconds of sustained pitch so far
    @State private var displayPitch: Double? = nil

    @State private var lowMIDI: Double? = nil
    @State private var highMIDI: Double? = nil

    /// Whether the microphone is open — `startListening` has run and `teardown`
    /// hasn't. The screen deliberately holds no audio before that.
    @State private var isListening = false

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
                    title: L("Lowest Note"),
                    instruction: L("When you’re ready, sing the lowest note you can and hold it steadily for 2 seconds."),
                    icon: "arrow.down.circle.fill"
                ) {
                    startListening()
                    beginRecording(.lowRecording)
                }

            case .highIntro:
                intro(
                    title: L("Highest Note"),
                    instruction: L("Now sing the highest note you can and hold it steadily for 2 seconds."),
                    icon: "arrow.up.circle.fill"
                ) {
                    startListening()
                    beginRecording(.highRecording)
                }

            case .lowRecording:
                recording(prompt: L("Sing your lowest note"))

            case .highRecording:
                recording(prompt: L("Sing your highest note"))

            case .result:
                result
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L("Vocal Range Test"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(tick) { _ in collectSample() }
        .onDisappear { teardown() }
        .onChange(of: scenePhase) { _, newPhase in
            // Only once the microphone has been asked for: until "Start" this
            // screen owns no audio, and returning to it mustn't take any.
            guard isListening else { return }
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

    /// Laid out like the slides either side of it in the introduction — icon, title
    /// and instruction centred in what the Start button leaves them, and scrollable
    /// on the short screens, and at the text sizes, where that isn’t enough room.
    private func intro(title: String, instruction: String, icon: String,
                       onStart: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)

                        Text(title)
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)

                        Text(instruction)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }

            Button(action: onStart) {
                Text("Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .explain(L("Starts listening. Sing the note asked for and hold it until the ring has gone all the way round."))
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
                    Text(verbatim: displayPitch.map { pitchName(Int($0.rounded())) } ?? "—")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(displayPitch == nil ? L("Listening…") : L("Hold it"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 220)
            .explain(L("The note the app hears you singing. The ring fills as you hold it, and moves on once it is full."))

            Spacer()

            Text("Keep singing until the ring fills.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var result: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Your Vocal Range")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.secondary)

            if let low = lowMIDI, let high = highMIDI {
                Text(verbatim: "\(pitchName(Int(low.rounded()))) – \(pitchName(Int(high.rounded())))")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.center)
                    .explain(L("The lowest and the highest note you managed. Exercises are moved up or down to fit between them."))
            } else {
                Text(verbatim: "—")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundStyle(.tint)
                    .explain(L("The lowest and the highest note you managed. Exercises are moved up or down to fit between them."))
            }

            Spacer()

            Button {
                if let low = lowMIDI, let high = highMIDI {
                    // Clamp into the note range the Voice settings pickers offer, so
                    // the saved custom range is always selectable there afterwards.
                    customLow  = min(max(Int(low.rounded()), loPitch), hiPitch)
                    customHigh = min(max(Int(high.rounded()), loPitch), hiPitch)
                    vocalRangeRaw = VocalRange.custom.rawValue
                }
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
            .explain(L("Keeps this range as your own, under “Custom” in the Voice settings."))

            Button("Try Again") { restart() }
                .padding(.bottom, 4)
                .explain(L("Throws this result away and runs the test again from the start."))
        }
    }

    // MARK: - Recording logic

    /// Opens the microphone. This is the moment whatever else the phone is
    /// playing stops, which is why it waits for "Start" rather than happening as
    /// the screen appears: music the singer had on keeps playing while they read
    /// what they are being asked to do. Idempotent — the second hold is sung on
    /// the session the first one opened.
    private func startListening() {
        guard !isListening else { return }
        isListening = true
        AudioRouteManager.shared.configureSession()
        pitchDetector.start()
    }

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

    /// Gives the microphone back. Nothing to give back when the test is left
    /// before it is started, and deactivating a session this screen never
    /// activated would disturb whatever else is holding one.
    private func teardown() {
        guard isListening else { return }
        isListening = false
        pitchDetector.stop()
        AudioRouteManager.shared.deactivateSession()
    }
}
