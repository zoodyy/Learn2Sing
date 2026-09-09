//
//  ResetSettingsView.swift
//  Learn2Sing
//
//  The "Reset" category in Settings and its four screens. Everything here
//  destroys something, so every action goes through the same confirmation and
//  each row spells out in its help text what survives it. Nothing on these
//  screens can be undone — the Backup category is where a copy is made first.
//

import SwiftUI

/// The "Reset" hub reached from Settings, sitting below "Backup". Splits the
/// undoing along the same lines the rest of the app is organised by: recorded
/// scores, the settings themselves, the exercise library, and the Home tab's
/// lists.
struct ResetSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// Push each screen onto the shared Settings navigation stack.
    let openScores: () -> Void
    let openSettings: () -> Void
    let openExercises: () -> Void
    let openHome: () -> Void

    var body: some View {
        Form {
            Section {
                SettingsHubRow(title: L("Scores"), systemImage: "chart.line.uptrend.xyaxis",
                               action: openScores)
                    .setting(.resetScoresRow)

                SettingsHubRow(title: L("Settings"), systemImage: "gearshape", action: openSettings)
                    .setting(.resetSettingsRow)

                SettingsHubRow(title: L("Exercises"), systemImage: "list.bullet",
                               action: openExercises)
                    .setting(.resetExercisesRow)

                SettingsHubRow(title: L("Home"), systemImage: "house", action: openHome)
                    .setting(.resetHomeRow)
            }
        }
        .navigationTitle(L("Reset"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.reset)
    }
}

// MARK: - Scores

