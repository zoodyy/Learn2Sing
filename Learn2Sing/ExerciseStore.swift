import SwiftUI
import Combine

/// An ordered list of exercises the user assembles on the Home tab. Unlike
/// categories, routines are keyed by id — names are free-form and don't have
/// to be unique — and an exercise can appear in any number of routines.
struct Routine: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    /// Shown on the routine's intro screen, like an exercise's `details`.
    var details: String = ""
    /// The routine's exercises in the user's order. Never contains duplicates.
    var exerciseIDs: [UUID] = []

    init(name: String) { self.name = name }

    private enum CodingKeys: String, CodingKey {
        case id, name, details, exerciseIDs
    }

    /// Hand-written so routines saved before a field existed still decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        exerciseIDs = try c.decodeIfPresent([UUID].self, forKey: .exerciseIDs) ?? []
    }
}

/// Single source of truth for the user's exercises and their MIDI patterns.
/// Backed by UserDefaults (exercise list under `exercises`, each pattern under
/// `midi_<uuid>`) so it stays compatible with the existing EditingView/PlaybackView.
final class ExerciseStore: ObservableObject {
    @Published var exercises: [Exercise] = []
    /// User-defined categories used to group exercises in the list, in display order.
    @Published var categories: [String] = []
    /// Exercise ids ordered by when they last played through to the end, newest
    /// first. Drives the Home tab's "Recent" category.
    @Published var recentlyPlayed: [UUID] = []
    /// When each exercise last played through to the end. Unlike `recentlyPlayed`
    /// this is kept for every exercise, not just the newest handful, so the Home
    /// tab's "Recommended" category can find the ones played longest ago.
    @Published var lastPlayed: [UUID: Date] = [:]
    /// The user's routines in display order. Shown in the Home tab's "Routines"
    /// category.
    @Published var routines: [Routine] = []
    /// The user's favourite exercises in display order. Shown in the Home tab's
    /// "Favourites" category. Never contains duplicates.
    @Published var favourites: [UUID] = []
    /// The exercises the Home tab's "Recommended" category may draw from. Worked
    /// out rather than stored: an exercise is in it when
    /// "Automatically whitelisted exercises" covers the group it came from, and
    /// the user hasn't said otherwise for that exercise under
    /// Settings ▸ Exercises ▸ Whitelisted Exercises — see
    /// `refreshRecommendationWhitelist`.
    @Published private(set) var recommendationWhitelist: Set<UUID> = []

    /// The groups of exercises whitelisted for recommendations automatically,
    /// from Settings ▸ Exercises. Every group by default, so a library recommends
    /// from all of itself until the user says otherwise — which is also what an
    /// upgrade lands on, the whitelist not having recorded until now which of its
    /// omissions were the user's doing.
    @Published private(set) var autoWhitelistOrigins = RecommendedExercises.storedAutoWhitelist

    /// The exercises the user has whitelisted (or un-whitelisted) by hand, which
    /// is to say the exceptions to the setting above: an entry is only kept while
    /// it disagrees with what that setting says about the exercise's group. So
    /// un-ticking a bundled exercise survives "Bundled Exercises" being switched
    /// off and on again, and one ticked while its group was off stays ticked when
    /// the group is switched on and off again.
    private var whitelistOverrides: [UUID: Bool] = [:]

    /// The always-present home for exercises not assigned to any other category:
    /// new exercises start here, deleting a category moves its exercises here, and
    /// it can never itself be deleted.
    static let noCategoryName = "No Category"

    private let storeKey = "exercises"
    private let categoriesKey = "categories"
    private let recentlyPlayedKey = "recentlyPlayed"
    private let lastPlayedKey = "lastPlayed"
    private let routinesKey = "routines"
    private let favouritesKey = "favourites"
    private let whitelistOverridesKey = "recommendationWhitelistOverrides"
    private let bundledImportedKey = "didImportBundledExercises"
    private let lastPlayedSeededKey = "didSeedLastPlayed"

    init() {
        load()
        loadCategories()
        loadRecentlyPlayed()
        loadLastPlayed()
        loadRoutines()
        loadFavourites()
        loadWhitelistOverrides()
        importBundledIfNeeded()
        adoptNoCategory()
        enforceBundledPrivacy()
        seedLastPlayedIfNeeded()
        // Last, so it sees the library the steps above settled on. Every one of
        // them that changed it has refreshed the whitelist already (`save` does
        // that); this covers the launch where none of them had anything to do.
        refreshRecommendationWhitelist()
    }

    // MARK: - Bundled exercises

    /// The exercise bundle shipped inside the app — the library exactly as a fresh
    /// install seeds it. Decoded once and kept, since Settings ▸ Reset compares
    /// against it to find the bundled exercises the user has changed.
    static let bundledBundle: ExerciseBundle? = {
        guard let url = Bundle.main.url(forResource: "BundledExercises", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ExerciseBundle.self, from: data)
    }()

    /// Ids of the exercises shipped in the app bundle. The JSON carries fixed
    /// UUIDs, so these are identical on every install and survive renames.
    static let bundledExerciseIDs: Set<UUID> = Set(bundledBundle?.exercises.map(\.id) ?? [])

    /// Bundled exercises can't be shared: their settings show no visibility
    /// picker (a copy made via Download can be shared — it gets a fresh id).
    func isBundled(_ id: UUID) -> Bool {
        Self.bundledExerciseIDs.contains(id)
    }

    /// Older versions allowed publishing bundled exercises, so stored data and
    /// imports may still carry .public on them — put those back to private.
    private func enforceBundledPrivacy() {
        var changed = false
        for i in exercises.indices where exercises[i].visibility == .public
            && Self.bundledExerciseIDs.contains(exercises[i].id) {
            exercises[i].visibility = .private
            exercises[i].uploaderName = ""
            changed = true
        }
        if changed { save() }
    }

