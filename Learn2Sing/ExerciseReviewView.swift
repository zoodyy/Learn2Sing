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
    /// One repetition's length in beats, for the repetition counter badge.
    let repeatSpan: Double
    let onClose: () -> Void

    @AppStorage(microphoneDelayKey) private var micDelayMs = 0.0
    @State private var visuals = VisualSettings.current

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
            .onAppear { canvasSize = canvas }
            .onChange(of: canvas) { _, size in canvasSize = size }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(exercise.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        // Leaving goes back to the score, not out of the exercise, so the system's
        // own back button (which would pop the whole run) is replaced.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel(L("Back"))
            }
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

    private func sceneLayout(size: CGSize, camera: Camera) -> SceneLayout {
        SceneLayout(size: size, pianoW: keyboardWidth,
                    rowH: rowHeight(size: size, zoom: camera.verticalZoom),
                    beatPx: beatWidth(zoom: camera.horizontalZoom),
                    playheadX: playheadX(size: size), centerPitch: camera.centerPitch)
    }

    /// Y at which the playhead line starts: the gap the navigation bar leaves
    /// below its buttons, so the line doesn't run up behind them.
    private func playheadTop(safeTop: CGFloat) -> CGFloat {
        max(0, safeTop - (navBarHeight - barButtonHeight))
    }

    // MARK: - Drawing

    private func draw(ctx: GraphicsContext, size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
        let cam = resolvedCamera(size: size)
        let layout = sceneLayout(size: size, camera: cam)
        let beat = cam.playheadBeat
        let delay = micDelayBeats(micDelayMs, bpm: bpm)

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
        if totalReps > 1, repeatSpan > 0 {
            let idx = max(0, min(totalReps - 1, Int(floor(beat / repeatSpan))))
            repetition = (current: idx + 1, total: totalReps)
        }

        drawPlaybackScene(ctx: ctx, layout: layout, beat: beat, notes: notes, texts: texts,
                          trailPath: trailPath, singerPitch: pitch(at: beat), settings: visuals,
                          repetition: repetition, safeTop: safeTop, safeBottom: safeBottom,
                          playheadTop: playheadTop(safeTop: safeTop), repeatSpan: repeatSpan)
    }

    /// The pitch recorded at `beat`, so the singer indicator sits on the line right
    /// under the cursor. `nil` where the run has no sample near that beat — the
    /// singer was silent there, or the cursor is past the end of the run.
    private func pitch(at beat: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        // Back into the recording's own timeline: the line is drawn `delay` beats
        // to the left of where its samples were taken.
        let target = beat + micDelayBeats(micDelayMs, bpm: bpm)

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
        var cam = camera ?? framedCamera(size: size)
        clamp(&cam, size: size)
        return cam
    }

    /// The opening view: the first note against the left edge of the note area
    /// (rather than the silent lead-in the recording also covers), centred on the
    /// notes' own pitch range — a stray label or a stray detected pitch shouldn't
    /// be what decides where the review starts.
    private func framedCamera(size: CGSize) -> Camera {
        let content = measureContent()
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

    /// How far the drawn content reaches, as the camera limits. In time it covers
    /// the recording as well as the notes — the run starts singing during the
    /// lead-in, and all of it should be reachable. In pitch it deliberately
    /// doesn't: the sung line is drawn pinned to the top or bottom edge when it
    /// leaves the view, so it is never lost, while letting one stray estimate
    /// stretch the limits would leave the view free to drift off the exercise.
    private func measureContent() -> (beats: ClosedRange<Double>, pitches: ClosedRange<Double>) {
        let delay = micDelayBeats(micDelayMs, bpm: bpm)
        var firstBeat = notes.first?.beat ?? 0
        var lastBeat = firstBeat
        for note in notes {
            firstBeat = min(firstBeat, note.beat)
            lastBeat = max(lastBeat, note.beat + note.length)
        }
        for label in texts {
            firstBeat = min(firstBeat, label.beat)
            lastBeat = max(lastBeat, label.beat + 2)   // rough allowance for its width
        }
        if let first = samples.first { firstBeat = min(firstBeat, first.beat - delay) }
        if let last = samples.last { lastBeat = max(lastBeat, last.beat - delay) }

        var lowPitch = Double(notes.first?.pitch ?? texts.first?.pitch ?? (hiPitch + loPitch) / 2)
        var highPitch = lowPitch
        for note in notes {
            lowPitch = min(lowPitch, Double(note.pitch))
            highPitch = max(highPitch, Double(note.pitch))
        }
        for label in texts {
            lowPitch = min(lowPitch, Double(label.pitch))
            highPitch = max(highPitch, Double(label.pitch))
        }
        return (min(firstBeat, lastBeat)...max(firstBeat, lastBeat),
                min(lowPitch, highPitch)...max(lowPitch, highPitch))
    }

    /// A one-finger drag: the content follows the finger on both axes.
    private func pan(by delta: CGSize) {
        let size = canvasSize
        guard size.width > 0, size.height > 0 else { return }
        var cam = resolvedCamera(size: size)
        cam.playheadBeat -= Double(delta.width / beatWidth(zoom: cam.horizontalZoom))
        cam.centerPitch += Double(delta.height / rowHeight(size: size, zoom: cam.verticalZoom))
        clamp(&cam, size: size)
        camera = cam
    }

    /// A pinch along one axis, keeping whatever is under the fingers' midpoint
    /// where it is so the content doesn't slide out from under them.
    private func zoom(by factor: CGFloat, axis: Axis, around point: CGPoint) {
        let size = canvasSize
        guard size.width > 0, size.height > 0, factor > 0 else { return }
        var cam = resolvedCamera(size: size)
        switch axis {
        case .horizontal:
            let offset = point.x - playheadX(size: size)
            let anchorBeat = cam.playheadBeat + Double(offset / beatWidth(zoom: cam.horizontalZoom))
            cam.horizontalZoom = clampedHorizontalZoom(cam.horizontalZoom * Double(factor))
            cam.playheadBeat = anchorBeat - Double(offset / beatWidth(zoom: cam.horizontalZoom))
        case .vertical:
            let offset = point.y - size.height / 2
            let anchorPitch = cam.centerPitch
                - Double(offset / rowHeight(size: size, zoom: cam.verticalZoom))
            cam.verticalZoom = clampedVerticalZoom(cam.verticalZoom * Double(factor), size: size)
            cam.centerPitch = anchorPitch
                + Double(offset / rowHeight(size: size, zoom: cam.verticalZoom))
        }
        clamp(&cam, size: size)
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

    /// Keeps the camera over the content: the visible window may reach a beat and a
    /// row past it on each side, and content that doesn't fill the window is
    /// centred in it instead of being free to drift around.
    private func clamp(_ cam: inout Camera, size: CGSize) {
        let content = measureContent()

        let beatPx = beatWidth(zoom: cam.horizontalZoom)
        let noteAreaX = playheadX(size: size) - keyboardWidth
        guard beatPx > 0 else { return }
        let visibleBeats = Double((size.width - keyboardWidth) / beatPx)
        let firstBeat = content.beats.lowerBound - 1
        let lastBeat = content.beats.upperBound + 1
        // Work in the beat at the left edge of the note area — that's the end of
        // the content the limits are about — then convert back to the playhead.
        var left = cam.playheadBeat - Double(noteAreaX / beatPx)
        left = lastBeat - firstBeat <= visibleBeats
            ? (firstBeat + lastBeat - visibleBeats) / 2
            : min(max(left, firstBeat), lastBeat - visibleBeats)
        cam.playheadBeat = left + Double(noteAreaX / beatPx)

        let rowH = rowHeight(size: size, zoom: cam.verticalZoom)
        guard rowH > 0 else { return }
        let visibleRows = Double(size.height / rowH)
        let lowPitch = content.pitches.lowerBound - 1
        let highPitch = content.pitches.upperBound + 1
        // Same again vertically, working in the pitch at the top edge.
        var top = cam.centerPitch + visibleRows / 2
        top = highPitch - lowPitch <= visibleRows
            ? (lowPitch + highPitch + visibleRows) / 2
            : min(max(top, lowPitch + visibleRows), highPitch)
        cam.centerPitch = top - visibleRows / 2
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
