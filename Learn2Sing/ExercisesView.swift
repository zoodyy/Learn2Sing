import SwiftUI

struct Exercise: Identifiable, Hashable {
    let id = UUID()
    var name: String
}

private enum ExerciseRoute: Hashable {
    case play(Exercise)
    case edit(Exercise)
}

struct ExercisesView: View {
    @State private var exercises: [Exercise] = []
    @State private var showingNameAlert = false
    @State private var newExerciseName = ""
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(exercises) { exercise in
                Button(exercise.name) {
                    navigationPath.append(ExerciseRoute.play(exercise))
                }
                .foregroundStyle(.primary)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        navigationPath.append(ExerciseRoute.edit(exercise))
                    } label: {
                        Label("Edit", systemImage: "pencil")
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
                    navigationPath.append(ExerciseRoute.edit(exercise))
                }
                Button("Cancel", role: .cancel) {
                    newExerciseName = ""
                }
            } message: {
                Text("Enter a name for the new exercise")
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .play(let ex): PlaybackView(exercise: ex)
                case .edit(let ex): EditingView(exercise: ex)
                }
            }
        }
    }
}
