import SwiftUI
import Combine

/// An ordered list of exercises the user assembles on the Home tab. Unlike
/// categories, routines are keyed by id — names are free-form and don't have
/// to be unique — and an exercise can appear in any number of routines.
struct Routine: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    /// The routine's exercises in the user's order. Never contains duplicates.
    var exerciseIDs: [UUID] = []
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
    /// The user's routines in display order. Shown in the Home tab's "Routines"
    /// category.
    @Published var routines: [Routine] = []

    /// The always-present home for exercises not assigned to any other category:
    /// new exercises start here, deleting a category moves its exercises here, and
    /// it can never itself be deleted.
    static let noCategoryName = "No Category"

    private let storeKey = "exercises"
    private let categoriesKey = "categories"
    private let recentlyPlayedKey = "recentlyPlayed"
    private let routinesKey = "routines"
    private let bundledImportedKey = "didImportBundledExercises"

    init() {
        load()
        loadCategories()
        loadRecentlyPlayed()
        loadRoutines()
        importBundledIfNeeded()
        adoptNoCategory()
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
        guard let url = Bundle.main.url(forResource: "BundledExercises", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              importData(data)
        else { return }
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
        guard let data = try? JSONEncoder().encode(exercises) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
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

    /// Reorder the exercises within a routine (drives the edit-routine screen).
    func moveRoutineExercises(_ id: UUID, from source: IndexSet, to destination: Int) {
        guard let idx = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[idx].exerciseIDs.move(fromOffsets: source, toOffset: destination)
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

    // MARK: - Exercise mutation

    @discardableResult
    func add(name: String) -> Exercise {
        var exercise = Exercise(name: name)
        exercise.category = Self.noCategoryName
        exercises.append(exercise)
        save()
        return exercise
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
        if routines.contains(where: { $0.exerciseIDs.contains(id) }) {
            for i in routines.indices {
                routines[i].exerciseIDs.removeAll { $0 == id }
            }
            saveRoutines()
        }
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

    private func texts(for id: UUID) -> [MIDIText] {
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

    /// Encodes every exercise (with all its settings) and its MIDI pattern into one file.
    /// Exercises are written in the order they appear in the list: grouped by
    /// category (in the user's category order), with uncategorized ones last.
    func exportData() -> Data? {
        var ordered: [Exercise] = []
        for category in categories {
            ordered.append(contentsOf: exercises.filter { $0.category == category })
        }
        ordered.append(contentsOf: exercises.filter { !categories.contains($0.category) })
        var midi: [String: [MIDINote]] = [:]
        var texts: [String: [MIDIText]] = [:]
        for exercise in ordered {
            midi[exercise.id.uuidString] = notes(for: exercise.id)
            let t = self.texts(for: exercise.id)
            if !t.isEmpty { texts[exercise.id.uuidString] = t }
        }
        let bundle = ExerciseBundle(exercises: ordered, categories: categories, midi: midi,
                                    texts: texts.isEmpty ? nil : texts)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try? encoder.encode(bundle)
    }

    /// Merges the exercises in `data` into the library (by id: existing ones are
    /// replaced, new ones appended), restoring their MIDI patterns too.
    @discardableResult
    func importData(_ data: Data) -> Bool {
        guard let bundle = try? JSONDecoder().decode(ExerciseBundle.self, from: data) else {
            return false
        }
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
        return true
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
