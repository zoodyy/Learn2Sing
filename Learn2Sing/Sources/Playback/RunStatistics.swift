//
//  RunStatistics.swift
//  Learn2Sing
//
//  What the score screen shows under its chart about the run just sung: where the
//  voice sat on the notes, the path it took across a note on average, and how fast
//  it moved from one note to the next. Worked out off the main actor once the
//  score screen is already up, and never stored anywhere: it lasts exactly as long
//  as that screen does.
//

import Foundation

/// The statistics of one finished run, measured from the same pitch line the score
/// was worked out from and lined up with the notes the same way (see `analyze`).
nonisolated struct RunStatistics: Sendable {
    /// Where the voice sat on the notes it held, on average, in cents: above the
    /// note's centre when positive, below it when negative. nil when no note was
    /// sung clearly enough to tell.
    ///
    /// Each note counts with where it was held (the median of its line, which a
    /// slide in or an early leave for the next note barely moves), weighted by how
    /// long it was held. The start of a note, where the voice is still arriving from
    /// the one before, is left out exactly as the score leaves it out (see
    /// `PitchTravel`).
    let averageCents: Double?

    /// How many notes that average was taken over, out of how many the run had. A
    /// note counts once there was enough of a line on it, held within
    /// `sungGateCents` of it; one sung further off was another note, not this one
    /// sung badly, and the score already says so.
    let measuredNotes: Int
    let noteCount: Int

    /// The pitch line averaged over every measured note, `pathPoints` values spread
    /// evenly from each note's start to its end, in cents from its centre. This one
    /// keeps the whole note, arrival included, since the way into a note is half of
    /// what it shows. nil where too few notes had any line to average.
    let averagePath: [Double?]

    /// How fast the voice moved between notes; nil when the run had no change of
    /// note it could be measured on.
    let noteChanges: NoteChanges?

    nonisolated struct NoteChanges: Sendable {
        /// Semitones per second over the middle of each move, all the moves taken
        /// together.
        let semitonesPerSecond: Double
        /// How long a move took on average from one note to the next, at that speed.
        let secondsPerChange: Double
        /// The same speed for the moves upwards and the moves downwards on their own;
        /// nil for a direction the run had no measured move in.
        let upwardSemitonesPerSecond: Double?
        let downwardSemitonesPerSecond: Double?
        let count: Int
    }
}

