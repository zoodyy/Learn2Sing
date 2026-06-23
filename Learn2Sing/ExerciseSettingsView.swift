import SwiftUI

struct ExerciseSettingsView: View {
    @Binding var exercise: Exercise

    private var pitchLabel: String {
        let s = exercise.pitchShift
        let sign = s > 0 ? "+" : ""
        let unit = abs(s) == 1 ? "semitone" : "semitones"
        return "\(sign)\(s) \(unit)"
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $exercise.name)
            }

            Section("Pitch") {
                Stepper(value: $exercise.pitchShift, in: -24...24) {
                    HStack {
                        Text("Transpose")
                        Spacer()
                        Text(pitchLabel).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Speed") {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(Int(exercise.speed))%").foregroundStyle(.secondary)
                }
                Slider(value: $exercise.speed, in: 25...200, step: 5)
            }

            Section {
                NavigationLink(value: ExerciseRoute.edit(exercise.id)) {
                    Label("Edit MIDI", systemImage: "pianokeys")
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
