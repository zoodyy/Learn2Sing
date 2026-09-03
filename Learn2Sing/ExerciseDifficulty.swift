//
//  ExerciseDifficulty.swift
//  Learn2Sing
//

import Foundation

/// How hard an exercise is to sing, read off its own notes: 0 is trivial, 100 is
/// as hard as the scale goes.
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
/// Three things about a pattern decide it:
///
/// * **Pace** — how quickly the notes change, as onsets per second at the
///   exercise's tempo.
/// * **Leaps** — how far the voice has to move to reach the next note, as the
///   mean interval between neighbours. The step from one note to the next, not
///   the spread of the whole pattern, which is the term below.
/// * **Span** — the distance from the pattern's lowest note to its highest.
///
/// The three multiply rather than add, because they compound: a wide pattern
/// taken slowly in small steps is a warm-up, and the same span jumped around at
/// speed is not — where a weighted sum would have to call them equally hard.
///
/// What it deliberately leaves out is everything around the pattern: the
/// repetitions, the transposition each one adds, and the pitch shift the whole
/// exercise is sung at. Those say where an exercise sits in a voice and how long
/// it goes on for, both of which the app already fits to the singer
/// (`fitTranspose`), while the difficulty should be the same number on every
/// device that holds the same exercise.
enum ExerciseDifficulty {
    /// The exponents each term is raised to, and the constant that puts the
    /// result on the 0-100 scale.
    ///
    /// Fitted to three bundled exercises placed by hand — "Mum" at 35,
    /// "Ascending Run" and "Octave Alternate Ee" at 80 apiece — which between
    /// them pin all three terms: the two 80s are nothing alike (one is fast and
    /// stepwise, the other slow and leapy) and Mum sits at half their span. The
    /// fit lands them on 35, 80 and 80.
    private static let scale = 0.7675
    private static let paceExponent = 0.6
    private static let leapExponent = 0.7
    private static let spanExponent = 1.15

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

    /// The longest silence between two notes that still counts towards the pace.
    /// A pattern of quick notes with a bar's rest in the middle of it is a
    /// pattern of quick notes; without a cap the rest would average it out into
    /// a slow one.
    private static let maxOnsetGap = 4.0

    /// The exercise's estimated difficulty, 0-100, or nil for a pattern with
    /// nothing to go on — fewer than two notes to move between, or no tempo.
    static func rating(for notes: [MIDINote], bpm: Double) -> Int? {
        guard bpm > 0 else { return nil }
        // One entry per moment the voice moves. Notes starting on the same beat
        // are a chord — unusual in a sung exercise, but the editor's grid allows
        // one — and count as a single onset at their middle pitch, so a chord
        // neither reads as an instant leap nor divides by a zero-length gap.
        let onsets = Dictionary(grouping: notes, by: \.beat)
            .map { beat, chord in
                (beat: beat, pitch: chord.reduce(0.0) { $0 + Double($1.pitch) } / Double(chord.count))
            }
            .sorted { $0.beat < $1.beat }
        guard onsets.count > 1, let low = notes.map(\.pitch).min(),
              let high = notes.map(\.pitch).max()
        else { return nil }

        var beatsBetween = 0.0
        var semitonesBetween = 0.0
        for (from, to) in zip(onsets, onsets.dropFirst()) {
            beatsBetween += min(to.beat - from.beat, maxOnsetGap)
            semitonesBetween += abs(to.pitch - from.pitch)
        }
        let steps = Double(onsets.count - 1)
        // Onsets per second: the mean gap between two of them, in beats, taken
        // at the exercise's tempo.
        let pace = steps / beatsBetween * bpm / 60
        let leap = semitonesBetween / steps
        let span = Double(high - low)

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
