import SwiftUI
import Combine

/// Single source of truth for the user's exercises and their MIDI patterns.
/// Backed by UserDefaults (exercise list under `exercises`, each pattern under
/// `midi_<uuid>`) so it stays compatible with the existing EditingView/PlaybackView.
final class ExerciseStore: ObservableObject {
    @Published var exercises: [Exercise] = []

    private let storeKey = "exercises"
    private let bundledImportedKey = "didImportBundledExercises"

    init() {
        load()
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

    // MARK: - Export / Import

    /// Encodes every exercise (with all its settings) and its MIDI pattern into one file.
    func exportData() -> Data? {
        var midi: [String: [MIDINote]] = [:]
        for exercise in exercises {
            midi[exercise.id.uuidString] = notes(for: exercise.id)
        }
        let bundle = ExerciseBundle(exercises: exercises, midi: midi)
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
}
