import SwiftUI
import Combine

/// Single source of truth for the user's exercises and their MIDI patterns.
/// Backed by UserDefaults (exercise list under `exercises`, each pattern under
/// `midi_<uuid>`) so it stays compatible with the existing EditingView/PlaybackView.
final class ExerciseStore: ObservableObject {
    @Published var exercises: [Exercise] = []
    /// User-defined categories used to group exercises in the list, in display order.
    @Published var categories: [String] = []

    private let storeKey = "exercises"
    private let categoriesKey = "categories"
    private let bundledImportedKey = "didImportBundledExercises"

    init() {
        load()
        loadCategories()
        importBundledIfNeeded()
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

    /// Remove a category and clear it from any exercise that used it (those become
    /// uncategorized) so no exercise is left pointing at a category that's gone.
    func deleteCategory(_ name: String) {
        categories.removeAll { $0 == name }
        saveCategories()
        var changed = false
        for i in exercises.indices where exercises[i].category == name {
            exercises[i].category = ""
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Exercise mutation

    @discardableResult
    func add(name: String) -> Exercise {
        let exercise = Exercise(name: name)
        exercises.append(exercise)
        save()
        return exercise
    }

    func delete(id: UUID) {
        exercises.removeAll { $0.id == id }
        UserDefaults.standard.removeObject(forKey: Self.midiKey(id))
        UserDefaults.standard.removeObject(forKey: Self.midiTextKey(id))
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

    private func notes(for id: UUID) -> [MIDINote] {
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
    func exportData() -> Data? {
        var midi: [String: [MIDINote]] = [:]
        var texts: [String: [MIDIText]] = [:]
        for exercise in exercises {
            midi[exercise.id.uuidString] = notes(for: exercise.id)
            let t = self.texts(for: exercise.id)
            if !t.isEmpty { texts[exercise.id.uuidString] = t }
        }
        let bundle = ExerciseBundle(exercises: exercises, midi: midi,
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
        for exercise in bundle.exercises {
            if let idx = exercises.firstIndex(where: { $0.id == exercise.id }) {
                exercises[idx] = exercise
            } else {
                exercises.append(exercise)
            }
            if let notes = bundle.midi[exercise.id.uuidString] {
                setNotes(notes, for: exercise.id)
            }
            if let texts = bundle.texts?[exercise.id.uuidString] {
                setTexts(texts, for: exercise.id)
            }
        }
        // Register any categories the imported exercises reference so they stay
        // selectable and the list can group by them.
        for category in Set(bundle.exercises.map(\.category)) where !category.isEmpty {
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
    var midi: [String: [MIDINote]]
    /// Text labels per exercise UUID string. Optional so bundles written before the
    /// text tool existed still decode.
    var texts: [String: [MIDIText]]? = nil
}
