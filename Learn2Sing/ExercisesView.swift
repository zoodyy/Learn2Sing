import SwiftUI

struct Exercise: Identifiable, Hashable {
    let id = UUID()
    var name: String
}

struct ExercisesView: View {
    @State private var exercises: [Exercise] = []
    @State private var showingNameAlert = false
    @State private var newExerciseName = ""
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List(exercises) { exercise in
                NavigationLink(exercise.name, value: exercise)
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
                    navigationPath.append(exercise)
                }
                Button("Cancel", role: .cancel) {
                    newExerciseName = ""
                }
            } message: {
                Text("Enter a name for the new exercise")
            }
            .navigationDestination(for: Exercise.self) { exercise in
                EditingView(exercise: exercise)
            }
        }
    }
}
