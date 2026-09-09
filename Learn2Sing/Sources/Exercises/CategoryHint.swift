//
//  CategoryHint.swift
//  Learn2Sing
//
//  The one-off hint the Exercises tab points at a category name: that holding one
//  down is what opens the screen where categories are renamed and rearranged.
//

import Foundation

/// Whether the exercise list still owes the singer that hint, and the runs it
/// waits for before giving it.
///
/// It waits for five finished exercises rather than appearing on the first launch:
/// there is nothing to arrange yet in a library nobody has used, and a bubble over
/// a screen being seen for the first time is one more thing in the way. By the
/// fifth run the list is familiar and worth tidying.
///
/// Both keys live in UserDefaults and deliberately outside `UserSettings`, like the
/// tutorial's own flag and the microphone calibration's: they record what has
/// happened on this install rather than something the singer chose.
enum CategoryHint {
    /// How many finished exercises come before the hint.
    static let runsBeforeShowing = 5

    private static let finishedRunsKey = "finishedExerciseRuns"
    private static let shownKey = "didShowCategoryHint"

    /// What the bubble says. It is the very bubble a press and hold puts up
    /// (see SettingHelp), so it reads like the rest of them.
    static var text: String {
        L("Press and hold any category name to rearrange your categories, rename them, or add new ones.")
    }

    /// Counts a run that played through to the end, whichever tab it was started
    /// from. Nothing reads the count once the hint has been given, so it stops
    /// being kept then.
    static func recordFinishedExercise() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(defaults.integer(forKey: finishedRunsKey) + 1, forKey: finishedRunsKey)
    }

    /// Whether the exercise list should put the hint up as it comes on screen.
    static var isDue: Bool {
        let defaults = UserDefaults.standard
        return !defaults.bool(forKey: shownKey)
            && defaults.integer(forKey: finishedRunsKey) >= runsBeforeShowing
    }

    /// Remember it has been given. Set the moment the bubble goes up rather than
    /// when it is tapped away: all it asks is that one line be read, and an app
    /// closed while it was on screen has still shown it. Waiting for the tap would
    /// be a hint that can come back a second time.
    static func markShown() {
        UserDefaults.standard.set(true, forKey: shownKey)
    }
}
