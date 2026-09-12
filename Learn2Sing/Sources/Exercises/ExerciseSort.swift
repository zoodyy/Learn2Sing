import Foundation

/// The order the Exercises tab lists the library in, picked from the sort menu in
/// its toolbar and remembered across launches — and across reinstalls, since it
/// rides along in the synced settings like the Community tab's order does.
///
/// Unlike the Community tab's orders, these are all worked out on the device from
/// what the library already knows about each exercise. They arrange the exercises
/// inside each category, or across the whole library while the menu's "Ignore
/// Categories" is on. Which exercises are listed is the filters' and the search's
/// business, never the order's.
enum ExerciseSort: String, CaseIterable, Identifiable {
    /// The user's own arrangement: the library as they dragged it into shape, with
    /// favourites held at the top of each category. The one order a row can be
    /// dragged in, since it is the one order a drop means anything to.
    case own
    /// Easiest first, by the difficulty an intro screen's stars show.
    case difficulty
    /// Best sung first, by the average of the user's most recent scores.
    case easiestForMe
    /// Most recently added to the library first.
    case newest
    /// Most recently changed first.
    case recentlyUpdated
    /// A to Z by the name each row shows.
    case alphabetical

    var id: String { rawValue }

    /// The keys the sort menu writes with @AppStorage, which the synced settings
    /// read as well.
    static let storageKey = "exercisesSort"
    static let reversedKey = "exercisesSortReversed"
    static let ignoresCategoriesKey = "exercisesSortIgnoresCategories"

    /// How many of an exercise's most recent scores "Easiest for Me" averages:
    /// enough that one bad run doesn't sink it, few enough that it follows how
    /// the singer does on the exercise now rather than how they did when they
    /// first tried it.
    static let recentScoreCount = 5

    var label: String {
        switch self {
        case .own: L("Own Sorting")
        case .difficulty: L("Difficulty")
        case .easiestForMe: L("Easiest for Me")
        case .newest: L("Newest First")
        case .recentlyUpdated: L("Recently Updated")
        case .alphabetical: L("Alphabetical")
        }
    }

    var systemImage: String {
        switch self {
        case .own: "line.3.horizontal"
        case .difficulty: "chart.bar"
        case .easiestForMe: "chart.line.uptrend.xyaxis"
        case .newest: "clock"
        case .recentlyUpdated: "arrow.triangle.2.circlepath"
        case .alphabetical: "textformat.abc"
        }
    }

    /// Whether the sort menu offers its reverse switch for this order. The user's
    /// own arrangement has no other end anyone asked for, and turned upside down
    /// a drop would land somewhere other than where it was aimed, so the switch
    /// is hidden there — and a remembered one ignored — as the Community tab does
    /// for "Hot".
    var isReversible: Bool {
        switch self {
        case .own: false
        case .difficulty, .easiestForMe, .newest, .recentlyUpdated, .alphabetical: true
        }
    }

    /// Whether the sort menu offers "Ignore Categories" for this order. The user's
    /// own arrangement is made inside the categories — a drag lands a row in one
    /// — so it is always shown in them, and a remembered pick is ignored.
    var canIgnoreCategories: Bool {
        switch self {
        case .own: false
        case .difficulty, .easiestForMe, .newest, .recentlyUpdated, .alphabetical: true
        }
    }
}

// MARK: - Ordering

extension ExerciseSort {
    /// `exercises` in this order, with the menu's reverse switch applied where it
    /// is offered. `exercises` is taken to be in the library's own order, which is
    /// what every tie falls back to: two exercises the order can't tell apart stay
    /// the way round the user has them.
    ///
    /// An exercise the order knows nothing about — nobody has rated it, or the
    /// user has never finished it — goes after every one it does know about, in
    /// either direction: reversed, "Difficulty" is hardest first, and an unrated
    /// exercise isn't that. Exercises without a date are the exception. Having
    /// none says they were in the library before dates were recorded, which
    /// makes them the oldest, so a reversed date order puts them first.
    ///
    /// `hardness` is SkillLevelStore's, handed in so the screen calling this is
    /// the one observing it.
    func ordered(_ exercises: [Exercise], reversed: Bool, hardness: [UUID: Double]) -> [Exercise] {
        let flipped = reversed && isReversible
        switch self {
        case .own:
            return exercises
        case .difficulty:
            return Self.arranged(exercises, by: exercises.map { hardness[$0.id] },
                                 smallestFirst: !flipped)
        case .easiestForMe:
            return Self.arranged(exercises, by: exercises.map { Self.recentAverageScore(of: $0.id) },
                                 smallestFirst: flipped)
        case .newest, .recentlyUpdated:
            let dates = ExerciseDates.all()
            let keys = exercises.map { exercise -> Double? in
                let stamps = dates[exercise.id.uuidString]
                let date = self == .newest ? stamps?.added : stamps?.edited ?? stamps?.added
                return date.map { Double($0) } ?? -.infinity
            }
            return Self.arranged(exercises, by: keys, smallestFirst: flipped)
        case .alphabetical:
            return Self.arranged(exercises, by: Self.alphabeticalRanks(of: exercises),
                                 smallestFirst: !flipped)
        }
    }

    /// `exercises` sorted by `keys`, which line up with them one for one: the
    /// smallest key first when `smallestFirst`, the largest otherwise. A nil key
    /// goes last whichever way round, and equal keys keep the order `exercises`
    /// came in.
    private static func arranged(_ exercises: [Exercise], by keys: [Double?],
                                 smallestFirst: Bool) -> [Exercise] {
        exercises.indices
            .sorted { i, j in
                switch (keys[i], keys[j]) {
                case let (left?, right?) where left != right:
                    return smallestFirst ? left < right : left > right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return i < j
                }
            }
            .map { exercises[$0] }
    }

    /// The average of the user's `recentScoreCount` most recent scores on an
    /// exercise, or nil for one they have never finished.
    private static func recentAverageScore(of id: UUID) -> Double? {
        let recent = ScoreHistory.entries(for: id)
            .sorted { $0.date > $1.date }
            .prefix(recentScoreCount)
        guard !recent.isEmpty else { return nil }
        return Double(recent.map(\.score).reduce(0, +)) / Double(recent.count)
    }

    /// Each exercise's place in the A-to-Z order of the name its row shows, as a
    /// number `arranged` can sort by. Compared in the app's language rather than
    /// the device's, since that is the language the names are shown in, and
    /// digit runs as numbers so "Scale 10" comes after "Scale 9". Names that
    /// compare equal share a place, so they keep the library's order either way
    /// round.
    private static func alphabeticalRanks(of exercises: [Exercise]) -> [Double?] {
        let locale = LanguageManager.shared.language.locale
        let names = exercises.map(\.localizedName)
        func compare(_ i: Int, _ j: Int) -> ComparisonResult {
            names[i].compare(names[j], options: [.caseInsensitive, .numeric, .widthInsensitive],
                             range: nil, locale: locale)
        }
        let byName = names.indices.sorted { i, j in
            let result = compare(i, j)
            return result == .orderedAscending || (result == .orderedSame && i < j)
        }
        var ranks = [Double?](repeating: nil, count: names.count)
        var rank = 0.0
        for (position, index) in byName.enumerated() {
            if position > 0, compare(byName[position - 1], index) != .orderedSame { rank += 1 }
            ranks[index] = rank
        }
        return ranks
    }
}