    /// Make sure the "No Category" group exists and owns every exercise without a
    /// category, migrating data written before this group existed.
    private func adoptNoCategory() {
        if !categories.contains(Self.noCategoryName) {
            categories.append(Self.noCategoryName)
            saveCategories()
        }
        var changed = false
        for i in exercises.indices where exercises[i].category.isEmpty {
            exercises[i].category = Self.noCategoryName
            changed = true
        }
        if changed { save() }
    }

    /// On first launch, seed the library with the exercises shipped in the app
    /// bundle. Gated by a flag so a user's later edits/deletions are never undone.
    private func importBundledIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: bundledImportedKey) else { return }
        guard let bundle = Self.bundledBundle else { return }
        importBundle(bundle)
        UserDefaults.standard.set(true, forKey: bundledImportedKey)
    }

    // MARK: - Exercise list persistence

    func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let saved = try? JSONDecoder().decode([Exercise].self, from: data)
        else { return }
        exercises = saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(exercises) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
        // The whitelist is drawn from the library, so it follows every change to
        // it: an exercise added, downloaded or imported is whitelisted (or not)
        // by the group it belongs to, and a deleted one drops out.
        refreshRecommendationWhitelist()
    }

    // MARK: - Categories

    func loadCategories() {
        guard let data = UserDefaults.standard.data(forKey: categoriesKey),
              let saved = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        categories = saved
    }

    private func saveCategories() {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        UserDefaults.standard.set(data, forKey: categoriesKey)
    }

    func addCategory(_ name: String) {
        guard !name.isEmpty, !categories.contains(name) else { return }
        categories.append(name)
        saveCategories()
    }

    /// Reorder the user's categories (drives the grouping order in the list).
    func moveCategory(from source: IndexSet, to destination: Int) {
        categories.move(fromOffsets: source, toOffset: destination)
        saveCategories()
    }

    /// Rename a category, carrying its exercises over to the new name. Refused
    /// (returning false) when the new name is taken, empty, or the source is the
    /// undeletable "No Category" group.
    @discardableResult
    func renameCategory(_ name: String, to newName: String) -> Bool {
        guard name != Self.noCategoryName,
              !newName.isEmpty,
              newName != name,
              !categories.contains(newName),
              let idx = categories.firstIndex(of: name)
        else { return false }
        categories[idx] = newName
        saveCategories()
        var changed = false
        for i in exercises.indices where exercises[i].category == name {
            exercises[i].category = newName
            changed = true
        }
        if changed { save() }
        return true
    }

    /// Move a dragged exercise so it lands in `category`, positioned just before the
    /// exercise `targetID` (or at the end of that category when `targetID` is nil).
    /// Sections in the list are rendered by filtering on `category`, so only the
    /// exercise's own `category` and its order relative to its new siblings matter.
    func moveExercise(_ id: UUID, toCategory category: String, before targetID: UUID?) {
        guard id != targetID,
              let from = exercises.firstIndex(where: { $0.id == id }) else { return }
        var moved = exercises.remove(at: from)
        moved.category = category
        if let targetID, let to = exercises.firstIndex(where: { $0.id == targetID }) {
            exercises.insert(moved, at: to)
        } else if let lastInCategory = exercises.lastIndex(where: { $0.category == category }) {
            exercises.insert(moved, at: lastInCategory + 1)
        } else {
            exercises.append(moved)
        }
        save()
    }

    /// Remove a category and move its exercises into "No Category" so none are
    /// deleted along with it. The "No Category" group itself can't be removed.
    func deleteCategory(_ name: String) {
        guard name != Self.noCategoryName else { return }
        categories.removeAll { $0 == name }
        saveCategories()
        var changed = false
        for i in exercises.indices where exercises[i].category == name {
            exercises[i].category = Self.noCategoryName
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Recently played

    private func loadRecentlyPlayed() {
        guard let data = UserDefaults.standard.data(forKey: recentlyPlayedKey),
              let saved = try? JSONDecoder().decode([UUID].self, from: data)
        else { return }
        recentlyPlayed = saved
    }

    private func saveRecentlyPlayed() {
        guard let data = try? JSONEncoder().encode(recentlyPlayed) else { return }
        UserDefaults.standard.set(data, forKey: recentlyPlayedKey)
    }

    /// Move an exercise to the front of the recently-played order. Called by the
    /// playback screen when a run plays through to the end.
    func markPlayed(_ id: UUID) {
        recentlyPlayed.removeAll { $0 == id }
        recentlyPlayed.insert(id, at: 0)
        // Keep a few more than the Home tab shows so deleted exercises don't
        // thin the visible list out.
        if recentlyPlayed.count > 20 {
            recentlyPlayed.removeLast(recentlyPlayed.count - 20)
        }
        saveRecentlyPlayed()
        lastPlayed[id] = Date()
        saveLastPlayed()
    }

    // MARK: - Last played

    private func loadLastPlayed() {
        guard let data = UserDefaults.standard.data(forKey: lastPlayedKey),
              let saved = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return }
        lastPlayed = saved.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    private func saveLastPlayed() {
        let encodable = lastPlayed.reduce(into: [String: Date]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: lastPlayedKey)
    }

    /// Libraries that predate the play timestamps have none, which would make
    /// every exercise look never-played. Seed them once from each exercise's
    /// newest recorded score — the closest record of when it last ran — after
    /// which `markPlayed` keeps them current.
    private func seedLastPlayedIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: lastPlayedSeededKey) else { return }
        for exercise in exercises where lastPlayed[exercise.id] == nil {
            if let played = ScoreHistory.entries(for: exercise.id).map(\.date).max() {
                lastPlayed[exercise.id] = played
            }
        }
        saveLastPlayed()
        UserDefaults.standard.set(true, forKey: lastPlayedSeededKey)
    }

    // MARK: - Recommendations

    /// The exercises the Home tab's "Recommended" category suggests, easiest
    /// first and ramping up to the hardest of them, adding up to at least
    /// `minutes` of practice — the daily practice time from Settings ▸ Exercises.
    /// The suggestion runs a little over rather than under, and only comes out
    /// short when the whole whitelist is shorter than that.
    ///
    /// Every whitelisted exercise is in the running — that starts out as the
    /// ones that shipped with the app, and the user edits it under
    /// Settings ▸ Exercises — and each is drawn with a chance made of two things:
    ///
    /// * **How long ago it was last sung.** The whitelist is ranked longest-ago
    ///   first (never sung at all leads it), and the chance halves every so many
    ///   places down that ranking, so a batch is mostly made of the exercises
    ///   the singer has been neglecting.
    /// * **How far its difficulty sits from the singer's level.** A bell curve
    ///   `SkillLevel.spread` wide centred on the level itself, so most of a
    ///   batch lands within that much of it and an exercise further out — either
    ///   way — is that much rarer. One nobody has rated yet is neither favoured
    ///   nor ruled out.
    ///
    /// The draw is random but not restless: it is seeded from the very things it
    /// ranks on, so the batch only changes when a run, an edit to the whitelist
    /// or a change of level actually gives it something new to say. Two calls in
    /// the same frame can't disagree about what was suggested, and neither can
    /// two launches.
    ///
    /// `hardness` is how hard each exercise is, keyed by the id it is stored
    /// under, and `skill` the singer's own level, both on the 0-100 scale
    /// `SkillLevel` describes — see SkillLevelStore, which is where the Home tab
    /// gets them.
    func recommendedExercises(minutes: Int, skill: Double, hardness: [UUID: Double]) -> [Exercise] {
        let target = Double(minutes) * 60
        guard target > 0 else { return [] }
        let ranked = exercises.enumerated()
            .filter { recommendationWhitelist.contains($0.element.id) }
            .sorted { lhs, rhs in
                let left = lastPlayed[lhs.element.id] ?? .distantPast
                let right = lastPlayed[rhs.element.id] ?? .distantPast
                // Never-played exercises all tie at .distantPast; library order
                // keeps their ranking stable from one launch to the next.
                if left == right { return lhs.offset < rhs.offset }
                return left < right
            }
            .map(\.element)
        guard !ranked.isEmpty else { return [] }

        var weights = ranked.enumerated().map { rank, exercise in
            // Floored rather than left to reach zero: an exercise at the far end
            // of both rankings is meant to be rare, not impossible, and the batch
            // has to reach the time it was asked for even if every remaining
            // chance has faded to nothing.
            max(Self.recencyWeight(rank: rank, of: ranked.count)
                * Self.difficultyWeight(hardness: hardness[exercise.id], skill: skill),
                1e-9)
        }
        var generator = SeededGenerator(seed: recommendationSeed(ranked, minutes: minutes, skill: skill))
        var batch: [Exercise] = []
        var length = 0.0
        // Drawn until the batch is at least as long as the singer asked for,
        // which means the exercise that takes it over the line is kept: a
        // suggestion that came out short would be one they'd have to make up
        // themselves. Only running out of whitelisted exercises stops it early.
        while length < target, batch.count < ranked.count {
            let total = weights.reduce(0, +)
            var draw = Double.random(in: 0..<total, using: &generator)
            // The last one catches a draw that the rounding of the running
            // subtraction leaves standing at the end.
            var chosen = weights.count - 1
            for (index, weight) in weights.enumerated() {
                draw -= weight
                if draw < 0 {
                    chosen = index
                    break
                }
            }
            batch.append(ranked[chosen])
            length += runDuration(of: ranked[chosen])
            weights[chosen] = 0     // drawn: out of the running for the rest
        }
        return ramped(batch, skill: skill, hardness: hardness)
    }

    /// How long a run of `exercise` takes, in seconds — what a batch is measured
    /// in. Its pattern is read here rather than passed in because the draw above
    /// only needs the exercises it actually picks measured, not the whole
    /// whitelist.
    func runDuration(of exercise: Exercise) -> Double {
        exercise.runDuration(pattern: notes(for: exercise.id))
    }

    /// A batch in the order the category shows it: easiest first, hardest last.
    /// An unrated exercise takes the singer's own level, which puts it in the
    /// middle of the ramp rather than at one end of it by accident.
    private func ramped(_ batch: [Exercise], skill: Double,
                        hardness: [UUID: Double]) -> [Exercise] {
        batch.enumerated()
            .sorted { lhs, rhs in
                let left = hardness[lhs.element.id] ?? skill
                let right = hardness[rhs.element.id] ?? skill
                if left == right { return lhs.offset < rhs.offset }
                return left < right
            }
            .map(\.element)
    }

    /// What an exercise's place in the played-longest-ago ranking is worth: 1
    /// for the one at the top of it, halving every quarter of the way down.
    /// Counted in places rather than in days so it behaves the same for a singer
    /// who practises daily and one who practises twice a year — and so the most
    /// neglected exercise is always the likeliest, whether it was last sung last
    /// week or never.
    private static func recencyWeight(rank: Int, of poolSize: Int) -> Double {
        pow(0.5, Double(rank) / max(2, Double(poolSize) / 4))
    }

    /// The bell curve over difficulty: 1 for an exercise pitched exactly at the
    /// singer's level, and falling away either side of it — to about 0.6 a whole
    /// `SkillLevel.spread` out, 0.14 at twice that, and next to nothing at three
    /// times, which is why a batch is mostly made of the first of those.
    private static func difficultyWeight(hardness: Double?, skill: Double) -> Double {
        // Nobody has finished it, so there is no difficulty to place it by. It
        // takes what an exercise one spread off the singer's level is worth,
        // which neither pushes it forward nor quietly drops it.
        guard let hardness else { return exp(-0.5) }
        let distance = (hardness - skill) / SkillLevel.spread
        return exp(-distance * distance / 2)
    }

    /// A seed for the draw that changes when — and only when — something the
    /// draw depends on does: which exercises are in the running, when each was
    /// last sung, how long a batch is wanted, and what level the singer is at.
    /// Mixed by hand rather than through `Hasher`, whose seed is fresh every
    /// launch: the same batch has to come back after a relaunch, not only after
    /// a redraw.
    private func recommendationSeed(_ ranked: [Exercise], minutes: Int, skill: Double) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            hash = (hash ^ value) &* 0x100_0000_01b3
        }
        for exercise in ranked {
            withUnsafeBytes(of: exercise.id.uuid) { bytes in
                for byte in bytes { mix(UInt64(byte)) }
            }
            let played = (lastPlayed[exercise.id] ?? .distantPast).timeIntervalSince1970
            mix(UInt64(bitPattern: Int64(played)))
        }
        mix(UInt64(bitPattern: Int64(minutes)))
        mix(UInt64(bitPattern: Int64((skill * 10).rounded())))
        return hash
    }

    // MARK: - Routines

    private func loadRoutines() {
        guard let data = UserDefaults.standard.data(forKey: routinesKey),
              let saved = try? JSONDecoder().decode([Routine].self, from: data)
        else { return }
        routines = saved
    }

    private func saveRoutines() {
        guard let data = try? JSONEncoder().encode(routines) else { return }
        UserDefaults.standard.set(data, forKey: routinesKey)
    }

    /// Create an empty routine. Names are free-form (duplicates allowed); only an
    /// empty name is refused.
    @discardableResult
    func addRoutine(named name: String) -> Routine? {
        guard !name.isEmpty else { return nil }
        let routine = Routine(name: name)
        routines.append(routine)
        saveRoutines()
        return routine
    }

    /// Delete a routine. Its exercises are untouched — they only stop being
    /// grouped by it.
    func deleteRoutine(_ id: UUID) {
        routines.removeAll { $0.id == id }
        saveRoutines()
    }

    /// Rename a routine. Refused only when the new name is empty after trimming.
    func renameRoutine(_ id: UUID, to newName: String) {
        guard !newName.isEmpty,
              let idx = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[idx].name = newName
        saveRoutines()
    }

    /// Set a routine's description — the text its intro screen shows. Any text
    /// is allowed, empty included.
    func setRoutineDetails(_ id: UUID, to newDetails: String) {
        guard let idx = routines.firstIndex(where: { $0.id == id }),
              routines[idx].details != newDetails else { return }
        routines[idx].details = newDetails
        saveRoutines()
    }

    /// Reorder the exercises within a routine (drives the edit-routine screen).
    func moveRoutineExercises(_ id: UUID, from source: IndexSet, to destination: Int) {
        guard let idx = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[idx].exerciseIDs.move(fromOffsets: source, toOffset: destination)
        saveRoutines()
    }

    /// Move a dragged routine so it sits just before the routine `targetID` (or
    /// at the end of the list when `targetID` is nil) — what the Home tab's
    /// drag & drop reports, alongside the edit screen's index-based `move`.
    func moveRoutine(_ id: UUID, before targetID: UUID?) {
        guard id != targetID,
              let from = routines.firstIndex(where: { $0.id == id }) else { return }
        let moved = routines.remove(at: from)
        if let targetID, let to = routines.firstIndex(where: { $0.id == targetID }) {
            routines.insert(moved, at: to)
        } else {
            routines.append(moved)
        }
        saveRoutines()
    }

    /// Add the exercise to the routine's end, or remove it if already present.
    /// Backs the picker's tap-to-select rows, which is why membership toggles.
    func toggleExercise(_ exerciseID: UUID, in routineID: UUID) {
        guard let idx = routines.firstIndex(where: { $0.id == routineID }) else { return }
        if let existing = routines[idx].exerciseIDs.firstIndex(of: exerciseID) {
            routines[idx].exerciseIDs.remove(at: existing)
        } else {
            routines[idx].exerciseIDs.append(exerciseID)
        }
        saveRoutines()
    }

    func removeExercise(_ exerciseID: UUID, fromRoutine routineID: UUID) {
        guard let idx = routines.firstIndex(where: { $0.id == routineID }) else { return }
        routines[idx].exerciseIDs.removeAll { $0 == exerciseID }
        saveRoutines()
    }

    /// Adds routines restored from the server that this device doesn't have,
    /// keeping their stored order. Routines already here are left as they are:
    /// a restore that failed on an earlier launch is retried on the next one,
    /// and anything the user built in between should survive it.
    func mergeRoutines(_ restored: [Routine]) {
        let known = Set(routines.map(\.id))
        let missing = restored.filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return }
        routines.append(contentsOf: missing)
        saveRoutines()
    }

    // MARK: - Favourites

    private func loadFavourites() {
        guard let data = UserDefaults.standard.data(forKey: favouritesKey),
              let saved = try? JSONDecoder().decode([UUID].self, from: data)
        else { return }
        favourites = saved
    }

    private func saveFavourites() {
        guard let data = try? JSONEncoder().encode(favourites) else { return }
        UserDefaults.standard.set(data, forKey: favouritesKey)
    }

    /// Reorder the favourites (drives the edit-favourites screen).
    func moveFavourites(from source: IndexSet, to destination: Int) {
        favourites.move(fromOffsets: source, toOffset: destination)
        saveFavourites()
    }

    /// Move a dragged favourite so it sits just before the exercise `targetID`
    /// (or at the end of the list when `targetID` is nil) — the Home tab's
    /// drag & drop, the same way `moveRoutine(_:before:)` works.
    func moveFavourite(_ id: UUID, before targetID: UUID?) {
        guard id != targetID, let from = favourites.firstIndex(of: id) else { return }
        favourites.remove(at: from)
        if let targetID, let to = favourites.firstIndex(of: targetID) {
            favourites.insert(id, at: to)
        } else {
            favourites.append(id)
        }
        saveFavourites()
    }

    /// Add the exercise to the favourites' end, or remove it if already present.
    /// Backs the picker's tap-to-select rows, which is why membership toggles.
    func toggleFavourite(_ exerciseID: UUID) {
        if let existing = favourites.firstIndex(of: exerciseID) {
            favourites.remove(at: existing)
        } else {
            favourites.append(exerciseID)
        }
        saveFavourites()
    }

    func removeFavourite(_ exerciseID: UUID) {
        favourites.removeAll { $0 == exerciseID }
        saveFavourites()
    }

    /// Appends favourites restored from the server that aren't already in the
    /// list, in their stored order — same merge rules as `mergeRoutines`.
    func mergeFavourites(_ restored: [UUID]) {
        let missing = restored.filter { !favourites.contains($0) }
        guard !missing.isEmpty else { return }
        favourites.append(contentsOf: missing)
        saveFavourites()
    }

    // MARK: - Recommendation whitelist

    /// Whether "Automatically whitelisted exercises" covers the group this
    /// exercise came from — what it is whitelisted by unless the user has said
    /// otherwise for this exercise in particular.
    private func isAutomaticallyWhitelisted(_ exercise: Exercise) -> Bool {
        autoWhitelistOrigins.contains(ExerciseOrigin.of(exercise, isBundled: isBundled(exercise.id)))
    }

    /// Work the whitelist out again: the setting's word on each exercise's group,
    /// with the user's own picks overriding it one exercise at a time. Called
    /// after anything either of those is drawn from changes — the library, the
    /// setting, the picks — since nothing else keeps the list current.
    private func refreshRecommendationWhitelist() {
        let updated = Set(exercises
            .filter { whitelistOverrides[$0.id] ?? isAutomaticallyWhitelisted($0) }
            .map(\.id))
        guard updated != recommendationWhitelist else { return }
        recommendationWhitelist = updated
    }

    private func loadWhitelistOverrides() {
        guard let data = UserDefaults.standard.data(forKey: whitelistOverridesKey),
              let saved = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return }
        whitelistOverrides = saved.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
    }

    private func saveWhitelistOverrides() {
        let encodable = whitelistOverrides.reduce(into: [String: Bool]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
        guard let data = try? JSONEncoder().encode(encodable) else { return }
        UserDefaults.standard.set(data, forKey: whitelistOverridesKey)
    }

    /// Change which groups of exercises are whitelisted automatically. The groups
    /// switched on take everything already in the library that belongs to them,
    /// not only what arrives afterwards, and the ones switched off give up theirs
    /// — in both cases leaving the exercises the user has decided on by hand
    /// exactly as they decided them.
    func setAutoWhitelistOrigins(_ origins: Set<ExerciseOrigin>) {
        guard origins != autoWhitelistOrigins else { return }
        autoWhitelistOrigins = origins
        RecommendedExercises.storedAutoWhitelist = origins
        refreshRecommendationWhitelist()
    }

    /// A two-way switch for one group's row in the setting's menu.
    func autoWhitelistBinding(_ origin: ExerciseOrigin) -> Binding<Bool> {
        Binding(
            get: { self.autoWhitelistOrigins.contains(origin) },
            set: { isOn in
                var origins = self.autoWhitelistOrigins
                if isOn { origins.insert(origin) } else { origins.remove(origin) }
                self.setAutoWhitelistOrigins(origins)
            }
        )
    }

    /// Put the whitelist back to how it starts out: every group whitelisted
    /// automatically, and no exercise picked out by hand. Used by
    /// Settings ▸ Reset ▸ Settings ▸ Exercises.
    func resetRecommendationWhitelist() {
        UserDefaults.standard.removeObject(forKey: RecommendedExercises.autoWhitelistKey)
        autoWhitelistOrigins = RecommendedExercises.storedAutoWhitelist
        whitelistOverrides = [:]
        saveWhitelistOverrides()
        refreshRecommendationWhitelist()
    }

    /// Puts back a whitelist restored from the server. Unlike the Home tab's
    /// routines and favourites this is a setting rather than a list the user adds
    /// to, so the restored one simply wins: every exercise it disagrees with the
    /// automatic groups about becomes a pick of the user's own, which is exactly
    /// what made the whitelist look like that on the device it came from.
    ///
    /// The caller restores the automatic groups before this — they are what the
    /// disagreements are measured against. (A pick that happens to agree with them
    /// isn't one of those, so it doesn't survive the trip; the whitelist does.)
    func restoreRecommendationWhitelist(_ restored: Set<UUID>) {
        var overrides: [UUID: Bool] = [:]
        for exercise in exercises {
            let whitelisted = restored.contains(exercise.id)
            if whitelisted != isAutomaticallyWhitelisted(exercise) {
                overrides[exercise.id] = whitelisted
            }
        }
        guard overrides != whitelistOverrides else { return }
        whitelistOverrides = overrides
        saveWhitelistOverrides()
        refreshRecommendationWhitelist()
    }

    /// Add the exercise to the recommendation pool, or remove it if already in it.
    /// Backs the picker's tap-to-select rows, which is why membership toggles.
    ///
    /// A tap that disagrees with the automatic groups is remembered as the user's
    /// own pick, and outlasts those groups being switched off and on. One that
    /// agrees hands the exercise back to them: it is no longer an exception, so
    /// it follows its group again from here on.
    func toggleWhitelisted(_ exerciseID: UUID) {
        guard let exercise = exercises.first(where: { $0.id == exerciseID }) else { return }
        let whitelisted = !recommendationWhitelist.contains(exerciseID)
        if whitelisted == isAutomaticallyWhitelisted(exercise) {
            whitelistOverrides.removeValue(forKey: exerciseID)
        } else {
            whitelistOverrides[exerciseID] = whitelisted
        }
        saveWhitelistOverrides()
        refreshRecommendationWhitelist()
    }

    // MARK: - Exercise mutation

    @discardableResult
    func add(name: String) -> Exercise {
        var exercise = Exercise(name: name)
        exercise.category = Self.noCategoryName
        exercises.append(exercise)
        save()
        return exercise
    }

    /// Copy a community exercise into the user's own library: a fresh id so the
    /// copy is independent of the original, private visibility, no uploader name,
    /// and the "No Category" group. The original uploader is remembered in
    /// `downloadedFrom`, which is what marks the copy as a community exercise for
    /// the Exercises tab's filter. The MIDI pattern and text labels are copied
    /// too. Takes the exercise by value because community exercises fetched from
    /// the server aren't in `exercises` (their patterns are still readable by id
    /// — CommunitySync caches them under the standard keys).
    @discardableResult
    func downloadCopy(of source: Exercise) -> Exercise {
        var copy = source
        copy.id = UUID()
        copy.visibility = .private
        copy.downloadedFrom = source.uploaderName
        copy.uploaderName = ""
        copy.category = Self.noCategoryName
        exercises.append(copy)
        setNotes(notes(for: source.id), for: copy.id)
        setTexts(texts(for: source.id), for: copy.id)
        save()
        return copy
    }

    /// Delete a just-created exercise the user backed out of without touching:
    /// every setting (name, description, …) still matches the snapshot taken at
    /// creation and no MIDI notes or text labels were added.
    func discardIfUntouched(_ created: Exercise) {
        guard let current = exercises.first(where: { $0.id == created.id }),
              current == created,
              notes(for: created.id).isEmpty,
              texts(for: created.id).isEmpty
        else { return }
        delete(id: created.id)
    }

    func delete(id: UUID) {
        exercises.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: Self.midiKey(id))
        UserDefaults.standard.removeObject(forKey: Self.midiTextKey(id))
        ScoreHistory.delete(for: id)
        if recentlyPlayed.contains(id) {
            recentlyPlayed.removeAll { $0 == id }
            saveRecentlyPlayed()
        }
        if lastPlayed.removeValue(forKey: id) != nil {
            saveLastPlayed()
        }
        if routines.contains(where: { $0.exerciseIDs.contains(id) }) {
            for i in routines.indices {
                routines[i].exerciseIDs.removeAll { $0 == id }
            }
            saveRoutines()
        }
        if favourites.contains(id) {
            favourites.removeAll { $0 == id }
            saveFavourites()
        }
        if whitelistOverrides.removeValue(forKey: id) != nil {
            saveWhitelistOverrides()
        }
        // Refreshes the whitelist, which the deleted exercise drops out of.
        save()
    }

    /// A safe two-way binding to a single exercise: edits write back (and persist)
    /// by id, so it never crashes if the exercise is deleted while a view holds it.
    func binding(for id: UUID) -> Binding<Exercise> {
        Binding(
            get: { self.exercises.first(where: { $0.id == id }) ?? Exercise(name: "") },
            set: { newValue in
                guard let idx = self.exercises.firstIndex(where: { $0.id == id }) else { return }
                self.exercises[idx] = newValue
                self.save()
            }
        )
    }

    // MARK: - Reset

    /// The exercises the user made themselves: neither shipped with the app nor
    /// copied in from the Community tab.
    var ownExerciseIDs: [UUID] {
        exercises.filter { !isBundled($0.id) && $0.downloadedFrom == nil }.map(\.id)
    }

    /// The exercises copied into the library from the Community tab.
    var downloadedExerciseIDs: [UUID] {
        exercises.filter { !isBundled($0.id) && $0.downloadedFrom != nil }.map(\.id)
    }

    /// Delete every exercise the user made themselves, each with its pattern,
    /// scores and place in the user's lists. Bundled and downloaded ones stay.
    func deleteOwnExercises() {
        for id in ownExerciseIDs { delete(id: id) }
    }

    /// Delete every exercise downloaded from the Community tab, under the same
    /// rules as `deleteOwnExercises`.
    func deleteDownloadedExercises() {
        for id in downloadedExerciseIDs { delete(id: id) }
    }

    /// A bundled exercise exactly as it ships, or nil for an id that isn't one.
    static func bundledOriginal(_ id: UUID) -> Exercise? {
        bundledBundle?.exercises.first { $0.id == id }
    }

    /// Whether the user has changed a bundled exercise from how it ships — edited
    /// its settings, notes or text labels, or deleted it outright.
    func isBundledChanged(_ id: UUID) -> Bool {
        guard let original = Self.bundledOriginal(id) else { return false }
        // A deleted bundled exercise counts as changed: reverting brings it back.
        guard let current = exercises.first(where: { $0.id == id }) else { return true }
        return current != original
            || notes(for: id) != Self.bundledNotes(id)
            || texts(for: id) != Self.bundledTexts(id)
    }

    /// The bundled exercises the user has changed, in the order they ship. Ids
    /// rather than exercises, since a deleted one is no longer in the library.
    var changedBundledIDs: [UUID] {
        (Self.bundledBundle?.exercises.map(\.id) ?? []).filter(isBundledChanged)
    }

    /// Put a bundled exercise back to how it ships — its settings, MIDI pattern and
    /// text labels — restoring it if the user deleted it. Where it sits in the
    /// user's own lists (favourites, routines, the recommendation whitelist) is
    /// left alone; those are reset from their own screens.
    func revertBundled(_ id: UUID) {
        guard let original = Self.bundledOriginal(id) else { return }
        if let idx = exercises.firstIndex(where: { $0.id == id }) {
            exercises[idx] = original
        } else {
            exercises.append(original)
        }
        setNotes(Self.bundledNotes(id), for: id)
        setTexts(Self.bundledTexts(id), for: id)
        // The group it belongs to may have been renamed or deleted since.
        addCategory(original.category)
        save()
    }

    /// Put every bundled exercise back to how it ships.
    func revertAllBundled() {
        for id in Self.bundledBundle?.exercises.map(\.id) ?? [] {
            revertBundled(id)
        }
    }

    private static func bundledNotes(_ id: UUID) -> [MIDINote] {
        bundledBundle?.midi[id.uuidString] ?? []
    }

    private static func bundledTexts(_ id: UUID) -> [MIDIText] {
        bundledBundle?.texts?[id.uuidString] ?? []
    }

    /// Empty the Home tab's "Favourites" list. The exercises themselves stay.
    func clearFavourites() {
        guard !favourites.isEmpty else { return }
        favourites = []
        saveFavourites()
    }

    /// Delete every routine. Their exercises stay in the library.
    func clearRoutines() {
        guard !routines.isEmpty else { return }
        routines = []
        saveRoutines()
    }

    /// Forget what was played when: both the Home tab's "Recent" list and the
    /// timestamps "Recommended" orders by.
    func clearPlayHistory() {
        recentlyPlayed = []
        saveRecentlyPlayed()
        lastPlayed = [:]
        saveLastPlayed()
    }

    // MARK: - MIDI pattern access

    static func midiKey(_ id: UUID) -> String { "midi_\(id.uuidString)" }
    static func midiTextKey(_ id: UUID) -> String { "miditext_\(id.uuidString)" }

    func notes(for id: UUID) -> [MIDINote] {
        guard let data = UserDefaults.standard.data(forKey: Self.midiKey(id)),
              let saved = try? JSONDecoder().decode([MIDINote].self, from: data)
        else { return [] }
        return saved
    }

    private func setNotes(_ notes: [MIDINote], for id: UUID) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: Self.midiKey(id))
    }

    func texts(for id: UUID) -> [MIDIText] {
        guard let data = UserDefaults.standard.data(forKey: Self.midiTextKey(id)),
              let saved = try? JSONDecoder().decode([MIDIText].self, from: data)
        else { return [] }
        return saved
    }

    private func setTexts(_ texts: [MIDIText], for id: UUID) {
        guard let data = try? JSONEncoder().encode(texts) else { return }
        UserDefaults.standard.set(data, forKey: Self.midiTextKey(id))
    }

    // MARK: - Export / Import

    /// Snapshots every exercise (with all its settings) and its MIDI pattern.
    /// Exercises are listed in the order they appear in the list: grouped by
    /// category (in the user's category order), with uncategorized ones last.
    ///
    /// `ids` narrows the snapshot to those exercises — what the export screen
    /// ticked. nil takes the whole library.
    func exportBundle(ids: Set<UUID>? = nil) -> ExerciseBundle {
        var ordered: [Exercise] = []
        for category in categories {
            ordered.append(contentsOf: exercises.filter { $0.category == category })
        }
        ordered.append(contentsOf: exercises.filter { !categories.contains($0.category) })
        if let ids { ordered = ordered.filter { ids.contains($0.id) } }
        var midi: [String: [MIDINote]] = [:]
        var texts: [String: [MIDIText]] = [:]
        for exercise in ordered {
            midi[exercise.id.uuidString] = notes(for: exercise.id)
            let t = self.texts(for: exercise.id)
            if !t.isEmpty { texts[exercise.id.uuidString] = t }
        }
        return ExerciseBundle(exercises: ordered, categories: exportedCategories(of: ordered),
                              midi: midi, texts: texts.isEmpty ? nil : texts)
    }

    /// The category list a bundle of `exported` exercises carries: those the
    /// export has an exercise in, plus every empty one — an empty category has no
    /// exercise that could have been unticked, so leaving it out would mean a
    /// full export no longer restores the library's grouping as it stands.
    private func exportedCategories(of exported: [Exercise]) -> [String] {
        let exportedIDs = Set(exported.map(\.id))
        return categories.filter { category in
            let inCategory = exercises.filter { $0.category == category }
            return inCategory.isEmpty || inCategory.contains { exportedIDs.contains($0.id) }
        }
    }

    /// `exportBundle(ids:)` encoded as a standalone JSON file.
    func exportData(ids: Set<UUID>? = nil) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try? encoder.encode(exportBundle(ids: ids))
    }

    /// Merges the exercises in `bundle` into the library (by id: existing ones are
    /// replaced, new ones appended), restoring their MIDI patterns too.
    func importBundle(_ bundle: ExerciseBundle) {
        for var exercise in bundle.exercises {
            // Bundles written before the "No Category" group existed use "".
            if exercise.category.isEmpty { exercise.category = Self.noCategoryName }
            // Imported exercises take the order they have in the bundle: any
            // existing copy is dropped and re-appended, so importing a full
            // export reproduces its list order exactly.
            exercises.removeAll { $0.id == exercise.id }
            exercises.append(exercise)
            if let notes = bundle.midi[exercise.id.uuidString] {
                setNotes(notes, for: exercise.id)
            }
            if let texts = bundle.texts?[exercise.id.uuidString] {
                setTexts(texts, for: exercise.id)
            }
        }
        // Register imported categories in the order the bundle lists them (older
        // bundles carry no category list, so fall back to the order categories
        // first appear on the exercises), keeping the exported grouping order.
        for category in bundle.categories ?? bundle.exercises.map(\.category) {
            addCategory(category)
        }
        save()
        enforceBundledPrivacy()
    }
}

