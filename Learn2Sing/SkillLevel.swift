//
//  SkillLevel.swift
//  Learn2Sing
//
//  Works out how hard an exercise this singer can handle, from the scores they
//  earn on exercises the server has rated, and keeps that one number where the
//  Home tab's recommendations and the synced profile can both read it.
//

import SwiftUI
import Combine

/// One exercise the singer has sung, together with what the server rates it at:
/// a single reading of how hard they can sing.
nonisolated struct RatedExercise {
    /// The server's average score for the exercise, 0-100 — 100 is the easiest.
    /// See `EventAverage` for why it counts that way round.
    var difficulty: Double
    /// The runs this device has recorded for it, in any order.
    var runs: [ScoreEntry]
}

/// How the singer's skill level is worked out, and the constants that shape it.
///
/// The level is one number from 0 to 100 on the *hardness* scale — the same one
/// the intro screen's difficulty stars fill along, where 0 is the easiest
/// exercise there is and 100 the hardest. The server rates exercises the other
/// way round (its `EXERCISE_DIFFICULTY` is the average score everyone gets on
/// one, so 100 means easy — see `EventAverage`), which is what
/// `hardness(ofDifficulty:)` turns around.
///
/// The estimate answers one question: how hard an exercise can this singer
/// handle? The level is the hardness at which they turn in a `cleanRun`, and
/// every exercise they have a score for is one reading of it: the exercise's own
/// hardness, moved up if they scored better than that and down if they scored
/// worse, at `scoreGain` points of level per point of score.
///
/// Not graded against the exercise's own average, tempting as that is now the
/// server hands one over. Par falls as exercises get harder — that is what the
/// average *is* — so grading against it would hand a singer most of an
/// exercise's hardness for merely attempting it, and one who failed everything
/// the suggestions put in front of them would still climb. The bar has to be the
/// same wherever it is measured; the exercise's average is how its hardness was
/// arrived at, and it does its work there.
///
/// Readings are averaged **per exercise, not per run**, so grinding one easy
/// exercise fifty times can't anchor the singer to it, and each one counts for
/// how recently it was last sung: a level earned two years ago is not the level
/// of today. What the readings don't account for goes to `starting`, so a singer
/// with nothing on record is treated as a beginner and their first few runs move
/// them a long way.
///
/// The one thing an average of readings can't be trusted with is a run that ran
/// out of scale. A hundred on something well within reach says the exercise was
/// easy for this singer, not how much easier — and averaged in flat, a shelf of
/// them holds a good singer down around the easy exercises they aced. Those
/// readings are therefore taken as the bounds they are (see `ceilingScore` and
/// `floorScore`): a maxed-out run may push the level up but never pull it down,
/// and a bottomed-out one the reverse. Which runs those are depends on where the
/// level lands, and the level on which runs count, so it is settled by repeating
/// the pass a handful of times.
enum SkillLevel {
    /// Where a singer with no rated runs sits: low, so the first suggestions
    /// are the easy end of the library rather than the middle of it.
    static let starting: Double = 25

    /// What that starting point weighs, counted in exercises. Two rated
    /// exercises pull the level half of the way to what they say; a dozen leave
    /// it barely felt.
    static let startingWeight: Double = 2

    /// The score that says an exercise is pitched exactly at the singer: a clean
    /// run, not a flawless one. Nothing in the app draws a line here — the
    /// result screen ramps its colour smoothly from 0 to 100 — so this is where
    /// the line for "sung well enough" is drawn.
    static let cleanRun: Double = 70

    /// Points of level per point of score above (or below) `cleanRun`. Two
    /// points of score to one of level, so a hundred reads as fifteen points of
    /// room above the exercise and a thirty as twenty points short of it: it
    /// takes an exercise near the singer's own level to place them precisely,
    /// which is what the suggestions keep putting in front of them.
    static let scoreGain: Double = 0.5

    /// At or above this, a run has run out of room at the top: it says the
    /// exercise was within the singer's reach without saying by how much, so it
    /// counts only towards a higher level, never a lower one.
    static let ceilingScore: Double = 95

    /// And at or below this, out of room at the bottom: the exercise was over
    /// the singer's head, which likewise says nothing about how far. (A run that
    /// scored nothing at all was silence or a walkout and was never recorded —
    /// see `ScoreHistory.record`.)
    static let floorScore: Double = 15

    /// How many times the level is worked out again with those bounds applied.
    /// It settles within two or three; the rest is headroom, and the pass stops
    /// early once it stops moving.
    static let settlingPasses = 5