/// Reset ▸ Scores: deletes the score history behind the chart on each result
/// screen, for one exercise or for the whole library.
struct ScoresResetView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    /// One exercise's score row. Held in state rather than recomputed each render
    /// because the counts come from UserDefaults, which publishes nothing —
    /// rebuilding the list after a deletion is what refreshes the screen.
    private struct ScoredExercise: Identifiable {
        let id: UUID
        let name: String
        let count: Int
    }

    @State private var scored: [ScoredExercise] = []

    /// What the confirmation is currently asking about, nil when it's closed.
    /// Equatable so each row can present the dialog for its own case, which is
    /// what points it at the row the user tapped.
    private enum Deletion: Equatable {
        case one(id: UUID, name: String)
        case all
    }

    @State private var pending: Deletion?

    var body: some View {
        Form {
            Section {
                if scored.isEmpty {
                    Text("No scores have been recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scored) { entry in
                        Button {
                            pending = .one(id: entry.id, name: entry.name)
                        } label: {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                Text(verbatim: "\(entry.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .settingHelp(L("Deletes the scores recorded for this exercise. The exercise itself is kept."))
                        .resetConfirmation(
                            $pending, for: .one(id: entry.id, name: entry.name),
                            confirmLabel: L("Delete"),
                            message: L("The scores recorded for “%@” will be deleted.", entry.name)
                        ) {
                            ScoreHistory.delete(for: entry.id)
                            reload()
                        }
                    }
                }
            } header: {
                Text("Recorded scores").settingSection(.resetRecordedScores)
            }

            Section {
                Button(role: .destructive) {
                    pending = .all
                } label: {
                    Label("Delete All Scores", systemImage: "trash")
                }
                .dangerRow()
                .disabled(scored.isEmpty)
                .setting(.deleteAllScores)
                .resetConfirmation(
                    $pending, for: .all,
                    confirmLabel: L("Delete"),
                    message: L("The scores recorded for every exercise will be deleted.")
                ) {
                    ScoreHistory.deleteAll()
                    reload()
                }
            }
        }
        .navigationTitle(L("Scores"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.resetScores)
        .onAppear(perform: reload)
    }

    /// The exercises that have at least one recorded score, in library order.
    private func reload() {
        scored = store.exercises.compactMap { exercise in
            let count = ScoreHistory.entries(for: exercise.id).count
            guard count > 0 else { return nil }
            return ScoredExercise(id: exercise.id, name: exercise.localizedName, count: count)
        }
    }
}

// MARK: - Settings

/// A settings category from the Settings hub that has something to put back.
/// "Backup" and "Reset" itself are absent: neither stores a setting.
enum ResettableSettings: String, CaseIterable, Identifiable {
    case profile, audio, voice, visuals, homeTab, language

    var id: String { rawValue }

    /// Title and symbol match the category's row on the Settings hub.
    var title: String {
        switch self {
        case .profile:  L("Profile")
        case .audio:    L("Audio")
        case .voice:    L("Voice")
        case .visuals:  L("Visuals")
        case .homeTab:  L("Home Tab")
        case .language: L("Language")
        }
    }

    var systemImage: String {
        switch self {
        case .profile:  "person.crop.circle"
        case .audio:    "speaker.wave.2"
        case .voice:    "music.mic"
        case .visuals:  "paintpalette"
        case .homeTab:  "house"
        case .language: "globe"
        }
    }

    /// What the reset touches and, just as importantly, what it leaves alone.
    var help: String {
        switch self {
        case .profile:
            L("Clears the username you chose. Your device ID and your exercises are kept.")
        case .audio:
            L("Puts the instrument, the playback and recording devices and the microphone delay back to their starting values. Instruments you uploaded are kept.")
        case .visuals:
            L("Puts the theme, the orientation lock and the look of the menus and the playback screen back to how they started out. Templates you saved are deleted, and the app's own two come back as they started out.")
        case .voice:
            L("Clears your vocal range, including the custom lowest and highest notes, and puts the target window back to the whole note.")
        case .homeTab:
            L("Puts the number of recommended exercises back, and returns the whitelist to every exercise in your library, dropping the ones you ticked or unticked yourself. The categories the tab shows and the order they come in are left as you arranged them.")
        case .language:
            L("Puts the app's language back to English.")
        }
    }

    /// Remove the stored values so every setting in the category reads as its
    /// default again, which is exactly what an untouched install shows.
    @MainActor
    func reset(store: ExerciseStore, templates: VisualTemplateStore) {
        let defaults = UserDefaults.standard
        switch self {
        case .profile:
            var profile = UserProfile.load()
            profile.username = ""
            profile.save()
            // Same pair of pushes the profile screen makes when the name changes,
            // so the server copy and the Community tab's label follow.
            ProfileSync.shared.scheduleUpload()
            CommunitySync.shared.scheduleUpload()
        case .audio:
            for key in [AudioRouteManager.speakerKey, AudioRouteManager.micKey,
                        microphoneDelayKey, Instrument.storageKey] {
                defaults.removeObject(forKey: key)
            }
        case .visuals:
            // Detach from the selected template before clearing the keys, so the
            // cleared values aren't saved into it as an edit.
            templates.deselect()
            for key in [AppTheme.storageKey, OrientationLock.storageKey,
                        MenuVisualKeys.exercisePreviewColor] + VisualKeys.all {
                defaults.removeObject(forKey: key)
            }
            OrientationLockManager.apply(.none)
            // A fresh install doesn't sit on the raw playback defaults: the bundled
            // template matching the app's appearance is applied on first launch, so
            // that — not `VisualDefaults` — is the look to come back to. The theme
            // key is cleared just above, so the appearance is the device's own again
            // by now. This puts the templates list back to what that install finds
            // too — only the app's own two, as it ships them — and selects the one
            // for the appearance.
            templates.resetToBundled()
        case .voice:
            for key in [VocalRange.storageKey, VocalRange.customLowKey,
                        VocalRange.customHighKey, ScoreTargetWindow.storageKey] {
                defaults.removeObject(forKey: key)
            }
        case .homeTab:
            defaults.removeObject(forKey: RecommendedExercises.minutesKey)
            defaults.removeObject(forKey: RecommendedExercises.asListKey)
            store.resetRecommendationWhitelist()
        case .language:
            LanguageManager.shared.language = .english
            defaults.removeObject(forKey: LanguageManager.storageKey)
        }
    }
}

/// Reset ▸ Settings: one row per settings category, plus a row that does the
/// lot. Only settings are touched — no exercise, score or routine is deleted
/// here, which the other three screens are for.
struct SettingsResetView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling. Doubly
    /// so here — resetting the Language category repaints this very screen.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    /// Resetting the visuals puts the bundled template back and re-selects it, so the
    /// live store — not just UserDefaults — has to hear about it.
    @EnvironmentObject private var visualTemplates: VisualTemplateStore

    /// Equatable so each row can present the dialog for its own case, which is
    /// what points it at the row the user tapped.
    private enum Reset: Equatable {
        case one(ResettableSettings)
        case all
    }

    @State private var pending: Reset?

    var body: some View {
        Form {
            Section {
                ForEach(ResettableSettings.allCases) { category in
                    Button {
                        pending = .one(category)
                    } label: {
                        Label(category.title, systemImage: category.systemImage)
                    }
                    .foregroundStyle(.primary)
                    .setting(.resetCategory(category))
                    .resetConfirmation(
                        $pending, for: .one(category),
                        confirmLabel: L("Reset"),
                        message: L("The settings under “%@” go back to how the app started out.",
                                   category.title)
                    ) {
                        category.reset(store: store, templates: visualTemplates)
                    }
                }
            } header: {
                Text("Categories").settingSection(.resetCategories)
            }

            Section {
                Button(role: .destructive) {
                    pending = .all
                } label: {
                    Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                }
                .dangerRow()
                .setting(.resetAllSettings)
                .resetConfirmation(
                    $pending, for: .all,
                    confirmLabel: L("Reset"),
                    message: L("Every setting in the app goes back to how it started out.")
                ) {
                    ResettableSettings.allCases.forEach { $0.reset(store: store, templates: visualTemplates) }
                }
            }
        }
        .navigationTitle(L("Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.resetSettings)
    }
}

// MARK: - Exercises

/// Reset ▸ Exercises: deletes the exercises the user brought into the library
/// themselves, and undoes their edits to the ones that shipped with the app.
struct ExercisesResetView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    /// Equatable so each row can present the dialog for its own case, which is
    /// what points it at the row the user tapped.
    private enum Reset: Equatable {
        case own
        case downloaded
        case bundled(id: UUID, name: String)
        case allBundled
    }

    @State private var pending: Reset?

    /// The bundled exercises the user has changed, with the name to show for
    /// each: what they call it now, or its shipped name if they deleted it.
    private var changedBundled: [(id: UUID, name: String, isDeleted: Bool)] {
        store.changedBundledIDs.map { id in
            if let current = store.exercises.first(where: { $0.id == id }) {
                return (id, current.localizedName, false)
            }
            return (id, ExerciseStore.bundledOriginal(id)?.localizedName ?? "", true)
        }
    }

    var body: some View {
        Form {
            Section {
                countedButton(L("Delete Own Exercises"), systemImage: "person",
                              count: store.ownExerciseIDs.count) {
                    pending = .own
                }
                .setting(.deleteOwnExercises)
                .resetConfirmation(
                    $pending, for: .own,
                    confirmLabel: L("Delete"),
                    message: L("Every exercise you created yourself will be deleted, along with its MIDI pattern and scores.")
                ) {
                    store.deleteOwnExercises()
                }

                countedButton(L("Delete Downloaded Exercises"), systemImage: "person.3",
                              count: store.downloadedExerciseIDs.count) {
                    pending = .downloaded
                }
                .setting(.deleteDownloadedExercises)
                .resetConfirmation(
                    $pending, for: .downloaded,
                    confirmLabel: L("Delete"),
                    message: L("Every exercise you downloaded from the Community tab will be deleted, along with its MIDI pattern and scores.")
                ) {
                    store.deleteDownloadedExercises()
                }
            } header: {
                Text("Your exercises").settingSection(.resetYourExercises)
            }

            Section {
                let changed = changedBundled
                if changed.isEmpty {
                    Text("You haven't changed any of the exercises that came with the app.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(changed, id: \.id) { entry in
                        Button {
                            pending = .bundled(id: entry.id, name: entry.name)
                        } label: {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                if entry.isDeleted {
                                    Text("Deleted").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .settingHelp(L("Puts this exercise back to how it came with the app, undoing your edits to its settings and its MIDI pattern."))
                        .resetConfirmation(
                            $pending, for: .bundled(id: entry.id, name: entry.name),
                            confirmLabel: L("Revert"),
                            message: L("“%@” goes back to how it came with the app.", entry.name)
                        ) {
                            store.revertBundled(entry.id)
                        }
                    }
                }

                Button(role: .destructive) {
                    pending = .allBundled
                } label: {
                    Label("Revert All Bundled Exercises", systemImage: "arrow.uturn.backward")
                }
                .dangerRow()
                .disabled(changed.isEmpty)
                .setting(.revertAllBundled)
                .resetConfirmation(
                    $pending, for: .allBundled,
                    confirmLabel: L("Revert"),
                    message: L("Every exercise that came with the app goes back to how it shipped, and any you deleted come back.")
                ) {
                    store.revertAllBundled()
                }
            } header: {
                Text("Bundled Exercises").settingSection(.resetBundledExercises)
            }
        }
        .navigationTitle(L("Exercises"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.resetExercises)
    }

    /// A destructive row with the number of exercises it would delete on its
    /// trailing edge, disabled while there are none.
    private func countedButton(_ title: String, systemImage: String, count: Int,
                               action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(verbatim: "\(count)").foregroundStyle(.secondary)
            }
        }
        .dangerRow()
        .disabled(count == 0)
    }
}

// MARK: - Home

/// Reset ▸ Home: clears the three lists the Home tab builds over the library,
/// and the practice time its calendar is drawn from. None of them delete an
/// exercise — only its membership in a list.
struct HomeResetView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    /// Equatable so each row can present the dialog for its own case, which is
    /// what points it at the row the user tapped.
    private enum Reset: Equatable {
        case favourites
        case routines
        case history
        case practice
    }

    @State private var pending: Reset?

    /// How many days have practice time against them. Held in state rather than
    /// read each render because it comes from UserDefaults, which publishes
    /// nothing — clearing it is what refreshes the row.
    @State private var practiceDays = 0

    var body: some View {
        Form {
            Section {
                countedButton(L("Clear Favourites"), systemImage: "star",
                              count: store.favourites.count) {
                    pending = .favourites
                }
                .setting(.clearFavourites)
                .resetConfirmation(
                    $pending, for: .favourites,
                    confirmLabel: L("Delete"),
                    message: L("The Home tab's “Favourites” list will be emptied. The exercises in it are kept.")
                ) {
                    store.clearFavourites()
                }

                countedButton(L("Delete Routines"), systemImage: "list.number",
                              count: store.routines.count) {
                    pending = .routines
                }
                .setting(.deleteRoutines)
                .resetConfirmation(
                    $pending, for: .routines,
                    confirmLabel: L("Delete"),
                    message: L("Every routine will be deleted. The exercises they were made of are kept.")
                ) {
                    store.clearRoutines()
                }

                countedButton(L("Clear Recently Played"), systemImage: "clock.arrow.circlepath",
                              count: store.recentlyPlayed.count) {
                    pending = .history
                }
                .setting(.clearRecentlyPlayed)
                .resetConfirmation(
                    $pending, for: .history,
                    confirmLabel: L("Delete"),
                    message: L("Your play history will be forgotten, emptying the Home tab's “Recent” list.")
                ) {
                    store.clearPlayHistory()
                }

                countedButton(L("Clear Practice Time"), systemImage: "calendar",
                              count: practiceDays) {
                    pending = .practice
                }
                .setting(.clearPracticeTime)
                .resetConfirmation(
                    $pending, for: .practice,
                    confirmLabel: L("Delete"),
                    message: L("Your practice time will be forgotten, emptying the Home tab's “Time Spent Singing”.")
                ) {
                    PracticeLog.deleteAll()
                    practiceDays = 0
                }
            }
        }
        .navigationTitle(L("Home"))
        .navigationBarTitleDisplayMode(.inline)
        .settingsSearchable(.resetHome)
        .onAppear { practiceDays = PracticeLog.all().count }
    }

    /// A destructive row with the size of the list it would clear on its trailing
    /// edge, disabled while that list is empty.
    private func countedButton(_ title: String, systemImage: String, count: Int,
                               action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(verbatim: "\(count)").foregroundStyle(.secondary)
            }
        }
        .dangerRow()
        .disabled(count == 0)
    }
}

