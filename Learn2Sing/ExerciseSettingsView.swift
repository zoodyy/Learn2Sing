import SwiftUI
import UIKit

struct ExerciseSettingsView: View {
    @Binding var exercise: Exercise
    @EnvironmentObject private var store: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    /// Drives the "really delete?" confirmation shown by the delete button.
    @State private var isConfirmingDelete = false

    /// The text fields that can hold keyboard focus, so a single keyboard toolbar
    /// can show a "Done" button (and the sign toggle for the transpose field) above
    /// whichever one is being edited.
    private enum Field {
        case name, details, repeatCount, transpose, switchDirection, betweenReps
    }
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
                    .focused($focusedField, equals: .name)
            }

            Section("Description") {
                TextField("Shown before the exercise starts", text: $exercise.details, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focusedField, equals: .details)
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
                        .focused($focusedField, equals: .repeatCount)
                        .frame(width: 60)
                        .onChange(of: exercise.repeatCount) { _, newValue in
                            if newValue < 1 { exercise.repeatCount = 1 }
                            clampSwitchDirectionAfter()
                        }
                    Text("time(s)").foregroundStyle(.secondary)
                }

                if exercise.repeatCount > 1 {
                    HStack {
                        Text("Transpose per repetition")
                        Spacer()
                        TextField("0", value: $exercise.transposePerRepeat, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .transpose)
                            .frame(width: 60)
                        Text("semitone(s)").foregroundStyle(.secondary)
                    }

                    if exercise.repeatCount > 2 && exercise.transposePerRepeat != 0 {
                        HStack {
                            Text("Switch transposing direction after")
                            Spacer()
                            TextField("0", value: $exercise.switchDirectionAfter, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .focused($focusedField, equals: .switchDirection)
                                .frame(width: 60)
                                .onChange(of: exercise.switchDirectionAfter) { _, _ in
                                    clampSwitchDirectionAfter()
                                }
                            Text("Repetitions").foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("Time between reps")
                        Spacer()
                        TextField("0", value: $exercise.beatsBetweenReps, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .betweenReps)
                            .frame(width: 60)
                        Text("beat(s)").foregroundStyle(.secondary)
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
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Exercise", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .alert("Delete Exercise?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                let id = exercise.id
                dismiss()
                // Delete after the pop so no view is bound to the removed exercise.
                DispatchQueue.main.async { store.delete(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(exercise.name)\" and its MIDI pattern will be deleted. This cannot be undone.")
        }
        .navigationTitle(exercise.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField == .transpose {
                    // The number pad has no minus key, so offer a sign toggle for
                    // entering negative transpositions.
                    Button {
                        exercise.transposePerRepeat.negate()
                    } label: {
                        Image(systemName: "plus.forwardslash.minus")
                    }
                }
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        // Select the whole number when a repetition field is tapped, so typing a new
        // value replaces the old one instead of inserting alongside it. Scoped to the
        // numeric fields by keyboard type (the Name field uses the default keyboard).
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
            guard let textField = notification.object as? UITextField else { return }
            let numericKeyboards: [UIKeyboardType] = [.numberPad, .numbersAndPunctuation, .decimalPad]
            guard numericKeyboards.contains(textField.keyboardType) else { return }
            DispatchQueue.main.async {
                textField.selectedTextRange = textField.textRange(
                    from: textField.beginningOfDocument, to: textField.endOfDocument)
            }
        }
    }

    /// Keep "switch transposing direction after" within range: never larger than one
    /// less than the number of repetitions, and never negative.
    private func clampSwitchDirectionAfter() {
        let maxValue = max(0, exercise.repeatCount - 1)
        if exercise.switchDirectionAfter > maxValue {
            exercise.switchDirectionAfter = maxValue
        }
        if exercise.switchDirectionAfter < 0 {
            exercise.switchDirectionAfter = 0
        }
    }
}
