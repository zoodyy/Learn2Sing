import Foundation

// An exercise's saved pattern laid out over its repetitions, the way playback plays
// it. Both the playback screen and the preview on the exercise's settings screen
// build one of these, so the preview shows the run rather than a second reading of
// the same settings.

/// The result of that expansion: where every note and label of every repetition
/// lands, and what "follow notes vertically" needs to frame them.
struct ExerciseTimeline {
    /// The pattern repeated: each repetition shifted along the timeline, scaled to
    /// its own tempo and transposed by its share of "transpose per repetition".
    var notes: [MIDINote] = []
    /// The labels that annotate it, expanded identically so each stays over the note
    /// it was written on.
    var texts: [MIDIText] = []
    /// Where the repetitions sit on that timeline.
    var repeats = RepeatLayout()
    /// Vertical centre of each repetition — the midpoint of its pitch range — which
    /// "follow notes vertically" recentres on.
    var centers: [Double] = []
    /// Furthest content from a repetition's centre (a note or a label, above or
    /// below) in semitones. The relative geometry is the same for every repetition,
    /// so one value covers them all.
    var maxExtent: Double = 0
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

    /// Expand `pattern` (and the `labels` written over it) into the timeline this
    /// exercise plays: every repetition in its place, at its own tempo and its own
    /// transposition, with the whole thing finally moved to fit `vocalRange` — the
    /// singer's, or nil to leave the pitches where the pattern puts them.
    func timeline(pattern: [MIDINote], labels: [MIDIText] = [],
                  vocalRange: VocalRange? = nil) -> ExerciseTimeline {
        // Length of one repetition, rounded up to a whole beat so repeats stay aligned,
        // plus any silent beats the user wants between repetitions. The layout then
        // says where each repetition begins and how far its beats are squeezed or
        // stretched to play it at its own tempo ("speed up per repetition").
        let patternEnd = pattern.map { $0.beat + $0.length }.max() ?? 0
        let span = patternEnd.rounded(.up) + max(0, beatsBetweenReps)
        let layout = repeatLayout(span: span)
        let repeats = layout.count

        // Expand the pattern: each repetition is shifted later in time, scaled to its
        // own tempo and transposed by `transposePerRepeat` semitones. Applying the
        // same transform to the drawn notes keeps playback and animation in sync.
        var expanded: [MIDINote] = []
        var expandedTexts: [MIDIText] = []
        for rep in 0..<repeats {
            let transpose = cumulativeTranspose(forRepetition: rep)
            let start = layout.starts[rep]
            let scale = layout.scales[rep]
            for note in pattern {
                var n = note
                n.id = UUID()
                n.pitch += pitchShift + transpose
                n.beat = start + note.beat * scale
                n.length = note.length * scale
                expanded.append(n)
            }
            // Text labels share the note coordinate system, so they take the identical
            // expansion (beat shift + tempo scale + transpose per repeat) to stay
            // pinned to the notes they annotate as the pattern repeats and scrolls.
            for label in labels {
                var t = label
                t.id = UUID()
                t.pitch += pitchShift + transpose
                t.beat = start + label.beat * scale
                expandedTexts.append(t)
            }
        }

        // Finally, if the singer has set a vocal range, transpose the whole exercise
        // (notes and their labels together) to fit it: never let a note drop below
        // the voice's lowest note, lowering the exercise only when its top pokes
        // above the voice's highest note. Applied to the fully expanded pitches so
        // every repetition's transposition is accounted for.
        var vocalShift = 0
        if let vocalRange,
           let lo = expanded.map(\.pitch).min(),
           let hi = expanded.map(\.pitch).max() {
            vocalShift = vocalRange.fitTranspose(low: lo, high: hi)
            if vocalShift != 0 {
                for i in expanded.indices { expanded[i].pitch += vocalShift }
                for i in expandedTexts.indices { expandedTexts[i].pitch += vocalShift }
            }
        }

        var timeline = ExerciseTimeline(notes: expanded, texts: expandedTexts, repeats: layout)

        // The vertical centre of each repetition (the midpoint of its pitch range) so
        // "follow notes vertically" can recentre once per repetition. Each
        // repetition's range is the pattern's range shifted by that repetition's
        // cumulative transpose, plus the global pitch- and vocal-range shifts.
        if let pMin = pattern.map(\.pitch).min(), let pMax = pattern.map(\.pitch).max() {
            let baseMid = Double(pMin + pMax) / 2
            timeline.centers = (0..<repeats).map { rep in
                baseMid + Double(pitchShift + cumulativeTranspose(forRepetition: rep) + vocalShift)
            }
            let contentMax = max(Double(pMax), labels.map { Double($0.pitch) }.max() ?? -.infinity)
            let contentMin = min(Double(pMin), labels.map { Double($0.pitch) }.min() ?? .infinity)
            timeline.maxExtent = max(contentMax - baseMid, baseMid - contentMin)
        }
        return timeline
    }
}

extension Exercise {
    /// The silent beats playback counts in before the first note. Shared with
    /// `PlaybackView`, which schedules the run this measures.
    static let playbackLeadInBeats: Double = 6

    /// How long a full run of this exercise takes, in seconds — the same span
    /// `PlaybackView` schedules and files on the practice calendar: the silent
    /// lead-in, every repetition at its own tempo, and the beat it waits at the
    /// end. Worked out from the repetition layout rather than by expanding the
    /// timeline, since nothing here needs the notes themselves.
    ///
    /// `pattern` is the exercise's stored notes, one repetition of them — what
    /// `ExerciseStore.notes(for:)` hands over.
    func runDuration(pattern: [MIDINote]) -> Double {
        guard bpm > 0, !pattern.isEmpty else { return 0 }
        let patternEnd = pattern.map { $0.beat + $0.length }.max() ?? 0
        let layout = repeatLayout(span: patternEnd.rounded(.up) + max(0, beatsBetweenReps))
        // Repetitions are laid out end to end, so the last one is always the one
        // that finishes last however the tempo steps along.
        let lastBeat = (layout.starts.last ?? 0) + patternEnd * (layout.scales.last ?? 1)
        return (lastBeat + Self.playbackLeadInBeats + 1.0) * (60.0 / bpm)
    }
}
