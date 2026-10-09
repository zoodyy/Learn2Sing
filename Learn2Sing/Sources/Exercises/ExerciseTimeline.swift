import Foundation

// An exercise's saved pattern laid out over its repetitions, the way playback plays
// it. Both the playback screen and the preview on the exercise's settings screen
// build one of these, so the preview shows the run rather than a second reading of
// the same settings.

/// The result of that expansion: where every note and label of every repetition
/// lands, and what playback needs to frame them as it follows the notes.
struct ExerciseTimeline {
    /// The pattern repeated: each repetition shifted along the timeline, scaled to
    /// its own tempo and transposed by its share of "transpose per repetition".
    var notes: [MIDINote] = []
    /// The labels that annotate it, expanded identically so each stays over the note
    /// it was written on.
    var texts: [MIDIText] = []
    /// The ghost notes played along with it, expanded identically too. Never sung
    /// or scored: they are only heard — in place of `notes` wherever they sound
    /// (see `soundingNotes(melody:ghosts:)`) — and drawn faintly.
    var ghosts: [MIDINote] = []
    /// Where the repetitions sit on that timeline.
    var repeats = RepeatLayout()
    /// Vertical centre of each repetition — the midpoint of its pitch range — which
    /// playback recentres on.
    var centers: [Double] = []
    /// Furthest content from a repetition's centre (a note, a ghost note or a
    /// label, above or below) in semitones. The relative geometry is the same for every repetition,
    /// so one value covers them all.
    var maxExtent: Double = 0
}

/// How much clear room a label has either side of its middle, as a multiple of how
/// far its own text reaches: 1 means the nearest note it doesn't already cover starts
/// exactly where the text ends, 2 means twice that much daylight. `.infinity` when
/// nothing is in its way.
///
/// This is what a squeezed repetition spends. Squeezing by `scale` closes those gaps
/// by exactly that factor while the text keeps the size it was written at, so a label
/// may keep `headroom * scale` of that size and no more before it runs into a note it
/// used to clear. The notes it already covers are not counted: the editor snaps a
/// label onto a note, and text written across one belongs there at every tempo.
///
/// Measured across the whole pattern rather than the label's own row — the notes a
/// spilling label runs into are the ones before and after the note it was written on,
/// which are rarely at the same pitch, and how far apart two rows are drawn is a
/// matter of the zoom the exercise is being played at.
private func textHeadroom(of label: MIDIText, over pattern: [MIDINote]) -> Double {
    let centre = label.centreBeat
    let reach = midiTextReach(label.text)
    guard reach > 0 else { return .infinity }

    var headroom = Double.infinity
    for note in pattern {
        let gap: Double
        if note.beat + note.length <= centre { gap = centre - (note.beat + note.length) }
        else if note.beat >= centre          { gap = note.beat - centre }
        else { continue }                    // the label's middle sits inside this note
        guard gap >= reach else { continue } // already covered at the written tempo
        headroom = min(headroom, gap / reach)
    }
    return headroom
}

extension Exercise {
    /// Cumulative semitone offset for a given repetition (0-based). Each repetition
    /// shifts by `transposePerRepeat` from the one before it. If `switchDirectionAfter`
    /// is set, the direction flips exactly once after that many repetitions — counting
    /// the untransposed first repetition — then keeps going the new way for the rest.
    /// E.g. step +1, switchAfter 1 over 5 reps gives 0, -1, -2, -3, -4 (one up step is
    /// "spent" on the first repetition, so the switch lands immediately after it).
    func cumulativeTranspose(forRepetition rep: Int) -> Int {
        let step = transposePerRepeat
        let switchAfter = switchDirectionAfter
        guard rep > 0 else { return 0 }
        guard switchAfter > 0 else { return rep * step }   // never switches

        var offset = 0
        for r in 1...rep {
            // The first `switchAfter` repetitions (including the untransposed one at
            // r == 0) go in the initial direction; from there on it's reversed.
            let direction = r >= switchAfter ? -1 : 1
            offset += direction * step
        }
        return offset
    }

