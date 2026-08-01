//
//  BundledLocalization.swift
//  Learn2Sing
//
//  The exercises that ship in BundledExercises.json are stored in English — they
//  are seeded into the library on first launch and then belong to the user, who
//  may rename or edit them. So their names, descriptions and categories are
//  translated on the way to the screen rather than in storage, which also keeps
//  exports, community uploads and the server profile language-independent.
//
//  Only content that came from the app is translated. Anything the user typed is
//  shown exactly as they wrote it.
//

import Foundation

extension Exercise {
    /// The name to display: translated for the exercises that shipped with the
    /// app, left alone for the user's own (including community downloads, which
    /// get a fresh id when copied in).
    var localizedName: String {
        ExerciseStore.bundledExerciseIDs.contains(id) ? L(name) : name
    }

    /// The description to display, under the same rule as `localizedName`.
    var localizedDetails: String {
        ExerciseStore.bundledExerciseIDs.contains(id) ? L(details) : details
    }
}

enum ExerciseCategoryName {
    /// The categories the app creates itself: the five the bundled exercises are
    /// grouped into, the always-present "No Category", and the Home tab's four
    /// built-ins. They're stored — and compared, exported and synced — in English,
    /// so only the display side is translated. A category the user creates keeps
    /// the name they gave it.
    static let appProvided: Set<String> = Set([
        "Tone", "Scales", "Articulation", "Agility", "Range", ExerciseStore.noCategoryName,
    ] + HomeCategories.all)

    static func localized(_ name: String) -> String {
        appProvided.contains(name) ? L(name) : name
    }
}

enum VisualTemplateName {
    /// The visual template seeded from the app bundle on first launch. Templates
    /// the user saves or imports keep the name they were given.
    static let appProvided: Set<String> = ["SimplestTemplate"]

    static func localized(_ name: String) -> String {
        appProvided.contains(name) ? L(name) : name
    }
}
