import SwiftUI
import UIKit

struct ExerciseSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @Binding var exercise: Exercise
    @EnvironmentObject private var store: ExerciseStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    /// Drives the "really delete?" confirmation shown by the delete button.
    @State private var isConfirmingDelete = false

    /// Shown when publishing (or renaming a public exercise) would give this
    /// user two public exercises with the same name; the exercise is kept (or
    /// put back to) private. Different users may share the same name.
    @State private var isWarningDuplicateName = false

    /// The exercise's saved MIDI pattern and the labels written over it, for the
    /// preview at the top of the screen. Read when the screen appears rather than
    /// per frame — the pattern lives in UserDefaults, and only the MIDI editor
    /// changes it.
    @State private var pattern: [MIDINote] = []
    @State private var labels: [MIDIText] = []

    /// How far the form is scrolled (0 at rest, growing downward), which collapses
    /// the preview pinned above it.
    @State private var scrollOffset: CGFloat = 0

    /// The text fields that can hold keyboard focus, so a single keyboard toolbar
    /// can show a "Done" button (and the sign toggle for the fields that take a
    /// negative value) above whichever one is being edited.
    private enum Field {
        case name, details, repeatCount, transpose, switchDirection, speed, betweenReps
    }
    private var pitchLabel: String {
        let s = exercise.pitchShift
        let sign = s > 0 ? "+" : ""
        let unit = abs(s) == 1 ? L("semitone") : L("semitones")
        return "\(sign)\(s) \(unit)"
    }

    /// What the keyboard bar's sign toggle does for the field being edited, and
    /// nil for the fields that don't take a negative value — the bar leaves the
    /// button out for those, so only "Done" is shown. Downward transpositions
    /// and slow-downs are the two that need it.
    private var signToggle: (() -> Void)? {
        switch focusedField {
        case .transpose: return { exercise.transposePerRepeat.negate() }
        case .speed: return { exercise.speedPerRepeat.negate() }
        default: return nil
        }
    }

    var body: some View {
        // The preview is pinned above the form rather than scrolling with it: what it
        // shows is what the controls below are setting, so it stays in sight while
        // they're used — collapsing as the form scrolls instead of moving away.
        GeometryReader { geo in
            let previewWidth = max(0, geo.size.width - 2 * ExercisePlaybackPreview.sidePadding)
            // Square, like the visuals screen's — but never more than half of what
            // the screen has: in landscape a square would be taller than the screen
            // and leave no room for the settings it belongs to.
            let previewSize = min(previewWidth, geo.size.height / 2)
            let previewHeight = pattern.isEmpty
                ? 0
                : previewSize + 2 * ExercisePlaybackPreview.verticalPadding
            settingsForm
                .contentMargins(.top, previewHeight)
                .onScrollGeometryChange(for: CGFloat.self) { scroll in
                    scroll.contentOffset.y + scroll.contentInsets.top
                } action: { _, offset in
                    scrollOffset = offset
                }
                .overlay(alignment: .top) {
                    // An exercise with no notes has nothing to preview, exactly as it
                    // gets no pattern thumbnail in the lists.
                    if !pattern.isEmpty {
                        ExercisePlaybackPreview(
                            exercise: exercise, pattern: pattern, labels: labels,
                            width: previewWidth, fullHeight: previewSize,
                            scrollOffset: scrollOffset)
                    }
                }
        }
        // Read again every time the screen comes back, so a pattern just changed in
        // the MIDI editor is the one the preview draws.
        .onAppear {
            pattern = store.notes(for: exercise.id)
            labels = store.texts(for: exercise.id)
        }
        .alert("Delete Exercise?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                let id = exercise.id
                // The pop below would otherwise toast "Exercise Saved!".
                toasts.suppressNext()
                dismiss()
                // Delete after the pop so no view is bound to the removed exercise.
                DispatchQueue.main.async { store.delete(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(L("\"%@\" and its MIDI pattern will be deleted. This cannot be undone.", exercise.name))
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
            if old == .speed, new != .speed { clampSpeedPerRepeat() }
        }
        .alert("Name Already Public", isPresented: $isWarningDuplicateName) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L("You already have a public exercise named \"%@\". Each of your public exercises needs a unique name, so this one stays private.", exercise.name))
        }
        .navigationTitle(exercise.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        // The description field's return key inserts a newline rather than
        // closing the keyboard, so a scroll is what puts it away — the same
        // swipe down over the keyboard that works on every other screen.
        .scrollDismissesKeyboard(.interactively)
        .keyboardBar(onToggleSign: signToggle) { focusedField = nil }
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

    private var settingsForm: some View {
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
                    Text(L("%d BPM", Int(exercise.bpm))).foregroundStyle(.secondary)
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
                        Text("Speed up per repetition")
                        Spacer()
                        TextField("0", value: $exercise.speedPerRepeat, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .speed)
                            .frame(width: 60)
                        Text("BPM").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { focusedField = .speed }

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

            // Bundled exercises can't be shared, so they get no visibility
            // setting at all.
            if !store.isBundled(exercise.id) {
                Section {
                    Picker("Visibility", selection: $exercise.visibility) {
                        ForEach(ExerciseVisibility.allCases, id: \.self) { visibility in
                            Text(visibility.label).tag(visibility)
                        }
                    }
                    .settingHelp(L("Public exercises appear on the Community tab."))
                } header: {
                    Text("Visibility")
                }
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Exercise", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .dangerRow()
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

    /// Keep "speed up per repetition" within ±`Exercise.maxSpeedPerRepeat` BPM.
    /// Applied when the field is done being edited (the keyboard's "Done" button, or
    /// focus moving on) rather than per keystroke, so a value typed digit by digit
    /// isn't cut short on its way to the one the singer meant.
    private func clampSpeedPerRepeat() {
        let limit = Exercise.maxSpeedPerRepeat
        exercise.speedPerRepeat = min(max(exercise.speedPerRepeat, -limit), limit)
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
