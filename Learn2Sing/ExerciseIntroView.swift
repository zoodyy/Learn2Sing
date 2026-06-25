import SwiftUI

/// Shown right after an exercise is tapped, before playback begins. Presents the
/// exercise's description so the singer knows what to do, with a button to start.
struct ExerciseIntroView: View {
    let exercise: Exercise
    let onStart: () -> Void

    private var trimmedDetails: String {
        exercise.details.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(exercise.name)
                        .font(.largeTitle.weight(.bold))

                    if trimmedDetails.isEmpty {
                        Text("No description.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(trimmedDetails)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            Button(action: onStart) {
                Text("Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
