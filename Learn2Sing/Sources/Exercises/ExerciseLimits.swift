//
//  ExerciseLimits.swift
//  Learn2Sing
//

import Foundation

/// What an exercise may hold: the settings on its settings screen, the notes and
/// labels of its pattern, and how long and how full a run of it gets. See
/// InputLimits.swift for why these exist.
///
/// The one limit a user is expected to meet is `maxDuration`: an exercise is
/// built to last at most half an hour. The rest only keep the app safe. They sit
/// far past anything the app's own exercises use (the longest of them repeats 20
/// times; the biggest pattern has 25 notes), and past anything a hand could draw.
nonisolated enum ExerciseLimits {
    // MARK: Settings

    /// How many times the pattern can be played in a row. Below the 30 minutes
    /// for any pattern but a single beat played very fast, so the length is what
    /// stops a run in practice; the bound is for a document that says a billion.
    static let repeatCount = 1...1000
    /// Semitones each repetition may move from the one before it: two octaves.
    static let transposePerRepeat = -24...24
    /// Semitones the whole exercise may be moved by: the settings screen's
    /// stepper spans the same two octaves.
    static let pitchShift = -24...24
    /// BPM each repetition may speed up or slow down by.
    static let speedPerRepeat = -150...150
    /// Silent beats that may be left between repetitions.
    static let beatsBetweenReps: ClosedRange<Double> = 0...100

    // MARK: Pattern

    /// Notes one repetition may hold, and as many ghost notes again.
    static let notesPerRepetition = 2000
    static let ghostsPerRepetition = 2000
    /// Labels one repetition may hold.
    static let labelsPerRepetition = 1000
    /// Notes, ghost notes and labels a whole run may hold, every repetition
    /// counted. Every screen that plays or draws an exercise lays all of them out
    /// at once, and the playback screen walks through them on every frame, so this
    /// is what keeps a run's memory and frame time in hand. Thirty minutes of
    /// singing would need to hold more than 55 of them every second to get here.
    static let timelineItems = 100_000
    /// The MIDI note numbers a stored note may sit on: the whole MIDI range. The
    /// editor's grid is narrower (`loPitch...hiPitch`).
    static let pitch = 0...127
    /// How far into its pattern a note may start or last, in beats: half an hour
    /// at the fastest tempo. Further out than any pattern the length limit lets
    /// the editor draw.
    static let patternBeats: Double = 7200
    /// The shortest a stored note may be, in beats. Far below the editor's quarter
    /// beat and below the triplets the app's own exercises use; only keeps a note
    /// from having no length at all.
    static let shortestNote: Double = 1.0 / 64
    /// How far before the first beat a label may start, in beats. A label is
    /// placed by its middle, so a long one over the first note reaches back past
    /// the start; at `TextLimit.label` characters that is a few beats.
    static let labelLead: Double = 16

    // MARK: Length

    /// The longest a run of an exercise may last, in seconds, as the intro screen
    /// shows it: count-in, every repetition and the beat at the end.
    static let maxDuration: Double = 30 * 60
    /// The same in whole minutes, for the message that says so.
    static let maxDurationMinutes = 30
    /// Slack on that limit, so a run landing exactly on it isn't refused over the
    /// rounding of beats into seconds.
    static let durationSlack = 0.0005
}

// MARK: - Holding an exercise inside the limits

nonisolated extension Exercise {
    /// This exercise with every setting brought inside `ExerciseLimits` and every
    /// text inside `TextLimit`. Applied to every exercise decoded (see
    /// `init(from:)`) and every one written to the store (see
    /// `ExerciseStore.binding(for:)`), so a value no screen would let through —
    /// typed into an older version, or written straight into a document on the
    /// server — never reaches the code that lays a run out.
    ///
    /// The category is left as it is: it is a key into the user's own category
    /// list, which a cut could make collide, and a fetched exercise's category is
    /// never shown or kept (a download puts it under "No Category").
    func withinLimits() -> Exercise {
        var limited = self
        limited.name = name.limited(to: TextLimit.exerciseName)
        limited.details = details.limited(to: TextLimit.exerciseDetails)
        limited.uploaderName = uploaderName.limited(to: TextLimit.username)
        limited.downloadedFrom = downloadedFrom?.limited(to: TextLimit.username)
        limited.pitchShift = pitchShift.clamped(to: ExerciseLimits.pitchShift)
        limited.bpm = bpm.isFinite ? bpm.clamped(to: Exercise.tempoRange) : 120
        limited.repeatCount = repeatCount.clamped(to: ExerciseLimits.repeatCount)
        limited.transposePerRepeat = transposePerRepeat.clamped(to: ExerciseLimits.transposePerRepeat)
        limited.switchDirectionAfter = switchDirectionAfter.clamped(to: 0...(limited.repeatCount - 1))
        limited.speedPerRepeat = speedPerRepeat.clamped(to: ExerciseLimits.speedPerRepeat)
        limited.beatsBetweenReps = beatsBetweenReps.isFinite
            ? beatsBetweenReps.clamped(to: ExerciseLimits.beatsBetweenReps)
            : 0
        return limited
    }

    /// How many repetitions a run actually plays: `repeatCount`, held inside its
    /// limit, and to as many as keep the run within `ExerciseLimits.timelineItems`
    /// when each repetition lays out `items` notes, ghost notes and labels.
    ///
    /// Every exercise the store holds already keeps inside that (see
    /// `ExerciseStore.holdRunsWithinLimits()`), so for those this is `repeatCount`;
    /// the second bound only ever bites on something that reached a screen some
    /// other way, which is what it is there for.
    func playedRepeatCount(items: Int) -> Int {
        let repeats = repeatCount.clamped(to: ExerciseLimits.repeatCount)
        guard items > 0 else { return repeats }
        return min(repeats, Exercise.mostRepeats(items: items))
    }

    /// The most repetitions of a pattern laying out `items` notes, ghost notes and
    /// labels that keep a run within `ExerciseLimits.timelineItems`: at least one,
    /// since a single repetition is held inside it by the per-repetition limits.
    static func mostRepeats(items: Int) -> Int {
        guard items > 0 else { return ExerciseLimits.repeatCount.upperBound }
        return max(1, min(ExerciseLimits.repeatCount.upperBound, ExerciseLimits.timelineItems / items))
    }
}

