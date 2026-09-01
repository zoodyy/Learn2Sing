import SwiftUI
import UIKit

/// The run that has just finished, frozen: the exercise drawn exactly as the
/// playback screen draws it, with the singer's whole pitch line laid over it so
/// they can see where they were sharp, flat or late. Nothing moves and nothing
/// sounds — the playhead is a fixed cursor that the content is dragged past.
/// One finger scrolls; a pinch zooms the axis the fingers are arranged along.
///
/// The line drawn is the one the score was computed from, so it is shifted
/// earlier by the microphone-delay setting: scoring treats the notes as sounding
/// that much later than they are drawn, which is the same comparison as putting
/// the detected pitch that much further left (see `micDelayBeats`).
///
/// The same screen is the last step of the sung microphone-delay test (Settings ▸
/// Audio ▸ Test for delay), and of the first run a singer scores anything on (see
/// `MicDelayCalibration`). There `onCalibrationDone` is set: the shift is no
/// longer the saved setting but an offset the singer dials in with the controls
/// along the bottom, sliding their whole line over the notes until it lines up,
/// and Done hands that offset back to be saved as the new microphone delay.
struct ExerciseReviewView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let exercise: Exercise
    /// The notes and labels as they were played — already expanded over the
    /// repetitions and transposed, so they sit where the singer saw them.
    let notes: [MIDINote]
    let texts: [MIDIText]
    /// Every pitch estimate of the run, oldest first, at the beat it was heard.
    let samples: [PitchSample]
    let bpm: Double
    /// Where the repetitions sit on the timeline, for the repetition counter badge.
    let repeatLayout: RepeatLayout
    /// Set when this screen is a microphone-delay calibration rather than a look
    /// back: the offset controls appear along the bottom and Done hands the offset
    /// the singer settled on (in milliseconds) back to be saved. nil elsewhere, where
    /// the screen is a plain look at the run just scored.
    var onCalibrationDone: ((Double) -> Void)? = nil
    let onClose: () -> Void

    @AppStorage(microphoneDelayKey) private var micDelayMs = 0.0
    @State private var visuals = VisualSettings.current

    /// How far the sung line is shifted while the calibration controls are up, in
    /// milliseconds. nil until the first nudge, so the line starts out exactly where
    /// the saved setting puts it and the singer adjusts from there.
    @State private var calibrationMs: Double? = nil

    /// Milliseconds the sung line is drawn earlier than it was recorded: the offset
    /// being dialled in during the delay test, otherwise the saved setting.
    private var delayMs: Double { calibrationMs ?? micDelayMs }

    /// Where the view is looking. `nil` until the singer moves it: the drawing
    /// falls back to the framing worked out from the screen size, so the very
    /// first frame is already pointed at the exercise without this screen having
    /// to write any state before it can draw.
    private struct Camera {
        /// Beat drawn at the playhead line, and the MIDI pitch drawn at the
        /// vertical centre.
        var playheadBeat: Double
        var centerPitch: Double
        /// Zoom the pinch has applied on top of the saved zoom settings, so an
        /// untouched review is framed exactly as playback was.
        var horizontalZoom: Double = 1
        var verticalZoom: Double = 1
    }
    @State private var camera: Camera? = nil

    /// Full-screen size of the canvas, so the gesture handlers can do the same
    /// layout maths the drawing does. Only ever read by them — the drawing takes
    /// the size it is handed.
    @State private var canvasSize: CGSize = .zero

    /// What the bars along the top and bottom cover, for the same reason: the
    /// drawing is handed the insets belonging to the frame it is drawing, and only
    /// the gesture handlers read this copy.
    @State private var safeArea = EdgeInsets()

    // Navigation-bar metrics for placing the top of the playhead line, matching
    // the playback screen's.
    private let navBarHeight: CGFloat = 54
    private let barButtonHeight: CGFloat = 44

    /// Zoom bounds, as points per beat and points per semitone: far enough out to
    /// take in a long exercise at a glance, far enough in to read a single note's
    /// wobble.
    private let beatWidthRange: ClosedRange<CGFloat> = 6...400
    private let rowHeightRange: ClosedRange<CGFloat> = 3...90

    var body: some View {
        GeometryReader { geo in
            // The canvas ignores the safe area, so it is the whole screen rather
            // than the size the GeometryReader reports.
            let canvas = CGSize(
                width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom)
            ZStack {
                Canvas { ctx, size in
                    draw(ctx: ctx, size: size,
                         safeTop: geo.safeAreaInsets.top, safeBottom: geo.safeAreaInsets.bottom)
                }
                PanZoomSurface(onPan: pan(by:), onPinch: zoom(by:axis:around:))
            }
            .ignoresSafeArea()
            .explain(L("The whole exercise with the pitch you sang drawn over it. Drag to move around, pinch to zoom."))
            .onAppear {
                canvasSize = canvas
                safeArea = geo.safeAreaInsets
            }
            .onChange(of: canvas) { _, size in canvasSize = size }
            .onChange(of: geo.safeAreaInsets) { _, insets in safeArea = insets }
        }
        // An inset rather than an overlay, so the drawing knows the bar is there and
        // keeps the repetition badge above it. The canvas underneath still ignores
        // the safe area, so nothing about the framing changes.
        .safeAreaInset(edge: .bottom) {
            if onCalibrationDone != nil { calibrationControls }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(exercise.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        // Leaving goes back to the score, not out of the exercise (and out of the
        // delay test, which has no score behind it), so the system's own back button
        // — which would pop the whole run — is replaced.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(L("Back"))
                .explain(L("Goes back to where you came from, leaving the exercise as it is."))
            }
            if let onCalibrationDone {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onCalibrationDone(delayMs.rounded()) }
                        .fontWeight(.semibold)
                        .explain(L("Saves the offset below as your microphone delay and closes the test."))
                }
            }
        }
    }

    // MARK: - Delay-test controls

    /// How far one tap moves the sung line, in milliseconds. The coarse pair crosses
    /// the range a microphone can plausibly lag by in a handful of taps; the fine pair
    /// is for settling on the value once the line is roughly over the notes.
    private let coarseStepMs: Double = 50
    private let fineStepMs: Double = 1

    /// How often a held-down button takes its next step. Set so the two pairs travel
    /// at speeds that suit what they're for: the coarse one covers the whole range in
    /// a few seconds, the fine one creeps along under the singer's eye.
    private let coarseRepeat: Duration = .milliseconds(120)
    private let fineRepeat: Duration = .milliseconds(35)

    /// What the offset may be dialled to. It compensates for a lag, so it can't run
    /// backwards; the top end is far past any real microphone's round trip.
    private let delayRangeMs: ClosedRange<Double> = 0...2000

    /// Move the sung line by `ms`: positive shifts it earlier (to the left), which is
    /// exactly what a larger microphone delay means.
    private func nudge(_ ms: Double) {
        calibrationMs = min(max(delayMs + ms, delayRangeMs.lowerBound), delayRangeMs.upperBound)
    }

    /// The bar a microphone-delay calibration is finished on: the offset either side
    /// of the value it currently stands at. The line is dragged past the notes with
    /// the same one-finger scroll as any review, so these move the line *against* the
    /// notes rather than moving the view.
    private var calibrationControls: some View {
        VStack(spacing: 10) {
            Text("Line your singing up with the notes, then tap Done.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 8) {
                NudgeButton(ms: coarseStepMs, symbol: "chevron.left.2",
                            repeatEvery: coarseRepeat, onStep: nudge)
                NudgeButton(ms: fineStepMs, symbol: "chevron.left",
                            repeatEvery: fineRepeat, onStep: nudge)

                Text(L("%d ms", Int(delayMs.rounded())))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .frame(minWidth: 76)
                    .explain(L("How far your singing is being moved to line it up. The arrows shift it: the double ones in big steps, the single ones a millisecond at a time."))

                NudgeButton(ms: -fineStepMs, symbol: "chevron.right",
                            repeatEvery: fineRepeat, onStep: nudge)
                NudgeButton(ms: -coarseStepMs, symbol: "chevron.right.2",
                            repeatEvery: coarseRepeat, onStep: nudge)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        // Solid, and carried on down through the home-indicator strip: the scene
        // behind is always black whatever theme the app is in, so a translucent bar
        // would leave the pitch names at its edge showing through the controls.
        .background {
            Rectangle().fill(.black).ignoresSafeArea(edges: .bottom)
        }
        // Hairline against the scene, so the bar reads as chrome rather than as part
        // of the drawing the notes are scrolled through.
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5)
        }
    }

    // MARK: - Layout

    private var keyboardWidth: CGFloat { visuals.showKeyboard ? playbackKeyboardWidth : 0 }

    private func playheadX(size: CGSize) -> CGFloat { size.width / 3 }

    private func beatWidth(zoom: Double) -> CGFloat {
        playbackBeatWidth * CGFloat(visuals.horizontalZoom * zoom)
    }

    private func rowHeight(size: CGSize, zoom: Double) -> CGFloat {
        size.height / CGFloat(hiPitch - loPitch + 1) * CGFloat(visuals.verticalZoom * zoom)
    }

    private func sceneLayout(size: CGSize, camera: Camera,
                             safeTop: CGFloat, safeBottom: CGFloat) -> SceneLayout {
        SceneLayout(size: size, pianoW: keyboardWidth,
                    rowH: rowHeight(size: size, zoom: camera.verticalZoom),
                    beatPx: beatWidth(zoom: camera.horizontalZoom),
                    playheadX: playheadX(size: size), centerPitch: camera.centerPitch,
                    centerY: centerY(height: size.height, safeTop: safeTop, safeBottom: safeBottom))
    }

    /// Screen y the camera's centre pitch is drawn at: the middle of what the bars
    /// leave visible, rather than the middle of the canvas — which on the delay test
    /// sits partly behind the offset controls. It is the point the vertical limits
    /// are expressed in, so this is what "brought to the middle" means for a note.
    private func centerY(height: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) -> CGFloat {
        (height + safeTop - safeBottom) / 2
    }

    /// Y at which the playhead line starts: the gap the navigation bar leaves
    /// below its buttons, so the line doesn't run up behind them.
    private func playheadTop(safeTop: CGFloat) -> CGFloat {
        max(0, safeTop - (navBarHeight - barButtonHeight))
    }

    // MARK: - Drawing

    private func draw(ctx: GraphicsContext, size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
        let cam = resolvedCamera(size: size)
        let layout = sceneLayout(size: size, camera: cam, safeTop: safeTop, safeBottom: safeBottom)
        let beat = cam.playheadBeat
        let delay = micDelayBeats(delayMs, bpm: bpm)

        // The sung line, shifted earlier by the microphone delay so it lies where
        // the scorer compared it against the notes. Only the stretch that can land
        // on screen becomes path segments: a run records a sample per rendered
        // frame, which is tens of thousands of points for a long exercise. The
        // margin either side keeps the segments that cross the edges.
        let margin = 2.0
        let leftBeat = beat + Double((layout.pianoW - layout.playheadX) / layout.beatPx) - margin
        let rightBeat = beat + Double((size.width - layout.playheadX) / layout.beatPx) + margin
        let r = min(layout.rowH * 0.85, 11)
        var trailPath = Path()
        var penDown = false
        for sample in samples {
            let sampleBeat = sample.beat - delay
            if sampleBeat < leftBeat { continue }
            if sampleBeat > rightBeat { break }
            guard let pitch = sample.pitch else { penDown = false; continue }
            // Clamped to the canvas exactly as the live view clamps it, so a note
            // sung far out of view shows up pinned to the edge rather than missing.
            let y = min(max(layout.y(pitch), r), size.height - r)
            let pt = CGPoint(x: layout.x(sampleBeat, beat: beat), y: y)
            if penDown { trailPath.addLine(to: pt) } else { trailPath.move(to: pt); penDown = true }
        }

        // Which repetition the cursor is sitting in, for the optional badge — the
        // same rule the live view uses.
        let totalReps = max(1, exercise.repeatCount)
        var repetition: (current: Int, total: Int)? = nil
        if totalReps > 1, repeatLayout.count > 0 {
            let idx = min(totalReps - 1, repeatLayout.index(at: beat))
            repetition = (current: idx + 1, total: totalReps)
        }

        drawPlaybackScene(ctx: ctx, layout: layout, beat: beat, notes: notes, texts: texts,
                          trailPath: trailPath, singerPitch: pitch(at: beat), settings: visuals,
                          repetition: repetition, safeTop: safeTop, safeBottom: safeBottom,
                          playheadTop: playheadTop(safeTop: safeTop), repeatLayout: repeatLayout)
    }

    /// The pitch recorded at `beat`, so the singer indicator sits on the line right
    /// under the cursor. `nil` where the run has no sample near that beat — the
    /// singer was silent there, or the cursor is past the end of the run.
    private func pitch(at beat: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        // Back into the recording's own timeline: the line is drawn `delay` beats
        // to the left of where its samples were taken.
        let target = beat + micDelayBeats(delayMs, bpm: bpm)

        // The samples are in the order they were recorded and the playback clock
        // never runs backwards, so they're sorted by beat and can be searched.
        var lo = 0
        var hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].beat < target { lo = mid + 1 } else { hi = mid }
        }
        var nearest = samples[lo]
        if lo > 0, abs(samples[lo - 1].beat - target) < abs(nearest.beat - target) {
            nearest = samples[lo - 1]
        }
        guard abs(nearest.beat - target) < 0.1 else { return nil }
        return nearest.pitch
    }

    // MARK: - Camera

    /// The camera to draw with: whatever the singer has scrolled to, or the
    /// opening framing, and either way kept over the content — so a rotation that
    /// changes what fits on screen can't leave the view stranded off the end.
    private func resolvedCamera(size: CGSize) -> Camera {
        resolvedCamera(size: size, content: measureContent())
    }

    private func resolvedCamera(size: CGSize, content: Content) -> Camera {
        var cam = camera ?? framedCamera(size: size, content: content)
        clamp(&cam, content: content)
        return cam
    }

    /// The opening view: the first note against the left edge of the note area
    /// (rather than the silent lead-in the recording also covers), centred on the
    /// notes' own pitch range — a stray label or a stray detected pitch shouldn't
    /// be what decides where the review starts.
    private func framedCamera(size: CGSize, content: Content) -> Camera {
        let pitches = notes.map(\.pitch)
        let center: Double
        if let low = pitches.min(), let high = pitches.max() {
            center = Double(low + high) / 2
        } else {
            center = (content.pitches.lowerBound + content.pitches.upperBound) / 2
        }
        let firstNote = notes.map(\.beat).min() ?? content.beats.lowerBound
        let playhead = firstNote
            + Double((playheadX(size: size) - keyboardWidth) / beatWidth(zoom: 1))
        return Camera(playheadBeat: playhead, centerPitch: center)
    }

    /// How far the drawn content reaches, as the camera limits.
    private struct Content {
        /// The stretch the playhead may travel, so every note and every part of the
        /// sung line can be brought under it. Each end is whichever of the two — the
        /// exercise or the line — reaches further.
        var beats: ClosedRange<Double>
        /// The pitches the camera's centre may travel between, on the same footing:
        /// anything drawn — a note, a label, any point of the sung line — can be
        /// brought to the middle of the screen, where no bar is covering it.
        var pitches: ClosedRange<Double>
    }

    /// Measures those limits. Samples with no detected pitch don't count towards
    /// the line's ends: it only starts where the singer did, not at the silent
    /// lead-in the recording also covers.
    private func measureContent() -> Content {
        let delay = micDelayBeats(delayMs, bpm: bpm)
        var firstBeat = Double.infinity
        var lastBeat = -Double.infinity
        for note in notes {
            firstBeat = min(firstBeat, note.beat)
            lastBeat = max(lastBeat, note.beat + note.length)
        }
        for label in texts {
            firstBeat = min(firstBeat, label.centreBeat)
            lastBeat = max(lastBeat, label.centreBeat)
        }
        if let sung = samples.first(where: { $0.pitch != nil }) {
            firstBeat = min(firstBeat, sung.beat - delay)
        }
        if let sung = samples.last(where: { $0.pitch != nil }) {
            lastBeat = max(lastBeat, sung.beat - delay)
        }
        if firstBeat > lastBeat { firstBeat = 0; lastBeat = 0 }   // nothing drawn at all

        var lowPitch = Double.infinity
        var highPitch = -Double.infinity
        for note in notes {
            lowPitch = min(lowPitch, Double(note.pitch))
            highPitch = max(highPitch, Double(note.pitch))
        }
        for label in texts {
            lowPitch = min(lowPitch, Double(label.pitch))
            highPitch = max(highPitch, Double(label.pitch))
        }
        // The sung line counts too, so a passage sung well outside the exercise's own
        // range can be brought into view instead of only ever being pinned to an edge.
        for sample in samples {
            guard let pitch = sample.pitch else { continue }
            lowPitch = min(lowPitch, pitch)
            highPitch = max(highPitch, pitch)
        }
        if lowPitch > highPitch {
            lowPitch = Double(hiPitch + loPitch) / 2
            highPitch = lowPitch
        }
        return Content(beats: firstBeat...lastBeat, pitches: lowPitch...highPitch)
    }

    /// A one-finger drag: the content follows the finger on both axes.
    private func pan(by delta: CGSize) {
        let size = canvasSize
        guard size.width > 0, size.height > 0 else { return }
        let content = measureContent()
        var cam = resolvedCamera(size: size, content: content)
        cam.playheadBeat -= Double(delta.width / beatWidth(zoom: cam.horizontalZoom))
        cam.centerPitch += Double(delta.height / rowHeight(size: size, zoom: cam.verticalZoom))
        clamp(&cam, content: content)
        camera = cam
    }

    /// A pinch along one axis, keeping whatever is under the fingers' midpoint
    /// where it is so the content doesn't slide out from under them.
    private func zoom(by factor: CGFloat, axis: Axis, around point: CGPoint) {
        let size = canvasSize
        guard size.width > 0, size.height > 0, factor > 0 else { return }
        let content = measureContent()
        var cam = resolvedCamera(size: size, content: content)
        switch axis {
        case .horizontal:
            let offset = point.x - playheadX(size: size)
            let anchorBeat = cam.playheadBeat + Double(offset / beatWidth(zoom: cam.horizontalZoom))
            cam.horizontalZoom = clampedHorizontalZoom(cam.horizontalZoom * Double(factor))
            cam.playheadBeat = anchorBeat - Double(offset / beatWidth(zoom: cam.horizontalZoom))
        case .vertical:
            let offset = point.y - centerY(height: size.height,
                                           safeTop: safeArea.top, safeBottom: safeArea.bottom)
            let anchorPitch = cam.centerPitch
                - Double(offset / rowHeight(size: size, zoom: cam.verticalZoom))
            cam.verticalZoom = clampedVerticalZoom(cam.verticalZoom * Double(factor), size: size)
            cam.centerPitch = anchorPitch
                + Double(offset / rowHeight(size: size, zoom: cam.verticalZoom))
        }
        clamp(&cam, content: content)
        camera = cam
    }

    private func clampedHorizontalZoom(_ zoom: Double) -> Double {
        let base = beatWidth(zoom: 1)
        guard base > 0 else { return zoom }
        return min(max(zoom, Double(beatWidthRange.lowerBound / base)),
                   Double(beatWidthRange.upperBound / base))
    }

    private func clampedVerticalZoom(_ zoom: Double, size: CGSize) -> Double {
        let base = rowHeight(size: size, zoom: 1)
        guard base > 0 else { return zoom }
        return min(max(zoom, Double(rowHeightRange.lowerBound / base)),
                   Double(rowHeightRange.upperBound / base))
    }

    /// Keeps the camera over the content. Both limits are on the camera itself —
    /// the playhead across, its centre pitch down — rather than on the visible
    /// window: those two are what the singer reads the run with, so everything
    /// drawn has to be able to reach them. That is also what makes each note and
    /// each part of the sung line reachable at all when a bar is covering the foot
    /// of the screen; a limit on the window instead would let a high exercise's
    /// lowest notes stop under it with nowhere further to scroll.
    private func clamp(_ cam: inout Camera, content: Content) {
        cam.playheadBeat = min(max(cam.playheadBeat, content.beats.lowerBound),
                               content.beats.upperBound)
        cam.centerPitch = min(max(cam.centerPitch, content.pitches.lowerBound),
                              content.pitches.upperBound)
    }
}

