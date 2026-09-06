//
//  ExerciseDifficulty.swift
//  Learn2Sing
//

import Foundation

/// How hard an exercise is to sing, read off the run it plays: 0 is trivial, 100
/// is as hard as the scale goes.
///
/// The server rates an exercise by averaging the scores everyone gets on it (see
/// `EventAverage`), so an exercise nobody has finished has no rating at all — no
/// stars on its intro screen, and nothing for the Home tab's suggestions to
/// place it by. This is the estimate that fills that gap the moment an exercise
/// is made: `CommunitySync.seedDifficulty(for:)` caches it and posts it as three
/// scores, so the rating is there before the first singer gets to it.
///
/// It reads the same way round as the stars — the bigger it is, the harder the
/// exercise — which is the opposite of the server's number. A score and an
/// estimate are two sides of the same 0-100 scale (`SkillLevel.hardness(ofDifficulty:)`),
/// so an exercise estimated at 35 is one that tends to be sung at 65.
///
/// ## The whole run, not the pattern
///
/// An exercise is a pattern *plus* what the repetition settings do to it: how
/// many times it comes round, how far each repetition transposes, how much
/// faster each one goes, how much silence sits between them. All of that is
/// singing the user has to do, so all of it counts. The estimate is taken off
/// `Exercise.timeline(pattern:)` — the very expansion playback scrolls — and
/// from there it is a function of nothing but the notes that come out of it:
/// their pitches, and the second each one starts on.
///
/// That is the property to preserve when changing anything below. Two exercises
/// that sound the same have to rate the same however they are written: one note
/// repeated ten times a fifth higher each round is the same exercise as one
/// repetition of those ten notes written out by hand, and reads as what it is —
/// big leaps, taken quickly. Nothing here may look at `repeatCount`,
/// `transposePerRepeat`, `speedPerRepeat` or `beatsBetweenReps` directly; they
/// are already in the timeline.
///
/// Three things about that run decide it:
///
/// * **Pace** — how quickly the notes change, in onsets per second.
/// * **Leaps** — how far the voice has to move to reach the next note, as the
///   mean interval between neighbours. The step from one note to the next, not
///   the spread of the pattern around it, which is the term below.
/// * **Span** — how much pitch the exercise covers, mostly as the range the
///   voice works over at any one moment and partly as the range it covers in
///   total.
///
/// The three multiply rather than add, because they compound: a wide pattern
/// taken slowly in small steps is a warm-up, and the same span jumped around at
/// speed is not — where a weighted sum would have to call them equally hard.
///
/// What it leaves out is the fit to the singer: `timeline` is asked for the
/// pitches the exercise was written at rather than the ones this voice will get
/// (`fitTranspose`), so the difficulty is the same number on every device that
/// holds the same exercise. Where those pitches sit doesn't matter either — all
/// three terms measure distances between notes, so `pitchShift` moves the run
/// without moving the rating.
enum ExerciseDifficulty {
    /// The exponents each term is raised to, and the constant that puts the
    /// result on the 0-100 scale.
    ///
    /// Fitted to three bundled exercises placed by hand — "Mum" at 35,
    /// "Ascending Run" and "Octave Alternate Ee" at 80 apiece — which between
    /// them pin all three terms: the two 80s are nothing alike (one is fast and
    /// stepwise, the other slow and leapy) and Mum sits at half their span. The
    /// fit lands them on 35, 80 and 80.
    private static let scale = 0.421
    private static let paceExponent = 0.6
    private static let leapExponent = 0.7
    private static let spanExponent = 1.366

    /// Added to the leap and the span before they are raised, so a pattern with
    /// neither — one pitch repeated over and over — comes out very easy rather
    /// than exactly zero however fast it goes. They are also what keeps the
    /// terms away from the part of a fractional power curve that is nearly
    /// vertical, where a semitone either way would swing the whole rating.
    private static let leapFloor = 0.75
    private static let spanFloor = 2.0