    /// How long a run keeps half its say. Singers improve and skills fade, so
    /// what was sung this month counts for about twice what last quarter's did.
    static let halfLifeDays: Double = 60

    /// What a run never falls below, however old it is. Someone coming back
    /// after a year away has to sing their way back up, but they don't start
    /// again from nothing.
    static let oldestSay: Double = 0.05

    /// How far the suggested difficulties spread either side of the level (see
    /// `ExerciseStore.recommendedExercises`): most of a batch lands within this
    /// much of it.
    static let spread: Double = 25

    /// The hardness an exercise of this server difficulty sits at — the scale
    /// the stars and the level share. Clamped, since an average is only ever as
    /// well behaved as the scores it was taken over.
    nonisolated static func hardness(ofDifficulty difficulty: Double) -> Double {
        100 - min(max(difficulty, 0), 100)
    }

    /// What one exercise says about the singer: the hardness it sits at, moved
    /// by however far their typical score on it lands from a clean run.
    nonisolated static func level(difficulty: Double, score: Double) -> Double {
        let reading = hardness(ofDifficulty: difficulty) + (score - cleanRun) * scoreGain
        return min(max(reading, 0), 100)
    }

    /// What a run sung at `date` still counts for: 1 the moment it finished,
    /// halving every `halfLifeDays` and never dropping past `oldestSay`. A run
    /// dated in the future — a device whose clock was wrong when it was sung —
    /// counts as fresh rather than as more than fresh.
    nonisolated static func recency(of date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return max(pow(0.5, days / halfLifeDays), oldestSay)
    }

    /// One exercise's say: what it reads the singer at, the score that reading
    /// came from — which is what decides whether it is a measurement or only a
    /// bound — and how much of a say it gets.
    private nonisolated struct Reading {
        var level: Double
        var score: Double
        var weight: Double
    }

    /// The singer's level over every exercise they have both a score and a
    /// rating for. Each exercise contributes its own reading once, weighted by
    /// how recently it was last sung, against `starting` at `startingWeight`.
    nonisolated static func estimate(_ rated: [RatedExercise], now: Date = Date()) -> Double {
        var readings: [Reading] = []
        var total = 0.0
        for exercise in rated {
            // The singer's result on this exercise lately: an average over its
            // runs, so a one-off doesn't stand for the lot, weighted towards the
            // recent ones, so improvement shows up rather than being averaged
            // away against how it went the first time. What the exercise weighs
            // is that newest run — an exercise dropped a year ago has as little
            // to say as the runs it was dropped after.
            var scoreSum = 0.0
            var scoreWeight = 0.0
            var newest = 0.0
            for run in exercise.runs {
                let weight = recency(of: run.date, now: now)
                scoreSum += Double(run.score) * weight
                scoreWeight += weight
                newest = max(newest, weight)
            }
            guard scoreWeight > 0 else { continue }
            let score = scoreSum / scoreWeight
            readings.append(Reading(level: level(difficulty: exercise.difficulty, score: score),
                                    score: score, weight: newest))
            total += newest
        }
        guard total > 0 else { return starting }

        var settled = readings.reduce(0) { $0 + $1.level * $1.weight } / total
        for _ in 0..<settlingPasses {
            var sum = 0.0
            var weight = 0.0
            for reading in readings {
                // The runs that ran out of scale, kept only on the side they
                // actually argue for.
                if reading.score >= ceilingScore && reading.level < settled { continue }
                if reading.score <= floorScore && reading.level > settled { continue }
                sum += reading.level * reading.weight
                weight += reading.weight
            }
            guard weight > 0 else { break }
            let moved = abs(sum / weight - settled)
            settled = sum / weight
            if moved < 0.05 { break }
        }

        // Blended against `starting` at what *every* reading weighs, not only
        // what the surviving ones do: a reading set aside above says this
        // exercise couldn't place the singer, not that they have less practice
        // behind them than they do.
        //
        // Rounded to a tenth, which is finer than anything drawn from it can
        // show and keeps rounding dust out of the profile document's diff.
        return ((starting * startingWeight + settled * total)
                / (startingWeight + total) * 10).rounded() / 10
    }
}

/// The singer's skill level as the app carries it around: worked out by
/// `SkillLevel` whenever the scores or the server's difficulties change, kept in
/// UserDefaults so the Home tab has it on the first frame, and mirrored into the
/// synced profile document (see `UserProfile.skillLevel`).
///
/// It holds what the suggestions need alongside it — how hard each exercise in
/// the library is, keyed by the id the library stores it under. That keeps the
/// Home tab from having to observe CommunitySync's counts, where a heart tapped
/// in the Community tab would rebuild the whole Home list for nothing; this
/// object changes only when a run is scored or the difficulties are fetched.
@MainActor
final class SkillLevelStore: ObservableObject {
    static let shared = SkillLevelStore()