// MARK: - Confirmation

private extension View {
    /// The confirmation every Reset action goes through: nothing is deleted until
    /// the user picks the destructive button here (dismissing the dialog any other
    /// way cancels). `pending` holds what the screen was asked for and is cleared
    /// whichever way the dialog closes.
    ///
    /// Applied to the *row* rather than to the screen, and each row names the
    /// `action` it is the confirmation for: the dialog is drawn as a bubble
    /// pointing at the view it's attached to, so anchoring it to the whole Form
    /// left it pointing at nothing in particular. One row's dialog is up at a
    /// time — the row whose `action` `pending` currently holds — which is the same
    /// way the press-and-hold help in `settingHelp(_:)` points at its own row.
    ///
    /// `perform` runs a moment after the user confirms rather than there and then,
    /// because the row it is attached to is usually the one the action does away
    /// with; see the destructive button below.
    func resetConfirmation<Action: Equatable>(
        _ pending: Binding<Action?>,
        for action: Action,
        confirmLabel: String,
        message: String,
        perform: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            Text(L("This can't be undone.")),
            isPresented: Binding(
                get: { pending.wrappedValue == action },
                // Only this row's dialog closing clears the state; a row that
                // isn't the presented one has no business cancelling it.
                set: { if !$0 && pending.wrappedValue == action { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(confirmLabel, role: .destructive) {
                pending.wrappedValue = nil
                // Most of these rows stand for the very thing they delete, so the
                // row — the view this bubble hangs off — goes with it. Doing that
                // while the bubble is still animating away leaves the dialog
                // pointing at a row that no longer exists, and it reappears for a
                // moment on the last snapshot it has of the screen before closing
                // for good: the bubble blinks off, back on, and off again. Letting
                // the dismissal finish first keeps the row underneath it until
                // there is nothing left pointing at it.
                Task { @MainActor in
                    try? await Task.sleep(for: dialogDismissal)
                    perform()
                }
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: {
            Text(message)
        }
    }
}

/// How long the confirmation bubble takes to animate away, with a little room
/// to spare. Only the row's disappearance waits this out — the deletion itself
/// is instant once it starts, and starts as soon as the bubble has gone.
private let dialogDismissal: Duration = .milliseconds(350)