    /// Where the scale stops being linear and starts bending towards 100.
    ///
    /// The fit is calibrated on ordinary exercises, and an extreme one runs well
    /// past 100 — two octaves of wide leaps at speed is several times the raw
    /// value of "Ascending Run". Cutting those off at 100 would make every
    /// unreasonable exercise exactly as hard as every other; above this they are
    /// squeezed into the last few points instead, smoothly enough that the curve
    /// doesn't kink where it starts (see `soften`). Nothing at or below this
    /// value is touched, so the exercises the fit was made on keep their ratings.
    private static let softCeiling = 85.0

    /// The quickest two onsets are allowed to read as, in seconds apart. Two
    /// notes a hair apart are a slur or a grid rounding rather than a step sung
    /// at fifty a second, and without a floor one of them would carry the pace
    /// of the whole exercise.
    private static let shortestStep = 0.1

    /// How much of the run the span looks at around each note, in seconds.
    ///
    /// The voice's work at any one moment is the notes either side of it, not
    /// the outer limits of a minute of singing: a pattern that climbs a semitone
    /// per repetition covers a wide range in total while never asking for more
    /// than its own few notes at a time. So the span is measured over a window
    /// this long, centred on each note in turn and averaged. Long enough to hold
    /// a phrase — a repetition of a bundled exercise runs 4-8 seconds — and
    /// short enough that where the *next* repetition sits is somebody else's
    /// problem.
    private static let reachWindow = 6.0

    /// How much of the range beyond that window still counts.
    ///
    /// Covering three octaves over a run is harder than covering one, even a
    /// semitone at a time, so the span is pulled this far from the windowed
    /// reach towards the full distance between the run's lowest and highest
    /// note. Small: it's a long climb rather than a leap, and the singer gets
    /// the whole exercise to make it.
    private static let driftWeight = 0.15

    /// How far apart two notes may start and still be one onset, in seconds.
    /// Well under anything a singer could articulate separately, and well over
    /// the rounding that squeezing a repetition to its own tempo leaves behind.
    private static let simultaneousWithin = 0.001

    /// Slack on the window's edges, in seconds, so a note landing exactly on one
    /// falls the same side of it whichever arithmetic produced its time. An
    /// exercise written out in full has to rate identically to the repetition
    /// settings that play it, and a run of even notes puts onsets on the edge
    /// all the way through.
    private static let edgeSlack = 1e-9

    /// The exercise's estimated difficulty, 0-100, or nil for a run with nothing
    /// to go on — fewer than two notes to move between, or no tempo.
    ///
    /// `pattern` is the exercise's stored notes, one repetition of them — what
    /// `ExerciseStore.notes(for:)` hands over. The repetitions are added here.
    static func rating(for exercise: Exercise, pattern: [MIDINote]) -> Int? {
        guard exercise.bpm > 0, !pattern.isEmpty else { return nil }
        let secondsPerBeat = 60.0 / exercise.bpm
        let played = exercise.timeline(pattern: pattern).notes

        // One entry per moment the voice moves, timed in seconds so that the
        // rating doesn't depend on which tempo the same run happens to be
        // written at. Notes starting together are a chord — unusual in a sung
        // exercise, but the editor's grid allows one — and count as a single
        // onset at their middle pitch, so a chord neither reads as an instant
        // leap nor divides by a zero-length gap.
        var onsets: [(time: Double, pitch: Double)] = []
        var chord: [Int] = []
        var chordTime = 0.0
        func closeChord() {
            guard !chord.isEmpty else { return }
            onsets.append((chordTime, chord.reduce(0.0) { $0 + Double($1) } / Double(chord.count)))
            chord = []
        }
        for note in played.sorted(by: { $0.beat < $1.beat }) {
            let time = note.beat * secondsPerBeat
            if chord.isEmpty || time - chordTime > simultaneousWithin {
                closeChord()
                chordTime = time
            }
            chord.append(note.pitch)
        }
        closeChord()
        guard onsets.count > 1 else { return nil }

        // Pace averages the rate of each step rather than dividing the notes by
        // the time they take, which is the difference between reading the
        // silence between repetitions as a rest and reading it as slowness: a
        // long gap contributes nearly nothing to a mean of rates, so a quick
        // pattern with a bar's breath after it stays a quick pattern.
        var rate = 0.0
        var semitones = 0.0
        for (from, to) in zip(onsets, onsets.dropFirst()) {
            rate += 1 / max(to.time - from.time, shortestStep)
            semitones += abs(to.pitch - from.pitch)
        }
        let steps = Double(onsets.count - 1)
        let pace = rate / steps
        let leap = semitones / steps

        // The span term: what the voice covers moment to moment, pulled a little
        // way towards the distance the run travels from end to end.
        let reach = meanReach(of: onsets)
        let pitches = onsets.map(\.pitch)
        let travelled = (pitches.max() ?? 0) - (pitches.min() ?? 0)
        let span = reach + driftWeight * (travelled - reach)

        let raw = scale
            * pow(pace, paceExponent)
            * pow(leap + leapFloor, leapExponent)
            * pow(span + spanFloor, spanExponent)
        return Int(soften(raw).rounded())
    }