nonisolated extension RunStatistics {
    /// How many values `averagePath` holds along a note.
    static let pathPoints = 40

    /// Furthest from a note its held line may sit, in cents, for the note to count
    /// as sung: a semitone and a half, so a singer who is far off the centre still
    /// counts while a neighbouring note sung instead doesn't.
    static let sungGateCents = 150.0

    /// Least line a note's held part needs, in seconds, to say where it was held: or
    /// half the held part, when that is shorter.
    static let minimumHeldSeconds = 0.04

    /// How far from a note a moment of line counts towards the average path, in
    /// cents. The line coming in from a fifth away is still well off the note, and
    /// is counted as this far off rather than letting the size of the leap swamp the
    /// average; it also keeps an octave slip of the detector from doing the same.
    static let pathClampCents = 300.0

    /// Least share of the measured notes that has to have line at a point along the
    /// note for the average path to be drawn there. Fewer than that and the point
    /// says more about the few notes than about the singing, so the path breaks.
    static let pathMinimumShare = 0.25

    /// Longest rest between two notes, in seconds, over which the move from one to
    /// the other still counts. Over a longer one the voice stops and starts afresh.
    static let longestRestSeconds = 0.25

    /// Longest break in the line a move may have in it, in seconds: room for a
    /// consonant between two syllables, not for a breath.
    static let longestBreakSeconds = 0.12

    /// The share of a move measured, from where it has covered 10% of the way to
    /// where it has covered 90%: its start and its end trail off too gradually to
    /// time, and the middle is what says how fast the voice went.
    static let measuredShare = 0.8

    /// Works the statistics out from a finished run, away from the main actor.
    ///
    /// `samples` is the run's pitch line, oldest first, at the beats it was drawn
    /// at, and `noteShift` is how much later than drawn the notes were scored, in
    /// beats: the microphone delay the score is at plus the pitch detection's
    /// look-ahead. Taking it off the line puts the line where the review screen
    /// draws it, which is where it was scored against the notes.
    @concurrent
    nonisolated static func analyze(samples: [PitchSample], notes: [MIDINote], bpm: Double,
                                    noteShift: Double) async -> RunStatistics {
        measure(samples: samples, notes: notes, bpm: bpm, noteShift: noteShift)
    }

    /// `analyze`, on whatever thread it is called on.
    nonisolated static func measure(samples: [PitchSample], notes unsorted: [MIDINote],
                                    bpm: Double, noteShift: Double) -> RunStatistics {
        // Played one at a time, so in time order the note before is the one sung
        // before.
        let notes = unsorted.sorted { $0.beat < $1.beat }
        guard bpm > 0, !notes.isEmpty else {
            return RunStatistics(averageCents: nil, measuredNotes: 0, noteCount: notes.count,
                                 averagePath: Array(repeating: nil, count: pathPoints),
                                 noteChanges: nil)
        }
        let line = MeasuredLine(samples: samples, noteShift: noteShift, bpm: bpm)
        let required = PitchTravel.requiredBeats(notes: notes, bpm: bpm)

        // Where each note was held, as a pitch, and the average over all of them.
        var held = [Double?](repeating: nil, count: notes.count)
        var centsTotal = 0.0
        var heldTotal = 0.0
        for (i, note) in notes.enumerated() {
            let end = note.beat + note.length
            guard let hold = line.hold(on: note, from: end - required[i], to: end,
                                       atLeast: min(minimumHeldSeconds,
                                                    required[i] * line.secondsPerBeat / 2))
            else { continue }
            guard abs(hold.cents) <= sungGateCents else { continue }
            held[i] = Double(note.pitch) + hold.cents / 100
            centsTotal += hold.cents * hold.seconds
            heldTotal += hold.seconds
        }
        let measured = notes.indices.filter { held[$0] != nil }

        return RunStatistics(
            averageCents: heldTotal > 0 ? centsTotal / heldTotal : nil,
            measuredNotes: measured.count,
            noteCount: notes.count,
            averagePath: averagePath(over: measured.map { notes[$0] }, line: line),
            noteChanges: noteChanges(notes: notes, held: held, required: required, line: line))
    }

    /// The line across each of `notes`, averaged point by point along them.
    private nonisolated static func averagePath(over notes: [MIDINote],
                                                line: MeasuredLine) -> [Double?] {
        var sums = [Double](repeating: 0, count: pathPoints)
        var counts = [Int](repeating: 0, count: pathPoints)
        for note in notes {
            for (k, value) in line.path(across: note, points: pathPoints, clamp: pathClampCents)
                .enumerated() {
                guard let value else { continue }
                sums[k] += value
                counts[k] += 1
            }
        }
        let needed = max(1, Int((Double(notes.count) * pathMinimumShare).rounded(.up)))
        return (0..<pathPoints).map { counts[$0] >= needed ? sums[$0] / Double(counts[$0]) : nil }
    }

    /// How fast the voice got from each note to the next, over every pair of
    /// neighbouring notes that were both sung, lie at different pitches and follow
    /// on without a long rest between them.
    private nonisolated static func noteChanges(notes: [MIDINote], held: [Double?],
                                                required: [Double],
                                                line: MeasuredLine) -> NoteChanges? {
        var moves: [(up: Bool, semitones: Double, seconds: Double)] = []
        for k in notes.indices.dropFirst() {
            let before = notes[k - 1]
            let after = notes[k]
            guard let from = held[k - 1], let to = held[k], before.pitch != after.pitch
            else { continue }
            let rest = (after.beat - (before.beat + before.length)) * line.secondsPerBeat
            // Two notes the singer held at much the same pitch leave no move to time.
            guard rest <= longestRestSeconds, abs(to - from) >= 0.5 else { continue }
            // From where the note before was being held, so the move found is the
            // one that left it, up to the end of the note it arrives on.
            let leaving = before.beat + before.length - required[k - 1]
            guard let seconds = line.moveSeconds(from: from, to: to, between: leaving,
                                                 and: after.beat + after.length,
                                                 longestBreak: longestBreakSeconds)
            else { continue }
            moves.append((up: to > from, semitones: abs(to - from) * measuredShare,
                          seconds: seconds))
        }
        guard !moves.isEmpty else { return nil }

        /// Distance over time for a set of moves, rather than the average of their
        /// speeds: one quick little move would otherwise count for as much as a
        /// whole octave's.
        func speed(_ chosen: [(up: Bool, semitones: Double, seconds: Double)]) -> Double? {
            let seconds = chosen.reduce(0) { $0 + $1.seconds }
            guard !chosen.isEmpty, seconds > 0 else { return nil }
            return chosen.reduce(0) { $0 + $1.semitones } / seconds
        }
        guard let overall = speed(moves) else { return nil }
        let meanSeconds = moves.reduce(0) { $0 + $1.seconds } / Double(moves.count)
        return NoteChanges(semitonesPerSecond: overall,
                           secondsPerChange: meanSeconds / measuredShare,
                           upwardSemitonesPerSecond: speed(moves.filter(\.up)),
                           downwardSemitonesPerSecond: speed(moves.filter { !$0.up }),
                           count: moves.count)
    }
}

