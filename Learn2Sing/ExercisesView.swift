import SwiftUI

struct Exercise: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var pitchShift: Int = 0     // transpose all notes by this many semitones
    var speed: Double = 100     // playback speed as a percentage of normal
}

enum ExerciseRoute: Hashable {
    case play(UUID)
    case settings(UUID)
    case edit(UUID)
}

struct ExercisesView: View {
    @State private var exercises: [Exercise] = []
    @State private var showingNameAlert = false
    @State private var newExerciseName = ""
    @State private var navigationPath = NavigationPath()

    private let storeKey = "exercises"

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(exercises) { exercise in
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
                    let exercise = Exercise(name: name)
                    exercises.append(exercise)
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
                    if let ex = exercises.first(where: { $0.id == id }) {
                        PlaybackView(exercise: ex)
                    }
                case .settings(let id):
                    if let idx = exercises.firstIndex(where: { $0.id == id }) {
                        ExerciseSettingsView(exercise: $exercises[idx])
                    }
                case .edit(let id):
                    if let ex = exercises.first(where: { $0.id == id }) {
                        EditingView(exercise: ex)
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onChange(of: exercises) { _, _ in save() }
    }

    // MARK: - Persistence

    private func load() {
        guard exercises.isEmpty,
              let data = UserDefaults.standard.data(forKey: storeKey),
              let saved = try? JSONDecoder().decode([Exercise].self, from: data)
        else { return }
        exercises = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(exercises) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }
}