/// Settings for the Home tab's "Recommended" category — and, since the daily
/// practice time below is what both of them are measured in, for its calendar
/// too. Edited under Settings ▸ Exercises.
enum RecommendedExercises {
    /// How long a day the singer means to practise for, in minutes. It is what
    /// the "Recommended" category fills — it suggests exercises until they add
    /// up to at least this long — and what a day of the Home tab's practice
    /// calendar is measured against, a square reaching the accent colour and a
    /// tick once the day has this much on it.
    ///
    /// Stored under a key of its own rather than the `recommendedExercisesAmount`
    /// this replaced, which counted exercises: five exercises must not come back
    /// as five minutes on an install that had set it.
    static let minutesKey = "recommendedPracticeMinutes"
    /// The daily practice time when the user hasn't chosen — a warm-up's worth,
    /// which on the exercises the app ships with is around ten of them.
    static let defaultMinutes = 10
    static let minutesRange = 5...120
    /// What one press of the Settings stepper — or of the tutorial's ± buttons,
    /// which don't repeat while held — moves it by. The setting is a round
    /// intention rather than a measurement, so it moves in round steps.
    static let minutesStep = 5

    /// The stored practice time, for the places that read it outside a view.
    static var minutes: Int {
        let stored = UserDefaults.standard.object(forKey: minutesKey) as? Int
        return stored ?? defaultMinutes
    }