// MARK: - Delay-test offset button

/// One of the four buttons that slide the sung line over the notes in the delay
/// test. A tap moves it one step; holding the button down keeps it moving, a step
/// every `repeatEvery`, until the finger is lifted — so a long way is covered
/// without tapping a hundred times.
private struct NudgeButton: View {
    /// Milliseconds one step moves the line. Positive is earlier (leftwards).
    let ms: Double
    let symbol: String
    let repeatEvery: Duration
    let onStep: (Double) -> Void

    /// The run of steps a held-down button is taking. nil while nothing is held.
    @State private var repeater: Task<Void, Never>? = nil
    /// Whether the hold has actually stepped, so the release that ends it isn't
    /// counted as a tap on top of everything it already moved.
    @State private var didRepeat = false

    /// How long the button has to be held before it starts repeating, so a tap is
    /// only ever one step.
    private let holdDelay: Duration = .milliseconds(400)

    var body: some View {
        Button {
            // Also the path an accessibility activation takes, which never presses
            // the button in the way the repeat below listens for.
            if didRepeat { didRepeat = false } else { withAnimation(.snappy(duration: 0.15)) { onStep(ms) } }
        } label: {
            Image(systemName: symbol)
                .font(.headline)
                .frame(width: 46, height: 40)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .buttonStyle(PressReportingButtonStyle { isPressed in
            if isPressed { startRepeating() } else { stopRepeating() }
        })
        // Spelled out for VoiceOver, which can't read a direction off a chevron: the
        // left-hand buttons make the singing land earlier against the notes.
        .accessibilityLabel(ms > 0 ? L("%d ms earlier", Int(ms)) : L("%d ms later", Int(-ms)))
        // A finger still down when the screen goes away would otherwise leave the
        // run of steps going with nothing to move.
        .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        repeater?.cancel()
        didRepeat = false
        repeater = Task { @MainActor in
            try? await Task.sleep(for: holdDelay)
            while !Task.isCancelled {
                didRepeat = true
                onStep(ms)
                try? await Task.sleep(for: repeatEvery)
            }
        }
    }

    private func stopRepeating() {
        repeater?.cancel()
        repeater = nil
    }
}

/// Passes a button's pressed state out to its owner, for a button that has to do
/// something for as long as it is held rather than once when it is let go.
private struct PressReportingButtonStyle: ButtonStyle {
    let onPressChange: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onChange(of: configuration.isPressed) { _, isPressed in
                onPressChange(isPressed)
            }
    }
}

