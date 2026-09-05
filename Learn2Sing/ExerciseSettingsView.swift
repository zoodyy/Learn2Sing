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

    /// Shown when publishing is refused because the exercise is shorter than
    /// `Exercise.minimumPublicDuration`; it stays private.
    @State private var isWarningTooShortToPublish = false

    /// Shown when a change made here drops an exercise that is already public
    /// under that minimum. It can't stay as it is, so the user picks which way
    /// out: off the Community tab, or back to how this screen found it.
    @State private var isResolvingTooShort = false

    /// The exercise, its notes and the labels over them exactly as this screen
    /// found them, which "Undo My Changes" puts back. Taken on the first
    /// appearance only: the screen appears again every time the MIDI editor is
    /// left, and what was drawn in there is a change made from here too.
    @State private var openState: Exercise?
    @State private var openNotes: [MIDINote] = []
    @State private var openLabels: [MIDIText] = []

    /// Whether the exercise obeyed the public-length rule when the screen
    /// opened. One that was already public and too short — published before the
    /// rule existed, or imported that way — is left alone: nothing done here
    /// caused it, and putting the screen back the way it was found wouldn't fix
    /// it either.
    @State private var wasWithinLengthRuleOnOpen = true

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
            let notes = store.notes(for: exercise.id)
            let texts = store.texts(for: exercise.id)
            pattern = notes
            labels = texts
            if openState == nil {
                openState = exercise
                openNotes = notes
                openLabels = texts
                wasWithinLengthRuleOnOpen = exercise.visibility != .public
                    || clearsMinimumLength(exercise.contentDuration(pattern: notes))
            } else {
                // Back from the MIDI editor: notes taken out in there shorten the
                // exercise exactly as the settings below do. Asked for a tick later
                // so the alert isn't put up while the screen is still arriving.
                DispatchQueue.main.async { enforcePublicMinimumLength() }
            }
        }
        // A value typed into one of the repetition fields is committed as it is
        // typed but only measured once the field is done being edited, so leaving
        // with the keyboard still up is the one way past the question below. The
        // rule holds anyway: the exercise comes off the Community tab.
        .onDisappear {
            guard wasWithinLengthRuleOnOpen, exercise.visibility == .public,
                  !isLongEnoughToPublish else { return }
            exercise.visibility = .private
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
        // next to the exercise on the Community tab — unless the exercise is too
        // short to be worth anyone's download, or the user already shares another
        // exercise with this name. Either one is refused.
        .onChange(of: exercise.visibility) { _, newValue in
            guard newValue == .public else { return }
            if !isLongEnoughToPublish {
                exercise.visibility = .private
                isWarningTooShortToPublish = true
            } else if isPublicNameTaken() {
                exercise.visibility = .private
                isWarningDuplicateName = true
            } else {
                exercise.uploaderName = UserProfile.load().username
            }
        }
        // Renames are checked when editing ends, not per keystroke — a name
        // passes through spurious collisions while being typed. The same goes for
        // the fields that decide how long the exercise runs: "20" repetitions
        // passes through "2" on its way in.
        .onChange(of: focusedField) { old, new in
            guard old != new else { return }
            switch old {
            case .name:
                demoteIfNameTaken()
            case .speed:
                clampSpeedPerRepeat()
                enforcePublicMinimumLength()
            case .repeatCount, .betweenReps:
                enforcePublicMinimumLength()
            default:
                break
            }
        }
        .alert("Name Already Public", isPresented: $isWarningDuplicateName) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L("You already have a public exercise named \"%@\". Each of your public exercises needs a unique name, so this one stays private.", exercise.name))
        }
        .alert("Too Short to Publish", isPresented: $isWarningTooShortToPublish) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(L("This exercise lasts %@. A public exercise has to last at least %@, counting all of its repetitions together, so this one stays private.",
                   formattedLength(contentLength),
                   formattedLength(Exercise.minimumPublicDuration)))
        }
        // Two ways out and no way past: whichever the user picks leaves the
        // exercise inside the rule, so the question is only ever asked once per
        // change that breaks it.
        .alert("Too Short to Stay Public", isPresented: $isResolvingTooShort) {
            Button("Make Private") { exercise.visibility = .private }
            Button("Undo My Changes") { revertToOpenState() }
        } message: {
            Text(L("A public exercise has to last at least %@, counting all of its repetitions together, and your changes bring this one down to %@. Make it private, or undo everything you have changed since you opened its settings.",
                   formattedLength(Exercise.minimumPublicDuration),
                   formattedLength(contentLength)))
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
                    .settingHelp(L("What this exercise is called in your lists."))
            }

            Section("Description") {
                TextField("Shown before the exercise starts", text: $exercise.details, axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focusedField, equals: .details)
                    .settingHelp(L("Your note on what to do, shown on the screen before the exercise starts."))
            }

            Section {
                NavigationLink(value: ExerciseRoute.edit(exercise.id)) {
                    Label("Edit MIDI", systemImage: "pianokeys")
                }
                .settingHelp(L("Opens the note editor, where you draw this exercise's notes and write labels on them."))
            }

            Section("Pitch") {
                Stepper(value: $exercise.pitchShift, in: -24...24) {
                    HStack {
                        Text("Transpose")
                        Spacer()
                        Text(pitchLabel).foregroundStyle(.secondary)
                    }
                }
                .settingHelp(L("Moves every note of the exercise up or down by this many semitones. 12 is a whole octave."))
            }

            Section("Tempo") {
                HStack {
                    Text("Tempo")
                    Spacer()
                    Text(L("%d BPM", Int(exercise.bpm))).foregroundStyle(.secondary)
                }
                .settingHelp(L("How fast the exercise is played, in beats per minute."))
                // Measured when the drag ends rather than as it moves: a tempo on
                // its way past the limit isn't one the singer has settled on.
                Slider(value: $exercise.bpm, in: 40...240, step: 1,
                       onEditingChanged: { editing in
                           if !editing { enforcePublicMinimumLength() }
                       })
                    .settingHelp(L("How fast the exercise is played, in beats per minute."))
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
                .settingHelp(L("How many times the pattern is played in a row."))

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
                    .settingHelp(L("Each repetition starts this many semitones above the one before it. A negative value works downwards."))

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
                        .settingHelp(L("After this many repetitions the transposing turns around, so the exercise climbs and then comes back down. 0 never turns."))
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
                    .settingHelp(L("Each repetition is played this many BPM faster than the one before it. A negative value slows it down."))

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
                    .settingHelp(L("Silent beats left between one repetition and the next, to breathe in."))
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
                    .settingHelp(L("Public exercises appear on the Community tab. Only an exercise lasting at least %@, counting all of its repetitions together, can be made public.",
                                   formattedLength(Exercise.minimumPublicDuration)))
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
                .settingHelp(L("Deletes this exercise, its notes and its scores. This cannot be undone."))
            }
        }
    }

    // MARK: - Minimum length for a public exercise

    /// How long the exercise lasts as this screen currently has it: all of its
    /// repetitions and the silence between them, without the count-in. This is
    /// what the public minimum is measured against.
    private var contentLength: Double {
        exercise.contentDuration(pattern: pattern)
    }

    private var isLongEnoughToPublish: Bool { clearsMinimumLength(contentLength) }

    /// Whether `seconds` clears `Exercise.minimumPublicDuration`. The slack
    /// absorbs the rounding of beats into seconds, so an exercise landing exactly
    /// on the limit is never refused over a fraction of a millisecond.
    private func clearsMinimumLength(_ seconds: Double) -> Bool {
        seconds >= Exercise.minimumPublicDuration - 0.0001
    }

    /// A length written out for the alerts and the help bubble, in whole seconds
    /// and in the app's chosen language. Rounded down, so an exercise a hair
    /// under the limit is never reported as the length the rule asks for.
    private func formattedLength(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds).rounded(.down)).formatted(
            Duration.UnitsFormatStyle(allowedUnits: [.seconds], width: .wide)
                .locale(appLanguage.language.locale))
    }

    /// Called wherever a change to the exercise's length is finished being made.
    /// A public exercise that has just dropped under the minimum can't be left
    /// as it is, so the user is asked which way out they want.
    private func enforcePublicMinimumLength() {
        guard wasWithinLengthRuleOnOpen, exercise.visibility == .public,
              !isLongEnoughToPublish, !isResolvingTooShort else { return }
        isResolvingTooShort = true
    }

    /// Puts the exercise back exactly as this screen found it: its settings, its
    /// notes and the labels over them. The pattern goes back too because the MIDI
    /// editor writes every stroke through as it is drawn, so a repetition emptied
    /// out in there is one of the changes made from here.
    private func revertToOpenState() {
        guard let openState else { return }
        store.restorePattern(notes: openNotes, texts: openLabels, for: openState.id)
        pattern = openNotes
        labels = openLabels
        // Last, so the write to the store that the server syncs watch happens
        // once the pattern they upload alongside it is back in place.
        exercise = openState
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