nonisolated extension MIDINote {
    /// This note moved inside the limits a stored note keeps to: a MIDI note
    /// number, a start no earlier than the pattern's first beat, and a length.
    func withinLimits() -> MIDINote {
        var note = self
        note.pitch = pitch.clamped(to: ExerciseLimits.pitch)
        note.beat = beat.isFinite ? beat.clamped(to: 0...ExerciseLimits.patternBeats) : 0
        note.length = length.isFinite
            ? length.clamped(to: ExerciseLimits.shortestNote...ExerciseLimits.patternBeats)
            : ExerciseLimits.shortestNote
        return note
    }
}

nonisolated extension MIDIText {
    /// This label moved inside the limits a stored label keeps to.
    func withinLimits() -> MIDIText {
        var label = self
        label.text = text.limited(to: TextLimit.label)
        label.pitch = pitch.clamped(to: ExerciseLimits.pitch)
        label.beat = beat.isFinite
            ? beat.clamped(to: -ExerciseLimits.labelLead...ExerciseLimits.patternBeats)
            : 0
        return label
    }
}

// MARK: - How long a run lasts

/// What `Exercise.runLength` needs to know about a pattern to time a run of it.
struct PatternExtent: Equatable {
    /// Where the last note or ghost note ends, in beats; nil when there are none.
    var end: Double?
    /// The notes, ghost notes and labels one repetition lays out.
    var items: Int

    init(notes: [MIDINote], ghosts: [MIDINote], labels: [MIDIText]) {
        end = (notes + ghosts).map { $0.beat + $0.length }.max()
        items = notes.count + ghosts.count + labels.count
    }

    init(end: Double?, items: Int) {
        self.end = end
        self.items = items
    }
}

extension Exercise {
    /// How long a run of this exercise lasts, in seconds, over a pattern of
    /// `extent`: the count-in, every repetition at its own tempo and the beat
    /// waited at the end. The same span `ExerciseStore.practiceSeconds(of:)` times
    /// by laying the notes out and `PlaybackView` schedules, worked out from the
    /// repetition layout alone, so it is cheap enough to ask on every keystroke
    /// and every drag.
    ///
    /// The last repetition always ends last: each one is given at least its own
    /// length before the next begins (see `timeline(pattern:labels:ghosts:vocalRange:)`).
    func runLength(over extent: PatternExtent) -> Double {
        guard bpm > 0 else { return 0 }
        var lastBeat = 0.0
        if let end = extent.end {
            let patternEnd = max(0, end)
            let layout = repeatLayout(span: patternEnd.rounded(.up) + max(0, beatsBetweenReps),
                                      items: extent.items)
            lastBeat = (layout.starts.last ?? 0) + patternEnd * (layout.scales.last ?? 1)
        }
        return (lastBeat + Self.playbackLeadInBeats + 1) * (60 / bpm)
    }

    /// Whether a run over `extent` keeps within `allowance` seconds: the half
    /// hour, or however long the exercise already was when the change being made
    /// to it started (see `lengthAllowance(over:)`).
    func fitsLength(over extent: PatternExtent, allowance: Double) -> Bool {
        runLength(over: extent) <= allowance + ExerciseLimits.durationSlack
    }

    /// How long a change to this exercise may leave it: the half hour, or longer
    /// for an exercise that already was, made before the limit existed or brought
    /// in from a file. Nothing done to it may make that one longer, only shorter.
    func lengthAllowance(over extent: PatternExtent) -> Double {
        max(ExerciseLimits.maxDuration, runLength(over: extent))
    }

    /// Whether `repeatCount` repetitions of a pattern laying out `items` notes,
    /// ghost notes and labels stay within `ExerciseLimits.timelineItems`.
    func fitsTimeline(items: Int) -> Bool {
        repeatCount.clamped(to: ExerciseLimits.repeatCount) <= Exercise.mostRepeats(items: items)
    }
}

// MARK: - Searching for the furthest a change can go

extension ExerciseLimits {
    /// The whole number between `from`, which is taken to fit, and `to` that lies
    /// furthest towards `to` while `fits` still holds; `to` itself when it fits.
    /// `fits` must hold up to some point between the two and fail past it, which
    /// is true of everything a run's length depends on: more repetitions, more
    /// silence between them, a slower tempo or a longer pattern never make it
    /// shorter.
    static func furthest(from: Int, to: Int, where fits: (Int) -> Bool) -> Int {
        guard from != to, !fits(to) else { return to }
        var good = from
        var bad = to
        while abs(bad - good) > 1 {
            let middle = good + (bad - good) / 2
            if fits(middle) { good = middle } else { bad = middle }
        }
        return good
    }
}
