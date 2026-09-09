import SwiftUI

/// A still of an exercise as the playback screen would draw it, pinned above the
/// exercise's settings so every change to the pitch, the tempo or the repetitions
/// can be seen where it lands. It draws the timeline playback plays, through the
/// same renderer and under the same visual settings, so what it shows is the run
/// rather than a second reading of the same settings.
///
/// Three things differ from the live screen, all of them because nobody is singing
/// to it: nothing moves on its own — the exercise is dragged past the playhead with
/// a finger instead of scrolling by itself; there is no singing indicator, since
/// there is no sung pitch to show; and the repetition counter is always drawn, at
/// the bottom right, whichever corner the singer chose for playback and whether or
/// not they show it there at all — the repetition settings are right underneath
/// this preview, so what numbers them stays put. An exercise that doesn't repeat
/// still has nothing to count, and gets no badge here either.
///
/// Like the preview on the Visuals ▸ Playback screen it is pinned rather than
/// scrolled away: as the form beneath it moves it collapses, cropping empty canvas
/// until only the strip the exercise is drawn in is left.
struct ExercisePlaybackPreview: View {
    /// The exercise as the settings screen currently has it, so an edit to any of
    /// its settings is drawn on the next frame.
    let exercise: Exercise
    /// Its saved MIDI pattern and the labels written over it — one repetition's
    /// worth, before this exercise's repetitions are laid out from them.
    let pattern: [MIDINote]
    let labels: [MIDIText]
    /// The size the preview is drawn at, before it collapses.
    let width: CGFloat
    let fullHeight: CGFloat
    /// How far the form under the preview has been scrolled (0 at rest, growing
    /// downward), which is what collapses it.
    let scrollOffset: CGFloat

    /// Layout of the pinned preview above the form, matching the visuals screen's.
    static let sidePadding: CGFloat = 20
    static let verticalPadding: CGFloat = 6

    /// The playback look. Read once: nothing on this screen changes it.
    @State private var visuals = VisualSettings.current
    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""

    /// The exercise expanded over its repetitions, rebuilt whenever a setting that
    /// moves a note is changed. Held rather than worked out per frame: a much
    /// repeated exercise is thousands of notes, and the form above redraws on every
    /// keystroke.
    @State private var timeline = ExerciseTimeline()

    /// Beat drawn at the playhead, `nil` until the preview is dragged — the drawing
    /// falls back to the framing worked out from the size it is given, so the first
    /// frame is already pointed at the exercise without this view having to write
    /// any state before it can draw.
    @State private var draggedBeat: Double? = nil
    /// The beat the finger went down at, held for the length of the drag so the
    /// exercise follows the finger rather than the sum of per-frame deltas.
    @State private var dragAnchor: Double? = nil