// MARK: - Pan & pinch input

/// Scroll and zoom input for the review canvas. Written against UIKit's
/// recognisers rather than SwiftUI's gestures because the pinch has to know which
/// way round the fingers are: `MagnifyGesture` reports a scale and nothing else,
/// so a sideways pinch (zoom time) can't be told from an up-and-down one (zoom
/// pitch) through it.
private struct PanZoomSurface: UIViewRepresentable {
    /// Drag since the last callback, in points.
    let onPan: (CGSize) -> Void
    /// Scale since the last callback, the axis the fingers are arranged along, and
    /// the point between them that the zoom should hold still.
    let onPinch: (CGFloat, Axis, CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Without this the view is handed only the first touch, so a pinch never
        // sees two fingers and its axis can't be read at all.
        view.isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handlePan(_:)))
        // One finger scrolls; a second one means the gesture is a pinch instead.
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPan = onPan
        context.coordinator.onPinch = onPinch
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPan: onPan, onPinch: onPinch) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onPan: (CGSize) -> Void
        var onPinch: (CGFloat, Axis, CGPoint) -> Void
        /// Fixed when the two fingers land, so a pinch that drifts diagonally keeps
        /// zooming the one axis it started on.
        private var axis: Axis = .horizontal

        init(onPan: @escaping (CGSize) -> Void,
             onPinch: @escaping (CGFloat, Axis, CGPoint) -> Void) {
            self.onPan = onPan
            self.onPinch = onPinch
        }

        // Both recognisers report incrementally — each callback reads how far the
        // gesture has come and resets it — so the view can apply the change to a
        // camera the clamping may meanwhile have moved, without the two fighting.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard recognizer.state == .changed, let view = recognizer.view else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            onPan(CGSize(width: translation.x, height: translation.y))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                guard recognizer.numberOfTouches >= 2 else { return }
                let first = recognizer.location(ofTouch: 0, in: view)
                let second = recognizer.location(ofTouch: 1, in: view)
                axis = abs(second.x - first.x) >= abs(second.y - first.y) ? .horizontal : .vertical
                recognizer.scale = 1
            case .changed:
                let scale = recognizer.scale
                recognizer.scale = 1
                guard scale > 0 else { return }
                onPinch(scale, axis, recognizer.location(in: view))
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
