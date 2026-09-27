//
//  PitchDetectionPrompt.swift
//  Learn2Sing
//
//  The one-off question the score screen asks after the singer's fourth scored run:
//  which pitch detection they want. And Try It Out, where the choices can be
//  compared while singing, reached from that question and from Settings ▸ Voice.
//

import SwiftUI

/// Whether the score screen still owes the singer the question, and the runs it
/// waits for before asking.
///
/// It waits for four scored runs rather than asking up front: the choice is about
/// how the pitch line looks while singing, and until the singer has watched it a few
/// times there is nothing to judge it by. Only runs that earned a score count, the
/// ones the score history keeps (a silent 0% run isn't one), which also means a
/// singer who already had four when this was added is asked after their next.
///
/// The flag lives in UserDefaults outside `UserSettings`, like `CategoryHint`'s: it
/// records what has happened on this install rather than something the singer chose.
enum PitchDetectionPrompt {
    /// How many scored runs come before the question.
    static let scoredRunsBeforeAsking = 4

    private static let shownKey = "didShowPitchDetectionPrompt"

    /// Whether the score screen just reached should ask. Called once the run's score
    /// is saved, so that run is among the ones counted.
    static var isDue: Bool {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return false }
        var runs = 0
        for history in ScoreHistory.all().values {
            runs += history.count
            if runs >= scoredRunsBeforeAsking { return true }
        }
        return false
    }

    /// Remember it has been asked. Set as the question goes up rather than when it
    /// is answered: closing it without a word keeps the choice already checked,
    /// which is an answer too.
    static func markShown() {
        UserDefaults.standard.set(true, forKey: shownKey)
    }
}

/// What Try It Out plays: "Buh Duh Guh", a bundled exercise sung on voiced
/// plosives. Those consonants are where the choices differ most (the fastest line
/// jumps at every "b", "d" and "g"; the slowest stays on the note), and it spans an
/// octave at an easy tempo. Always as it ships, whatever the library holds.
enum PitchDetectionTrial {
    static let exerciseID = UUID(uuidString: "AA855D4A-4571-4AA4-AE69-FECC0BFBE44D")!

    /// nil only if the bundle has lost it, in which case nothing offers Try It Out.
    static var exercise: Exercise? { ExerciseStore.bundledOriginal(exerciseID) }

    /// What the Try It Out button does, said the same way wherever it appears.
    static var help: String {
        L("Plays an exercise on repeat, so you can switch between the choices while you sing and see how each one draws your line.")
    }
}

// MARK: - The question

/// The sheet the score screen puts up after the fourth scored run: what the setting
/// does, the three choices (the balanced one recommended, the slowest one not), what
/// the checked one does, Try It Out, and where to change it later.
///
/// Tapping a choice sets it, as the rows on the Voice screen do, so there is nothing
/// to lose by closing the sheet however it is closed.
struct PitchDetectionPromptView: View {
    /// Re-renders when the language is changed; the strings are resolved when the
    /// body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(PitchDetection.storageKey) private var detectionRaw = PitchDetection.defaultValue.rawValue

    @Environment(\.dismiss) private var dismiss

    @State private var isTrying = false
    /// Set when Try It Out was left through its choose button: the choice has been
    /// made there, so this sheet goes too, once the try-out has.
    @State private var choseInTrial = false
    /// The height of everything on the sheet, which is the height it opens to. The
    /// first guess only matters until the first layout.
    @State private var contentHeight: CGFloat = 620

