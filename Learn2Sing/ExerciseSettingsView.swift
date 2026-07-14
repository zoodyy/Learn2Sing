import SwiftUI
import UIKit

struct ExerciseSettingsView: View {
    @Binding var exercise: Exercise
    @EnvironmentObject private var store: ExerciseStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    /// Drives the "really delete?" confirmation shown by the delete button.
    @State private var isConfirmingDelete = false

    /// Shown when publishing (or renaming a public exercise) would give this
    /// user two public exercises with the same name; the exercise is kept (or
    /// put back to) private. Different users may share the same name.
    @State private var isWarningDuplicateName = false

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
                    .onSubmit { demoteIfNameTaken() }
            }

            Section("Description") {
                TextField("Shown before the exercise starts", text: $exercise.details, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focusedField, equals: .details)
            }

            Section {
                NavigationLink(value: ExerciseRoute.edit(exercise.id)) {
                    Label("Edit MIDI", systemImage: "pianokeys")
                }
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
                .contentShape(Rectangle())
                .onTapGesture { focusedField = .repeatCount }

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
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .transpose }

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
                        .contentShape(Rectangle())
                        .onTapGesture { focusedField = .switchDirection }
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
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .betweenReps }
                }
            }

            Section {
                Picker("Visibility", selection: $exercise.visibility) {
                    ForEach(ExerciseVisibility.allCases, id: \.self) { visibility in
                        Text(visibility.label).tag(visibility)
                    }
                }
            } header: {
                Text("Visibility")
            } footer: {
                Text("Public exercises appear on the Community tab.")
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
        // Publishing stamps the current profile username as the uploader shown
        // next to the exercise on the Community tab — unless the user already
        // shares another exercise with this name, which is refused.
        .onChange(of: exercise.visibility) { _, newValue in
            guard newValue == .public else { return }
            if isPublicNameTaken() {
                exercise.visibility = .private
                isWarningDuplicateName = true
            } else {
                exercise.uploaderName = UserProfile.load().username
            }
        }
        // Renames are checked when editing ends, not per keystroke — a name
        // passes through spurious collisions while being typed.
        .onChange(of: focusedField) { old, new in
            if old == .name, new != .name { demoteIfNameTaken() }
        }
        .alert("Name Already Public", isPresented: $isWarningDuplicateName) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You already have a public exercise named \"\(exercise.name)\". Each of your public exercises needs a unique name, so this one stays private.")
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

    /// Whether another of this user's public exercises already uses this
    /// exercise's name (ignoring case and surrounding whitespace).
    private func isPublicNameTaken() -> Bool {
        let name = exercise.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.exercises.contains {
            $0.id != exercise.id && $0.visibility == .public
                && $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Called when a rename is committed: a public exercise renamed into a
    /// collision with another public one goes back to private, with the same
    /// warning the visibility picker shows.
    private func demoteIfNameTaken() {
        guard exercise.visibility == .public, isPublicNameTaken() else { return }
        exercise.visibility = .private
        isWarningDuplicateName = true
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