    /// The practice time written out — "10 min", "1 hr 30 min". The style is
    /// handed the locale by hand: that is the app's chosen language, which is
    /// not necessarily the device's.
    static func formatted(minutes: Int, locale: Locale) -> String {
        Duration.seconds(minutes * 60).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes],
                                      width: .abbreviated).locale(locale))
    }

    /// Whether the category lists those exercises or shows a single card that
    /// opens all of them as one queue. The card is what it shows by default;
    /// the list is the older shape, kept for anyone who prefers it.
    static let asListKey = "recommendationsAsList"
    static let defaultAsList = false

    /// The groups of exercises whitelisted for recommendations automatically,
    /// stored newline-joined like the Home tab's category order. Absent — nothing
    /// stored at all — is every group, which is how the setting starts out; an
    /// empty string is the user having switched all three off, and the two have to
    /// read differently.
    static let autoWhitelistKey = "recommendationAutoWhitelist"

    static var storedAutoWhitelist: Set<ExerciseOrigin> {
        get {
            guard let raw = UserDefaults.standard.string(forKey: autoWhitelistKey) else {
                return Set(ExerciseOrigin.allCases)
            }
            return Set(raw.split(separator: "\n").compactMap { ExerciseOrigin(rawValue: String($0)) })
        }
        set {
            // Sorted so the same set of groups always stores the same string.
            let raw = newValue.map(\.rawValue).sorted().joined(separator: "\n")
            UserDefaults.standard.set(raw, forKey: autoWhitelistKey)
        }
    }
}

