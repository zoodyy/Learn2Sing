import Foundation

/// When an exercise came into the library and when it was last changed, as whole
/// seconds since 1970 — what the Exercises tab's "Newest First" and "Recently
/// Updated" orders sort by. Plain data, like `ScoreEntry`, so the profile document
/// it rides along in can encode it from anywhere.
nonisolated struct ExerciseTimestamps: Codable, Equatable {
    /// When the exercise was made, downloaded or imported. nil for one that was
    /// already in the library before these dates were recorded.
    var added: Int? = nil
    /// When its settings, name, description or pattern last changed. nil until
    /// the first change, which leaves "Recently Updated" to go by `added`.
    var edited: Int? = nil
}

/// The dates behind the Exercises tab's date orders, kept in UserDefaults under
/// one key beside the library and carried in the synced profile.
///
/// Kept beside the exercises rather than on them. An `Exercise` is compared
/// whole — `discardIfUntouched` and the bundled-exercise reset both ask whether
/// one is still exactly what it was — and it is the very document a public
/// exercise is published as, so a date stamped onto it would read as a change
/// to both and republish exercises nobody had touched.
///
/// Exercises that were in the library before the dates were recorded have none.
/// They are older than every exercise that has one, and the orders treat them
/// that way (see `ExerciseSort.ordered`).
enum ExerciseDates {
    static let storageKey = "exerciseDates"

    /// Every recorded exercise's dates, keyed by exercise UUID string.
    static func all() -> [String: ExerciseTimestamps] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([String: ExerciseTimestamps].self, from: data)
        else { return [:] }
        return saved
    }

    static func timestamps(for id: UUID) -> ExerciseTimestamps? {
        all()[id.uuidString]
    }

    /// Records exercises as having just come into the library, with no edit yet.
    static func markAdded(_ ids: [UUID], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        var dates = all()
        for id in ids {
            dates[id.uuidString] = ExerciseTimestamps(added: seconds(date))
        }
        save(dates)
    }

    /// Records an exercise as having just been changed.
    static func markEdited(_ id: UUID, at date: Date = Date()) {
        var dates = all()
        dates[id.uuidString, default: ExerciseTimestamps()].edited = seconds(date)
        save(dates)
    }

    /// Puts one exercise's dates back to what they were, for an undo that puts
    /// the exercise itself back: the edits it takes away take their date along.
    static func restore(_ timestamps: ExerciseTimestamps?, for id: UUID) {
        var dates = all()
        guard dates[id.uuidString] != timestamps else { return }
        dates[id.uuidString] = timestamps
        save(dates)
    }

    static func remove(_ id: UUID) {
        var dates = all()
        guard dates.removeValue(forKey: id.uuidString) != nil else { return }
        save(dates)
    }

    /// Merges dates restored from the server into whatever this device has. The
    /// same exercise can carry a date on both — a bundled one stamped as this
    /// install seeded it, say — so each keeps the earlier of its two adds and
    /// the later of its two edits, which are the ones that really happened.
    static func merge(_ restored: [String: ExerciseTimestamps]) {
        guard !restored.isEmpty else { return }
        var dates = all()
        for (key, remote) in restored {
            let local = dates[key] ?? ExerciseTimestamps()
            dates[key] = ExerciseTimestamps(
                added: [local.added, remote.added].compactMap { $0 }.min(),
                edited: [local.edited, remote.edited].compactMap { $0 }.max())
        }
        save(dates)
    }

    private static func seconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded())
    }

    private static func save(_ dates: [String: ExerciseTimestamps]) {
        guard let data = try? JSONEncoder().encode(dates) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