    /// Expand `pattern` (and the `labels` written over it, and the `ghosts` played
    /// along with it) into the timeline this exercise plays: every repetition in its
    /// place, at its own tempo and its own transposition, with the whole thing
    /// finally moved to fit `vocalRange` — the singer's, or nil to leave the pitches
    /// where the pattern puts them.
    func timeline(pattern: [MIDINote], labels: [MIDIText] = [], ghosts: [MIDINote] = [],
                  vocalRange: VocalRange? = nil) -> ExerciseTimeline {
        // Length of one repetition, rounded up to a whole beat so repeats stay aligned,
        // plus any silent beats the user wants between repetitions. The layout then
        // says where each repetition begins and how far its beats are squeezed or
        // stretched to play it at its own tempo ("speed up per repetition"). A ghost
        // note left ringing past the last note is part of the repetition too, so the
        // next one doesn't start on top of it.
        let patternEnd = (pattern + ghosts).map { $0.beat + $0.length }.max() ?? 0
        let span = patternEnd.rounded(.up) + max(0, beatsBetweenReps)
        let layout = repeatLayout(span: span)
        let repeats = layout.count

        // Expand the pattern: each repetition is shifted later in time, scaled to its
        // own tempo and transposed by `transposePerRepeat` semitones. Applying the
        // same transform to the drawn notes keeps playback and animation in sync.
        var expanded: [MIDINote] = []
        var expandedTexts: [MIDIText] = []
        var expandedGhosts: [MIDINote] = []
        // How much clear room each label has around it, which is what says how far it
        // may be shrunk in a squeezed repetition. Measured once: the room is the
        // pattern's own, and every repetition draws the same labels over the same
        // notes — only the scale it's held against changes.
        let headroom = labels.map { textHeadroom(of: $0, over: pattern) }
        for rep in 0..<repeats {
            let transpose = cumulativeTranspose(forRepetition: rep)
            let start = layout.starts[rep]
            let scale = layout.scales[rep]
            func placed(_ note: MIDINote) -> MIDINote {
                var n = note
                n.id = UUID()
                n.pitch += pitchShift + transpose
                n.beat = start + note.beat * scale
                n.length = note.length * scale
                return n
            }
            expanded.append(contentsOf: pattern.map(placed))
            expandedGhosts.append(contentsOf: ghosts.map(placed))
            // Text labels share the note coordinate system, so they take the identical
            // expansion (beat shift + tempo scale + transpose per repeat) to stay
            // pinned to the notes they annotate as the pattern repeats and scrolls.
            for (i, label) in labels.enumerated() {
                var t = label
                t.id = UUID()
                t.pitch += pitchShift + transpose
                // A label is placed — and drawn — by its middle, not by the `beat`
                // that stores it, which is its left edge at the width the text
                // happens to lay out at. So it's the middle that moves with the
                // tempo: scaling the left edge instead would leave the label's own
                // width unsqueezed under it and slide the middle off the note it was
                // centred on, by more the further the tempo strays from the written one.
                t.centreBeat = start + label.centreBeat * scale
                // Squeezing a repetition narrows its notes but not the text over them,
                // so a label that cleared its neighbours stops clearing them. It gives
                // back exactly what the squeeze took and no more: at `scale` it is the
                // written picture shrunk whole, which is as small as this can ever make
                // it — a label written across a note stays across it rather than being
                // shrunk out of a clash that was there from the start.
                t.fontScale = min(1, headroom[i] * scale)
                expandedTexts.append(t)
            }
        }

        // Finally, if the singer has set a vocal range, transpose the whole exercise
        // (notes, their labels and the ghost notes together) to fit it: never let a
        // note drop below the voice's lowest note, lowering the exercise only when its
        // top pokes above the voice's highest note. Applied to the fully expanded
        // pitches so every repetition's transposition is accounted for. Measured on
        // the notes alone, since those are what the voice has to reach.
        var vocalShift = 0
        if let vocalRange,
           let lo = expanded.map(\.pitch).min(),
           let hi = expanded.map(\.pitch).max() {
            vocalShift = vocalRange.fitTranspose(low: lo, high: hi)
            if vocalShift != 0 {
                for i in expanded.indices { expanded[i].pitch += vocalShift }
                for i in expandedTexts.indices { expandedTexts[i].pitch += vocalShift }
                for i in expandedGhosts.indices { expandedGhosts[i].pitch += vocalShift }
            }
        }

        var timeline = ExerciseTimeline(notes: expanded, texts: expandedTexts,
                                        ghosts: expandedGhosts, repeats: layout)

        // The vertical centre of each repetition (the midpoint of its pitch range) so
        // playback can recentre once per repetition. Each repetition's range is the
        // pattern's range shifted by that repetition's cumulative transpose, plus the
        // global pitch- and vocal-range shifts.
        if let pMin = pattern.map(\.pitch).min(), let pMax = pattern.map(\.pitch).max() {
            let baseMid = Double(pMin + pMax) / 2
            timeline.centers = (0..<repeats).map { rep in
                baseMid + Double(pitchShift + cumulativeTranspose(forRepetition: rep) + vocalShift)
            }
            let others = labels.map { Double($0.pitch) } + ghosts.map { Double($0.pitch) }
            let contentMax = max(Double(pMax), others.max() ?? -.infinity)
            let contentMin = min(Double(pMin), others.min() ?? .infinity)
            timeline.maxExtent = max(contentMax - baseMid, baseMid - contentMin)
        }
        return timeline
    }
}