/// A random number generator that starts from a seed it is handed, so the same
/// seed replays the same draw — which is what keeps a recommendation batch put
/// between redraws and across launches (see `recommendedExercises`).
///
/// SplitMix64, constants and all. Nothing drawn from it is a secret, so there is
/// no reason to want it unpredictable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The on-disk format for export/import: the exercise list plus each one's MIDI
/// pattern keyed by exercise UUID string.
struct ExerciseBundle: Codable {
    var exercises: [Exercise]
    /// The category display order at export time. Optional so bundles written
    /// before categories were exported still decode.
    var categories: [String]? = nil
    var midi: [String: [MIDINote]]
    /// Text labels per exercise UUID string. Optional so bundles written before the
    /// text tool existed still decode.
    var texts: [String: [MIDIText]]? = nil
}

extension ExerciseBundle {
    /// This bundle with any repeated exercise id dropped, keeping the first of
    /// each. An export of ours can't repeat one, but a hand-edited file can, and
    /// the import screen would then list the same exercise twice — which the
    /// list's diffable data source treats as a programming error and traps on.
    var deduplicated: ExerciseBundle {
        var seen: Set<UUID> = []
        var copy = self
        copy.exercises = exercises.filter { seen.insert($0.id).inserted }
        return copy
    }

    /// This bundle narrowed to the exercises `ids` names — what the import screen
    /// ticked — carrying their patterns and texts and only the categories those
    /// exercises belong to, so a category nothing was taken from isn't created on
    /// the way in.
    func filtered(to ids: Set<UUID>) -> ExerciseBundle {
        let kept = exercises.filter { ids.contains($0.id) }
        // Patterns and texts are keyed by UUID string, exactly as
        // `ExerciseStore.importBundle` looks them up.
        let keys = Set(kept.map { $0.id.uuidString })
        return ExerciseBundle(
            exercises: kept,
            // Left nil for a bundle that never listed its categories: import
            // then reads them off the exercises, which are filtered already.
            categories: categories.map { list in
                list.filter { category in kept.contains { $0.category == category } }
            },
            midi: midi.filter { keys.contains($0.key) },
            texts: texts.map { $0.filter { keys.contains($0.key) } }
        )
    }
}