/// A finished run's pitch line, moved back onto the notes by the shift it was
/// scored at, with the questions the statistics ask of it.
private nonisolated struct MeasuredLine {
    /// Each sample's beat with the shift taken off, in recording order, which is
    /// beat order: the playback clock never runs backwards.
    let beats: [Double]
    let pitches: [Double?]
    let secondsPerBeat: Double

    /// Neighbouring samples further apart than this (in beats) have a pause between
    /// them rather than a stretch of line: the same guard the scorer puts on them.
    static let longestStep = 0.5

    init(samples: [PitchSample], noteShift: Double, bpm: Double) {
        beats = samples.map { $0.beat - noteShift }
        pitches = samples.map(\.pitch)
        secondsPerBeat = 60 / bpm
    }

    /// The first sample at or after `beat`.
    func index(atOrAfter beat: Double) -> Int {
        var low = 0
        var high = beats.count
        while low < high {
            let mid = (low + high) / 2
            if beats[mid] < beat { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Where `note` was held between `start` and `end` (beats): the median of the
    /// line there in cents from the note, and how many seconds of line that was. nil
    /// when there was less than `atLeast` seconds of it.
    ///
    /// Each sample stands for the step back to the one before it, as it does for the
    /// scorer.
    func hold(on note: MIDINote, from start: Double, to end: Double,
              atLeast: Double) -> (cents: Double, seconds: Double)? {
        var cents: [Double] = []
        var seconds = 0.0
        for j in index(atOrAfter: start)..<index(atOrAfter: end) where j > 0 {
            guard let pitch = pitches[j] else { continue }
            let step = beats[j] - beats[j - 1]
            guard step > 0, step < Self.longestStep else { continue }
            cents.append((pitch - Double(note.pitch)) * 100)
            seconds += step * secondsPerBeat
        }
        guard !cents.isEmpty, seconds >= atLeast else { return nil }
        cents.sort()
        let middle = cents.count / 2
        let median = cents.count.isMultiple(of: 2) ? (cents[middle - 1] + cents[middle]) / 2 : cents[middle]
        return (median, seconds)
    }

    /// The line across `note`, as the average over each of `points` equal stretches
    /// of it of how far the line was from the note there, in cents (held within
    /// `clamp`). The line is the one the review screen draws, straight from each
    /// sample to the next, so a stretch between two samples still has the part of
    /// that line which runs through it. nil for a stretch with too little line in it.
    func path(across note: MIDINote, points: Int, clamp: Double) -> [Double?] {
        guard note.length > 0, beats.count > 1 else { return Array(repeating: nil, count: points) }
        var integral = [Double](repeating: 0, count: points)
        var covered = [Double](repeating: 0, count: points)
        let count = Double(points)
        func cents(_ pitch: Double) -> Double {
            min(clamp, max(-clamp, (pitch - Double(note.pitch)) * 100))
        }
        // Every piece of line that reaches into the note, the ones crossing its two
        // ends included.
        let first = max(1, index(atOrAfter: note.beat))
        let last = min(beats.count - 1, index(atOrAfter: note.beat + note.length))
        if first <= last {
            for j in first...last {
                guard let p0 = pitches[j - 1], let p1 = pitches[j] else { continue }
                // Along the note, 0 at its start and 1 at its end.
                let t0 = (beats[j - 1] - note.beat) / note.length
                let t1 = (beats[j] - note.beat) / note.length
                guard t1 > t0, beats[j] - beats[j - 1] < Self.longestStep,
                      t1 > 0, t0 < 1 else { continue }
                let c0 = cents(p0)
                let c1 = cents(p1)
                let firstPoint = max(0, Int(t0 * count))
                let lastPoint = min(points - 1, Int(t1 * count))
                guard firstPoint <= lastPoint else { continue }
                for k in firstPoint...lastPoint {
                    let a = max(Double(k) / count, t0)
                    let b = min(Double(k + 1) / count, t1)
                    guard b > a else { continue }
                    // A straight piece of line averages to its value halfway along.
                    let middle = (a + b) / 2
                    integral[k] += (c0 + (c1 - c0) * (middle - t0) / (t1 - t0)) * (b - a)
                    covered[k] += b - a
                }
            }
        }
        // A stretch needs line over a good part of it to say where the line was.
        let enough = 0.3 / count
        return (0..<points).map { covered[$0] >= enough ? integral[$0] / covered[$0] : nil }
    }

    /// How long the voice took to move from the pitch `from` to the pitch `to`
    /// somewhere between the beats `start` and `end`, in seconds: from the last time
    /// the line was within 10% of the way from `from`, to the first time after it
    /// that it had come 90% of the way. nil when it never got there, or broke off
    /// for longer than `longestBreak` seconds on the way.
    func moveSeconds(from: Double, to: Double, between start: Double, and end: Double,
                     longestBreak: Double) -> Double? {
        let distance = to - from
        guard distance != 0 else { return nil }
        func progress(_ j: Int) -> Double? { pitches[j].map { ($0 - from) / distance } }

        let lower = index(atOrAfter: start)
        let upper = index(atOrAfter: end)
        guard lower < upper else { return nil }
        guard let arrived = (lower..<upper).first(where: { (progress($0) ?? 0) >= 0.9 }),
              let left = (lower..<arrived).last(where: { progress($0).map { $0 <= 0.1 } ?? false })
        else { return nil }

        // Breaks in the line on the way, and any pause that would make a jump of it.
        var broken = 0.0
        for j in (left + 1)...arrived {
            let step = beats[j] - beats[j - 1]
            guard step >= 0, step < Self.longestStep else { return nil }
            if pitches[j] == nil || pitches[j - 1] == nil { broken += step * secondsPerBeat }
        }
        guard broken <= longestBreak else { return nil }

        /// When the straight line from sample `a` to sample `b` passes `share` of the
        /// way. Only ever asked of two samples either side of it.
        func crossing(_ share: Double, from a: Int, to b: Int) -> Double {
            guard let pa = progress(a), let pb = progress(b), pb != pa else { return beats[a] }
            let along = min(1, max(0, (share - pa) / (pb - pa)))
            return beats[a] + along * (beats[b] - beats[a])
        }
        // The samples after the 10% mark and before the 90% one with a pitch, which
        // the line runs straight to from either of them across any break.
        guard let next = ((left + 1)...arrived).first(where: { pitches[$0] != nil }),
              let previous = (left..<arrived).last(where: { pitches[$0] != nil })
        else { return nil }
        let seconds = (crossing(0.9, from: previous, to: arrived) - crossing(0.1, from: left, to: next))
            * secondsPerBeat
        // A move that takes longer than a second is not one move.
        return seconds > 0 && seconds <= 1 ? seconds : nil
    }
}