    private var selection: PitchDetection {
        PitchDetection(rawValue: detectionRaw) ?? .defaultValue
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                VStack(spacing: 10) {
                    choices
                    selectionHelp
                }
                tryButton
                VStack(spacing: 12) {
                    Text("You can change this anytime in Settings under Voice.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .explain(L("The Voice screen in Settings lists the same choices, with Try It Out beside them."))
                    doneButton
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $isTrying, onDismiss: {
            if choseInTrial { dismiss() }
        }) {
            PitchDetectionTrialCover {
                choseInTrial = true
                isTrying = false
            }
        }
        // Asserted again here: a presentation takes neither the language nor the
        // appearance from the screen it is presented over (see IntroTutorialView).
        .environment(\.locale, appLanguage.language.locale)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Pitch Detection")
                .font(.title2.weight(.bold))
            Text("How quickly your pitch line follows your voice. Slower choices are thrown off less by consonants, and your score allows for the wait.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        // The longer telling, the one the Voice screen's section heading gives.
        .explain(SettingsCatalog.help(for: .voicePitchDetection))
    }

    /// The three choices, grouped the way a settings list groups its rows.
    private var choices: some View {
        VStack(spacing: 0) {
            ForEach(PitchDetection.allCases) { detection in
                if detection != PitchDetection.allCases.first {
                    Divider().padding(.leading, 16)
                }
                Button {
                    detectionRaw = detection.rawValue
                } label: {
                    choiceRow(detection)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(detection == selection ? .isSelected : [])
                .explain(detection.help)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func choiceRow(_ detection: PitchDetection) -> some View {
        let isSelected = detection == selection
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: detection.title)
                    .foregroundStyle(.primary)
                if let recommendation = detection.recommendation {
                    let color: Color = recommendation.isRecommended ? .green : .orange
                    Text(verbatim: recommendation.text)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(color.opacity(0.15), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// What the checked choice does: its press-and-hold text, always in view here.
    private var selectionHelp: some View {
        PitchDetectionHelpText(selection: selection)
            .padding(.horizontal, 4)
            .explain(L("What the checked choice above does to your pitch line."))
    }

    private var tryButton: some View {
        Button {
            isTrying = true
        } label: {
            Label("Try It Out", systemImage: "play.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.tint)
        }
        .disabled(PitchDetectionTrial.exercise == nil)
        .explain(PitchDetectionTrial.help)
    }

    private var doneButton: some View {
        Button {
            dismiss()
        } label: {
            Text("Done")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
        .explain(L("Keeps the checked choice and closes this."))
    }
}

/// A choice's press-and-hold text as a line of small print. Every choice's text is
/// laid out and only the chosen one shown, so the space it takes is the longest one's
/// and nothing below it moves when the choice changes.
private struct PitchDetectionHelpText: View {
    let selection: PitchDetection

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(PitchDetection.allCases) { detection in
                Text(verbatim: detection.help)
                    .opacity(detection == selection ? 1 : 0)
                    .accessibilityHidden(detection != selection)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Try It Out

/// The panel under Try It Out's exercise: the choices side by side, switched while
/// singing, what the selected one does, and the button that makes it the setting.
/// Switching only changes the line on this screen; the setting stays as it was until
/// that button is tapped.
struct PitchDetectionTrialPanel: View {
    /// Re-renders when the language is changed, the same as the screen around it.
    @ObservedObject private var appLanguage = LanguageManager.shared
    @AppStorage(PitchDetection.storageKey) private var detectionRaw = PitchDetection.defaultValue.rawValue

    @Binding var selection: PitchDetection
    /// Called once the selected choice has been saved, to leave the try-out.
    let onChosen: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker("Pitch Detection", selection: $selection) {
                ForEach(PitchDetection.allCases) { detection in
                    Text(verbatim: detection.shortTitle).tag(detection)
                }
            }
            .pickerStyle(.segmented)
            .explain(L("Switches how your pitch line is drawn straight away, so you can compare the choices while you sing."))

            PitchDetectionHelpText(selection: selection)
                .explain(L("What the selected choice does to your pitch line."))

            Button {
                detectionRaw = selection.rawValue
                onChosen()
            } label: {
                Text("Use This Pitch Detection")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .explain(L("Makes the selected choice your pitch detection and leaves this screen."))
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
    }
}

/// Try It Out opened from the question, over everything: the same screen Settings
/// pushes, in a navigation stack of its own for its bar, with a close button where
/// the back button would be.
struct PitchDetectionTrialCover: View {
    @ObservedObject private var appLanguage = LanguageManager.shared
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    @Environment(\.dismiss) private var dismiss

    /// Called when a choice has been made and saved.
    let onChosen: () -> Void

    var body: some View {
        NavigationStack {
            if let exercise = PitchDetectionTrial.exercise {
                PlaybackView(exercise: exercise, mode: .pitchDetectionTrial, onTrialExit: onChosen)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "xmark")
                                    .toolbarSymbolHitArea()
                            }
                            .accessibilityLabel(L("Close"))
                            .explain(L("Closes this without changing your pitch detection."))
                        }
                    }
            }
        }
        // A presentation takes neither the language nor the appearance from the
        // screen it is presented over (see IntroTutorialView).
        .environment(\.locale, appLanguage.language.locale)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }
}