    var body: some View {
        let crop = collapsingPreviewCrop(fullHeight: fullHeight, band: contentBand,
                                         scrollOffset: scrollOffset)
        canvas(crop: crop)
            .frame(width: width, height: fullHeight)
            .offset(y: -crop.top)
            .frame(width: width, height: fullHeight - crop.top - crop.bottom, alignment: .top)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.15)))
            .contentShape(Rectangle())
            .gesture(drag)
            .explain(L("This exercise as it will play, with the settings below already applied. Drag it sideways to look further along."))
            .padding(.horizontal, Self.sidePadding)
            .padding(.vertical, Self.verticalPadding)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            // The pattern arrives with the screen and the exercise changes under the
            // controls below, so the timeline is rebuilt from whichever moved.
            .onChange(of: exercise, initial: true) { _, _ in rebuild() }
            .onChange(of: pattern) { _, _ in rebuild() }
            .onChange(of: labels) { _, _ in rebuild() }
    }

    private func canvas(crop: (top: CGFloat, bottom: CGFloat)) -> some View {
        Canvas { ctx, size in
            let beat = self.beat
            let layout = SceneLayout(size: size, pianoW: keyboardWidth, rowH: rowHeight,
                                     beatPx: beatPx, playheadX: playheadX,
                                     centerPitch: centerPitch(at: beat))
            // No sung pitch: no dot at the playhead and no line trailing behind it.
            // The crop is passed on as the scene's safe area so the repetition badge
            // stays inside the visible strip as the preview collapses.
            drawPlaybackScene(ctx: ctx, layout: layout, beat: beat,
                              notes: timeline.notes, texts: timeline.texts,
                              trailPath: Path(), singerPitch: nil, settings: settings,
                              repetition: repetition(at: beat),
                              safeTop: crop.top, safeBottom: crop.bottom,
                              repeatLayout: timeline.repeats)
        }
    }

    /// One finger drags the exercise past the playhead, the way it is dragged on the
    /// review screen. Measured from the beat the drag started at, so a drag that runs
    /// past an end of the exercise and comes back stays pinned there until the finger
    /// is back over the exercise.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let anchor = dragAnchor ?? beat
                dragAnchor = anchor
                draggedBeat = clamped(anchor - Double(value.translation.width / beatPx))
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private func rebuild() {
        timeline = exercise.timeline(pattern: pattern, labels: labels,
                                     vocalRange: VocalRange(rawValue: vocalRangeRaw))
    }

    // MARK: - Settings

    /// The saved look with the repetition counter turned on at the bottom right,
    /// whatever it is set to for playback.
    private var settings: VisualSettings {
        var settings = visuals
        settings.showRepetitionCounter = true
        settings.repetitionCounterPosition = .bottomRight
        return settings
    }

    // MARK: - Layout

    private var keyboardWidth: CGFloat { settings.showKeyboard ? playbackKeyboardWidth : 0 }
    private var beatPx: CGFloat { playbackBeatWidth * CGFloat(settings.horizontalZoom) }
    private var playheadX: CGFloat { width / 3 }

    /// Points per semitone, worked out as playback works it out — including the
    /// zoom-out "follow notes vertically" applies when a repetition is too tall to
    /// fit, measured here against the preview at its full height so the drawing
    /// doesn't change scale while the form scrolls it shut.
    private var rowHeight: CGFloat {
        let base = fullHeight / CGFloat(hiPitch - loPitch + 1) * CGFloat(settings.verticalZoom)
        guard settings.followNotesVertically, timeline.maxExtent > 0 else { return base }
        return min(base, (fullHeight / 2) / CGFloat(timeline.maxExtent + 1))
    }

    /// The pitch drawn at the vertical centre: the whole keyboard's midpoint, or —
    /// with "follow notes vertically" on — the centre of the repetition the playhead
    /// is in, the same as during playback.
    private func centerPitch(at beat: Double) -> Double {
        let centers = timeline.centers
        guard settings.followNotesVertically, !centers.isEmpty else {
            return Double(hiPitch + loPitch) / 2
        }
        let index = min(centers.count - 1, timeline.repeats.index(at: beat))
        let previous = centers[max(0, index - 1)]
        // Playback eases from one repetition's centre to the next over about a beat.
        // Dragged by hand there are no frames to ease over, so the move is spread
        // across the first beat of the repetition instead — the same distance, drawn
        // against the drag rather than against the clock.
        let t = min(max(beat - timeline.repeats.starts[index], 0), 1)
        return previous + (centers[index] - previous) * (t * t * (3 - 2 * t))
    }

    /// The strip of canvas the exercise is drawn in, plus a one-row margin either
    /// side — what the preview collapses down to. Taken from the framing rather than
    /// from what is on screen, so it holds still while the exercise is dragged past.
    private var contentBand: (top: CGFloat, bottom: CGFloat) {
        let rowH = rowHeight
        if settings.followNotesVertically, !timeline.centers.isEmpty {
            // Every repetition is drawn around the middle, so one band covers them all.
            let half = CGFloat(timeline.maxExtent + 1.5) * rowH
            return (fullHeight / 2 - half, fullHeight / 2 + half)
        }
        let center = Double(hiPitch + loPitch) / 2
        func y(_ pitch: Double) -> CGFloat { fullHeight / 2 - CGFloat(pitch - center) * rowH }
        let pitches = timeline.notes.map { Double($0.pitch) }
            + timeline.texts.map { Double($0.pitch) }
        guard let low = pitches.min(), let high = pitches.max() else { return (0, fullHeight) }
        return (y(high + 1.5), y(low - 1.5))
    }

    // MARK: - Position

    /// The beat under the playhead: wherever it has been dragged to, or the opening
    /// framing, and either way kept over the exercise.
    private var beat: Double { clamped(draggedBeat ?? framedBeat) }

    /// The opening framing: the exercise's first note against the left-hand edge of
    /// the note area, so as much of it as fits is in view from the start.
    private var framedBeat: Double {
        let first = timeline.notes.map(\.beat).min() ?? contentBeats.lowerBound
        return first + Double((playheadX - keyboardWidth) / beatPx)
    }

    /// How far the playhead may travel: far enough each way that every note and every
    /// label can be brought under it.
    private var contentBeats: ClosedRange<Double> {
        var first = Double.infinity
        var last = -Double.infinity
        for note in timeline.notes {
            first = min(first, note.beat)
            last = max(last, note.beat + note.length)
        }
        for label in timeline.texts {
            first = min(first, label.centreBeat)
            last = max(last, label.centreBeat)
        }
        guard first <= last else { return 0...0 }   // nothing drawn at all
        return first...last
    }

    private func clamped(_ beat: Double) -> Double {
        let range = contentBeats
        return min(max(beat, range.lowerBound), range.upperBound)
    }

    /// Which repetition the playhead is sitting in, for the badge — the same rule the
    /// live screen and the review screen use, so an exercise that doesn't repeat
    /// shows no badge here either.
    private func repetition(at beat: Double) -> (current: Int, total: Int)? {
        let total = max(1, exercise.repeatCount)
        guard total > 1, timeline.repeats.count > 0 else { return nil }
        return (current: min(total - 1, timeline.repeats.index(at: beat)) + 1, total: total)
    }
}
