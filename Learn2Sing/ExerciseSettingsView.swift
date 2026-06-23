import SwiftUI

struct ExerciseSettingsView: View {
    @Binding var exercise: Exercise
    @EnvironmentObject private var store: ExerciseStore
    @Environment(\.dismiss) private var dismiss

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

            Section("Tempo") {
                HStack {
                    Text("Tempo")
                    Spacer()
                    Text("\(Int(exercise.bpm)) BPM").foregroundStyle(.secondary)
                }
                Slider(value: $exercise.bpm, in: 40...240, step: 1)
            }

            Section("Repetition") {
                HStack {
                    Text("Repeat")
                    Spacer()
                    TextField("1", value: $exercise.repeatCount, format: .number)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(width: 60)
                        .onChange(of: exercise.repeatCount) { _, newValue in
                            if newValue < 1 { exercise.repeatCount = 1 }
                        }
                }

                if exercise.repeatCount > 1 {
                    HStack {
                        Text("Transpose per repetition")
                        Spacer()
                        TextField("0", value: $exercise.transposePerRepeat, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .frame(width: 60)
                    }

                    HStack {
                        Text("Time between reps")
                        Spacer()
                        TextField("0", value: $exercise.beatsBetweenReps, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(width: 60)
                        Text("beats").foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                NavigationLink(value: ExerciseRoute.edit(exercise.id)) {
                    Label("Edit MIDI", systemImage: "pianokeys")
                }
            }

            Section {
                Button(role: .destructive) {
                    let id = exercise.id
                    dismiss()
                    // Delete after the pop so no view is bound to the removed exercise.
                    DispatchQueue.main.async { store.delete(id: id) }
                } label: {
                    Label("Delete Exercise", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
