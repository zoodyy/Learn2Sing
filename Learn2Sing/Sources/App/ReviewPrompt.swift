//
//  ReviewPrompt.swift
//  Learn2Sing
//
//  Apple's own rating pop-up ("Enjoying Learn2Sing?"): when the app may ask for
//  it, which run earns it, and the moment it goes up, which is on the screen
//  after that run's score screen rather than on the score screen itself.
//

import SwiftUI
import Combine
import UIKit

/// How long the app has been open on this install, counted while it is in the
/// foreground: what the rating pop-up waits for before it is ever asked for.
///
/// Never less than the practice time the profile carries (see `PracticeLog`),
/// which is time spent in the app too. That is what a reinstall restores, and
/// what an install from before this was counted already has, so neither has to
/// start again from nothing.
///
/// The count lives in UserDefaults outside `UserSettings`, like `CategoryHint`'s:
/// it records what has happened on this install rather than something the singer
/// chose.
enum AppUsageTime {
    private static let key = "foregroundSeconds"

    /// When the app last came to the foreground, while it is still there.
    private static var activeSince: Date?

    /// Starts counting. Called each time the app becomes active; a second call
    /// while it is already counting changes nothing.
    static func resume() {
        guard activeSince == nil else { return }
        activeSince = Date()
    }

    /// Adds the time since `resume` to the stored count and stops. Called on the
    /// way to the background, which is also the last the app hears before being
    /// closed from the app switcher.
    static func pause() {
        guard let start = activeSince else { return }
        activeSince = nil
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return }
        UserDefaults.standard.set(stored + elapsed, forKey: key)
    }

    /// Seconds spent in the app, the stretch it has been open for right now
    /// included.
    static var seconds: Double {
        let running = activeSince.map { Date().timeIntervalSince($0) } ?? 0
        let practised = PracticeLog.all().values.reduce(0, +)
        return max(stored + running, Double(practised))
    }

    private static var stored: Double { UserDefaults.standard.double(forKey: key) }
}

/// Asks for a rating with Apple's own pop-up, at the happiest moment the app can
/// find: just after a new personal best, once the singer knows the app well.
///
/// Three things have to line up:
/// - **Five hours in the app** (`AppUsageTime`). Advice on when to ask is written
///   in sessions and days rather than hours (three to seven sessions, a week or
///   two after installing), and five hours is already past all of it.
/// - **A third of a year since it last asked**, so at most three times in any
///   365 days. That is also the most Apple's pop-up ever shows itself, and it
///   shows nothing at all to someone who has turned it off, or who rated the
///   app within the last year.
/// - **A run that earned it**: a new best on its exercise, scored above 90%. A
///   singer who has never scored that high anywhere gets it on a new best alone,
///   rather than never.
///
/// The run only makes the pop-up owed. It goes up once the exercise is left, on
/// whatever screen comes next: on the score screen the singer is still reading
/// their result, or about to open the run up to see where it came from, and
/// would wave the pop-up away to get back to that.
///
/// The date it last asked stays on this device, like `CategoryHint`'s flags:
/// Apple counts its own showings per device too.
@MainActor
final class ReviewPrompt: ObservableObject {
    static let shared = ReviewPrompt()

    /// How long the app has to have been used before it asks at all.
    static let requiredUsage: TimeInterval = 5 * 60 * 60
    /// The shortest time between two asks: a third of a year, so four can never
    /// fall inside one.
    static let minimumGap: TimeInterval = 122 * 24 * 60 * 60
    /// The score a new best has to beat, unless nothing ever has.
    static let greatScore = 90

    private static let lastAskedKey = "reviewPromptLastAsked"

    /// Bumped each time the pop-up should go up. `ContentView` answers it, since
    /// the action that puts it up comes out of a view's environment.
    @Published private(set) var askCount = 0

    /// Set by a run that earned the pop-up, until it goes up. Kept in memory
    /// only: an app closed in between asks again at the next new best instead,
    /// rather than straight after a launch.
    private var isOwed = false

    /// How many exercise screens are showing: the run, its score and its review,
    /// which are one `PlaybackView`. Counted rather than flagged, because each
    /// tab can have one open, and switching between two of them may bring the
    /// new one up before the old one has gone.
    private var exerciseScreens = 0

    /// The ask waiting for the next screen to settle.
    private var pendingAsk: Task<Void, Never>?

    private init() {}

    /// Whether the time in the app and the time since the last ask both allow
    /// asking now, whatever the run.
    private var mayAsk: Bool {
        guard AppUsageTime.seconds >= Self.requiredUsage else { return false }
        guard let last = UserDefaults.standard.object(forKey: Self.lastAskedKey) as? Date else {
            return true
        }
        return Date().timeIntervalSince(last) >= Self.minimumGap
    }

    /// Hears about every run that reached a score, with whether it beat every
    /// earlier one on its exercise, and decides whether it earned the pop-up.
    func runScored(_ score: Int, isPersonalRecord: Bool) {
        guard !isOwed, isPersonalRecord, mayAsk else { return }
        // A new best that is still short of great counts only for a singer who
        // has never scored above it, on any exercise. This run can't be the one
        // that has, so it makes no difference whether it is saved yet.
        let isGreat = score > Self.greatScore
            || !ScoreHistory.all().values.joined().contains { $0.score > Self.greatScore }
        guard isGreat else { return }
        isOwed = true
    }

    /// One of the exercise's screens came up, which puts off any ask until the
    /// singer has left it again.
    func exerciseScreenAppeared() {
        exerciseScreens += 1
        pendingAsk?.cancel()
        pendingAsk = nil
    }

    /// One of the exercise's screens went. Once none is left, an owed pop-up goes
    /// up a second later, when the next screen has had time to come in and be
    /// seen. Starting another exercise within that second puts it off again.
    func exerciseScreenDisappeared() {
        exerciseScreens = max(exerciseScreens - 1, 0)
        guard isOwed, exerciseScreens == 0 else { return }
        pendingAsk?.cancel()
        pendingAsk = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.askIfStillOwed()
        }
    }

    private func askIfStillOwed() {
        pendingAsk = nil
        guard isOwed, exerciseScreens == 0,
              UIApplication.shared.applicationState == .active
        else { return }
        isOwed = false
        UserDefaults.standard.set(Date(), forKey: Self.lastAskedKey)
        askCount += 1
    }
}