    /// How hard an exercise this singer can handle, 0-100 — the scale the
    /// difficulty stars fill along, so it can be drawn with the same five of
    /// them. See `SkillLevel` for what moves it.
    @Published private(set) var level: Double

    /// How hard each exercise in the library is, 0-100 on that same scale, for
    /// the ones the server has an average for. A missing entry means unrated:
    /// nobody has finished it yet, or its difficulty hasn't been fetched.
    @Published private(set) var hardness: [UUID: Double] = [:]

    private static let levelKey = "skillLevel"

    private weak var store: ExerciseStore?

    /// The level a restored profile arrived with, if one did — see `adopt`. Kept
    /// so a restore whose score histories didn't survive the server's size limit
    /// isn't read as a singer who has never sung.
    private var restoredLevel: Double?

    /// Derived public ids, remembered: each one costs a SHA-1 (see
    /// PublicIdentifier) and the whole library is walked every time a run is
    /// scored.
    private var publicIDs: [UUID: UUID] = [:]

    private init() {
        level = UserDefaults.standard.object(forKey: Self.levelKey) as? Double ?? SkillLevel.starting
    }

    /// Call once at launch, after ProfileSync has restored the library and its
    /// scores and before CommunitySync fetches the difficulties — which asks for
    /// a second pass of its own once they land.
    func start(with store: ExerciseStore) {
        self.store = store
        recompute()
    }

    /// Works the level and the hardness map out again from the scores on this
    /// device and the difficulties CommunitySync has fetched. Cheap enough to
    /// run on every finished run.
    func recompute() {
        let difficulties = CommunitySync.shared.counts.difficulties
        var hardness: [UUID: Double] = [:]
        for exercise in store?.exercises ?? [] {
            guard let difficulty = difficulties[publicID(of: exercise.id)] else { continue }
            hardness[exercise.id] = SkillLevel.hardness(ofDifficulty: difficulty)
        }
        self.hardness = hardness

        let histories = ScoreHistory.all()
        var rated: [RatedExercise] = []
        for (idString, runs) in histories where !runs.isEmpty {
            guard let id = UUID(uuidString: idString),
                  // An exercise sung from the Community tab is scored under the
                  // public id it was listed by, so its difficulty is already
                  // filed under that id; everything in the library is stored
                  // under a private id the public one has to be derived from.
                  let difficulty = difficulties[publicID(of: id)] ?? difficulties[id]
            else { continue }
            rated.append(RatedExercise(difficulty: difficulty, runs: runs))
        }
        // Nothing sung at all — a new singer, or Settings ▸ Reset ▸ Scores —
        // puts the level back to where one starts. Unless a restore has just
        // handed one over without the scores behind it: the profile document
        // drops its oldest runs to fit the server's size limit and can arrive
        // with none left, and there the level it carried is all there is.
        guard !histories.isEmpty else { return setLevel(restoredLevel ?? SkillLevel.starting) }
        // Runs, but none on an exercise the server has rated: no difficulty has
        // been fetched yet, or nothing sung has one. Whatever level is on file —
        // a restored profile's included — says more than a beginner's would, so
        // it stays rather than being reset on every launch until a fetch lands.
        guard !rated.isEmpty else { return }
        setLevel(SkillLevel.estimate(rated))
    }

    /// Takes the level from a profile restored off the server, so a reinstall
    /// opens at the level it left off at instead of as a beginner until the
    /// difficulties have been fetched and the restored scores worked through
    /// again. Only when this device has none of its own: a restore the server
    /// failed on is retried on a later launch, and by then the singer may have
    /// sung their way to a level here.
    func adopt(restored: Double) {
        guard UserDefaults.standard.object(forKey: Self.levelKey) == nil else { return }
        restoredLevel = min(max(restored, 0), 100)
        setLevel(restoredLevel ?? SkillLevel.starting)
    }

    /// Written through to UserDefaults, which is both how the Home tab has a
    /// level to draw before anything is worked out and how the new one reaches
    /// the server: ProfileSync uploads on any defaults change.
    private func setLevel(_ new: Double) {
        guard new != level else { return }
        level = new
        UserDefaults.standard.set(new, forKey: Self.levelKey)
    }

    private func publicID(of id: UUID) -> UUID {
        if let known = publicIDs[id] { return known }
        let derived = PublicIdentifier.exercise(id)
        publicIDs[id] = derived
        return derived
    }
}