extension Exercise {
    /// The silent beats playback counts in before the first note. Shared with
    /// `PlaybackView`, which schedules the run this measures.
    static let playbackLeadInBeats: Double = 6

    /// The shortest an exercise may be and still be shared on the Community tab,
    /// in seconds. Measured against `contentDuration(pattern:)` rather than the
    /// full run, so it is singing time: a two-note exercise can't buy its way
    /// over the line with a slow tempo, which would only stretch the count-in.
    static let minimumPublicDuration: Double = 10

    /// Whether `seconds`, a `contentDuration(pattern:)`, clears
    /// `minimumPublicDuration`. The slack absorbs the rounding of beats into
    /// seconds, so an exercise landing exactly on the limit is never refused over
    /// a fraction of a millisecond.
    static func clearsMinimumPublicDuration(_ seconds: Double) -> Bool {
        seconds >= minimumPublicDuration - 0.0001
    }

    /// Whether two names are the same name as far as the Community tab is
    /// concerned, where each of a user's public exercises needs its own: case and
    /// surrounding whitespace don't tell them apart.
    static func isSamePublicName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// How long this exercise's music lasts, in seconds: every repetition at the
    /// tempo it is played at, and the silence left between them. Measured from
    /// the first beat to the end of the last repetition, so the count-in and the
    /// beat playback waits at the end are left out — this is the time the singer
    /// spends singing. Worked out from the repetition layout rather than by
    /// expanding the timeline, since nothing here needs the notes themselves.
    ///
    /// `pattern` is the exercise's stored notes, one repetition of them — what
    /// `ExerciseStore.notes(for:)` hands over. Ghost notes are left out: they are
    /// played rather than sung, so they can't carry an exercise over the minimum
    /// either.
    func contentDuration(pattern: [MIDINote]) -> Double {
        guard bpm > 0, !pattern.isEmpty else { return 0 }
        let patternEnd = pattern.map { $0.beat + $0.length }.max() ?? 0
        let layout = repeatLayout(span: patternEnd.rounded(.up) + max(0, beatsBetweenReps))
        // Repetitions are laid out end to end, so the last one is always the one
        // that finishes last however the tempo steps along.
        let lastBeat = (layout.starts.last ?? 0) + patternEnd * (layout.scales.last ?? 1)
        return lastBeat * (60.0 / bpm)
    }

