import SwiftUI

struct Exercise: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var pitchShift: Int = 0           // transpose all notes by this many semitones
    var bpm: Double = 120             // playback tempo in beats per minute
    var repeatCount: Int = 1          // how many times the pattern is played back
    var transposePerRepeat: Int = 0   // semitones to shift up each repetition (negative = down)
    var beatsBetweenReps: Double = 0  // silent beats inserted between repetitions

    init(name: String) { self.name = name }

    private enum CodingKeys: String, CodingKey {
        case id, name, pitchShift, bpm, speed, repeatCount, transposePerRepeat, beatsBetweenReps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        pitchShift = try c.decodeIfPresent(Int.self, forKey: .pitchShift) ?? 0
        if let bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) {
            self.bpm = bpm
        } else if let speed = try c.decodeIfPresent(Double.self, forKey: .speed) {
            // Legacy: `speed` was a percentage of a 120 BPM baseline.
            bpm = (120.0 * speed / 100.0).rounded()
        }
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        transposePerRepeat = try c.decodeIfPresent(Int.self, forKey: .transposePerRepeat) ?? 0
        beatsBetweenReps = try c.decodeIfPresent(Double.self, forKey: .beatsBetweenReps) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(pitchShift, forKey: .pitchShift)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(repeatCount, forKey: .repeatCount)
        try c.encode(transposePerRepeat, forKey: .transposePerRepeat)
        try c.encode(beatsBetweenReps, forKey: .beatsBetweenReps)
    }
}

enum ExerciseRoute: Hashable {
    case play(UUID)
    case settings(UUID)
    case edit(UUID)
}

struct ExercisesView: View {
    @EnvironmentObject private var store: ExerciseStore
    @State private var showingNameAlert = false
    @State private var newExerciseName = ""
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(store.exercises) { exercise in
                Button(exercise.name) {
                    navigationPath.append(ExerciseRoute.play(exercise.id))
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        navigationPath.append(ExerciseRoute.settings(exercise.id))
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .tint(.blue)
                }
            }
            .navigationTitle("Exercises")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNameAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("New Exercise", isPresented: $showingNameAlert) {
                TextField("Name", text: $newExerciseName)
                Button("Add") {
                    let name = newExerciseName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let exercise = store.add(name: name)
                    newExerciseName = ""
                    navigationPath.append(ExerciseRoute.edit(exercise.id))
                }
                Button("Cancel", role: .cancel) {
                    newExerciseName = ""
                }
            } message: {
                Text("Enter a name for the new exercise")
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .play(let id):
                    if let ex = store.exercises.first(where: { $0.id == id }) {
                        PlaybackView(exercise: ex)
                    }
                case .settings(let id):
                    if store.exercises.contains(where: { $0.id == id }) {
                        ExerciseSettingsView(exercise: store.binding(for: id))
                    }
                case .edit(let id):
                    if let ex = store.exercises.first(where: { $0.id == id }) {
                        EditingView(exercise: ex)
                    }
                }
            }
        }
    }
}