    /// The score a singer of exactly average ability would be expected to get on
    /// an exercise of this difficulty — the number the server holds and the intro
    /// screen turns back into stars. The two are opposite ends of one scale, so
    /// this is the difficulty subtracted from 100.
    static func expectedScore(forRating rating: Int) -> Int {
        100 - min(max(rating, 0), 100)
    }

    /// How much pitch the voice covers around a note, in semitones, averaged over
    /// every note of the run: the distance from the lowest to the highest onset
    /// within `reachWindow` of it.
    ///
    /// Sliding-window maximum and minimum, the usual way — two queues of
    /// indices, one holding the pitches that are still the highest thing to come
    /// and one the lowest, so the front of each is the window's top and bottom
    /// note. Both edges of the window only ever move forwards, so every onset
    /// joins and leaves each queue once apiece however long the exercise runs.
    private static func meanReach(of onsets: [(time: Double, pitch: Double)]) -> Double {
        let half = reachWindow / 2
        var highs: [Int] = []
        var lows: [Int] = []
        var highHead = 0
        var lowHead = 0
        var firstInWindow = 0
        var nextToAdd = 0
        var total = 0.0

        for onset in onsets {
            while nextToAdd < onsets.count, onsets[nextToAdd].time <= onset.time + half + edgeSlack {
                while highs.count > highHead,
                      onsets[highs[highs.count - 1]].pitch <= onsets[nextToAdd].pitch {
                    highs.removeLast()
                }
                highs.append(nextToAdd)
                while lows.count > lowHead,
                      onsets[lows[lows.count - 1]].pitch >= onsets[nextToAdd].pitch {
                    lows.removeLast()
                }
                lows.append(nextToAdd)
                nextToAdd += 1
            }
            // Never past the note being measured, which is inside its own window.
            while onsets[firstInWindow].time < onset.time - half - edgeSlack { firstInWindow += 1 }
            while highHead < highs.count, highs[highHead] < firstInWindow { highHead += 1 }
            while lowHead < lows.count, lows[lowHead] < firstInWindow { lowHead += 1 }
            guard highHead < highs.count, lowHead < lows.count else { continue }
            total += onsets[highs[highHead]].pitch - onsets[lows[lowHead]].pitch
        }
        return total / Double(onsets.count)
    }

    /// Bends the top of the scale into 100 rather than letting it run past.
    ///
    /// Below `softCeiling` this is the identity. Above it the remaining points
    /// are spent exponentially, and the two halves meet with the same slope, so
    /// there is no step or corner at the join: a raw 100 comes out at 94.5 and a
    /// raw 200 at 99.99, approaching 100 without ever arriving (a rating of 100
    /// is the rounding, not the curve).
    private static func soften(_ raw: Double) -> Double {
        guard raw > softCeiling else { return max(raw, 0) }
        let headroom = 100 - softCeiling
        return 100 - headroom * exp(-(raw - softCeiling) / headroom)
    }
}