    /// How long a full run of this exercise takes, in seconds — the same span
    /// `PlaybackView` schedules and files on the practice calendar: the silent
    /// lead-in, the music itself, and the beat it waits at the end.
    ///
    /// `pattern` is the exercise's stored notes, one repetition of them — what
    /// `ExerciseStore.notes(for:)` hands over.
    func runDuration(pattern: [MIDINote]) -> Double {
        guard bpm > 0, !pattern.isEmpty else { return 0 }
        return contentDuration(pattern: pattern)
            + (Self.playbackLeadInBeats + 1.0) * (60.0 / bpm)
    }

    /// How long a run lasts as `PlaybackView` schedules it, in seconds: the
    /// silent lead-in, `notes` and `ghosts` (an expanded timeline's) played out
    /// to whichever of them ends last, and the beat it waits at the end, all at
    /// `bpm`. This is what a finished run adds to the Home tab's practice
    /// calendar.
    ///
    /// Unlike `runDuration(pattern:)` it counts a ghost note left ringing past
    /// the last sung one, as the player does. That one is left as it is: it is
    /// what the "Recommended" draw measures its batches in, and changing it
    /// would change which exercises get drawn.
    static func scheduledRunDuration(notes: [MIDINote], ghosts: [MIDINote], bpm: Double) -> Double {
        let lastBeat = (notes + ghosts).map { $0.beat + $0.length }.max() ?? 0
        return (lastBeat + playbackLeadInBeats + 1.0) * (60.0 / bpm)
    }
}

// MARK: - What is heard

/// What an exercise sounds like, as the notes to play: every ghost note, and the
/// notes of `melody` wherever no ghost note is sounding. A ghost note over part of a
/// note silences that part and nothing more, so a note the ghosts cover the first
/// half of is heard for its second half, struck again where they stop. Only the
/// sound changes: the notes are still what is sung and scored, silenced or not.
///
/// Ghost notes of one pitch that overlap are played as a single note, since the
/// player lets go of every voice of a pitch at the first note-off and would cut the
/// longer of them short. Ones that only touch stay two notes, struck twice.
nonisolated func soundingNotes(melody: [MIDINote], ghosts: [MIDINote]) -> [MIDINote] {
    guard !ghosts.isEmpty else { return melody }
    let slack = 1e-9
    let covered = mergedSpans(of: ghosts, joiningTouching: true)
    var heard: [MIDINote] = []
    func play(_ note: MIDINote, from start: Double, to end: Double) {
        guard end - start > slack else { return }
        heard.append(MIDINote(pitch: note.pitch, beat: start, length: end - start))
    }
    for note in melody {
        var start = note.beat
        let end = note.beat + note.length
        for span in covered where span.end > start && span.start < end {
            play(note, from: start, to: span.start)
            start = span.end
        }
        play(note, from: start, to: end)
    }
    for (pitch, sameNote) in Dictionary(grouping: ghosts, by: \.pitch) {
        for span in mergedSpans(of: sameNote, joiningTouching: false) {
            heard.append(MIDINote(pitch: pitch, beat: span.start, length: span.end - span.start))
        }
    }
    return heard
}

/// The stretches of the timeline `notes` sound over, in order, with the notes that
/// overlap — and, with `joiningTouching`, the ones that butt up against each other
/// — folded into one.
nonisolated private func mergedSpans(of notes: [MIDINote],
                                     joiningTouching: Bool) -> [(start: Double, end: Double)] {
    let slack = 1e-9
    var spans: [(start: Double, end: Double)] = []
    for note in notes.sorted(by: { $0.beat < $1.beat }) {
        let end = note.beat + note.length
        if let last = spans.last,
           joiningTouching ? note.beat <= last.end + slack : note.beat < last.end - slack {
            spans[spans.count - 1].end = max(last.end, end)
        } else {
            spans.append((note.beat, end))
        }
    }
    return spans
}
