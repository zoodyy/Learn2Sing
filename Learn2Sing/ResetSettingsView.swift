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
                    .settingHelp(L("Delete the scores recorded for a single exercise, or wipe them all."))

                SettingsHubRow(title: L("Settings"), systemImage: "gearshape", action: openSettings)
                    .settingHelp(L("Put a single settings category — or every one of them — back to how the app started out."))

                SettingsHubRow(title: L("Exercises"), systemImage: "list.bullet",
                               action: openExercises)
                    .settingHelp(L("Delete the exercises you made or downloaded, and undo your changes to the ones that came with the app."))

                SettingsHubRow(title: L("Home"), systemImage: "house", action: openHome)
                    .settingHelp(L("Clear the Home tab's favourites, routines and recently played list."))
            }
        }
        .navigationTitle(L("Reset"))
        .navigationBarTitleDisplayMode(.inline)
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
    private enum Deletion {
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
                    }
                }
            } header: {
                Text("Recorded scores")
            }

            Section {
                Button(role: .destructive) {
                    pending = .all
                } label: {
                    Label("Delete All Scores", systemImage: "trash")
                }
                .disabled(scored.isEmpty)
                .settingHelp(L("Deletes the scores of every exercise, including any left behind by exercises you have since deleted. The exercises themselves are kept."))
            }
        }
        .navigationTitle(L("Scores"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .resetConfirmation($pending, confirmLabel: { _ in L("Delete") }) { deletion in
            switch deletion {
            case .one(_, let name):
                L("The scores recorded for “%@” will be deleted.", name)
            case .all:
                L("The scores recorded for every exercise will be deleted.")
            }
        } perform: { deletion in
            switch deletion {
            case .one(let id, _): ScoreHistory.delete(for: id)
            case .all: ScoreHistory.deleteAll()
            }
            reload()
        }
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
    case profile, audio, visuals, voice, exercises, language

    var id: String { rawValue }

    /// Title and symbol match the category's row on the Settings hub.
    var title: String {
        switch self {
        case .profile:   L("Profile")
        case .audio:     L("Audio")
        case .visuals:   L("Visuals")
        case .voice:     L("Voice")
        case .exercises: L("Exercises")
        case .language:  L("Language")
        }
    }

    var systemImage: String {
        switch self {
        case .profile:   "person.crop.circle"
        case .audio:     "speaker.wave.2"
        case .visuals:   "paintpalette"
        case .voice:     "music.mic"
        case .exercises: "list.bullet"
        case .language:  "globe"
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
            L("Puts the theme, the orientation lock and the look of the menus and the playback screen back to how they started out. Templates you saved are kept.")
        case .voice:
            L("Clears your vocal range, including the custom lowest and highest notes.")
        case .exercises:
            L("Puts the number of recommended exercises back, and returns the whitelist to the exercises that came with the app.")
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
            // A fresh install doesn't sit on the raw playback defaults: the
            // template shipped in the app bundle is applied on first launch, so
            // that — not `VisualDefaults` — is the look to come back to. It also
            // becomes the selected template again if the user still has it.
            templates.resetToBundled()
        case .voice:
            for key in [VocalRange.storageKey, VocalRange.customLowKey,
                        VocalRange.customHighKey] {
                defaults.removeObject(forKey: key)
            }
        case .exercises:
            defaults.removeObject(forKey: RecommendedExercises.amountKey)
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

    private enum Reset {
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
                    .settingHelp(category.help)
                }
            } header: {
                Text("Categories")
            }

            Section {
                Button(role: .destructive) {
                    pending = .all
                } label: {
                    Label("Reset All Settings", systemImage: "arrow.counterclockwise")
                }
                .settingHelp(L("Puts every category above back at once. Your exercises, scores and routines are untouched."))
            }
        }
        .navigationTitle(L("Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .resetConfirmation($pending, confirmLabel: { _ in L("Reset") }) { reset in
            switch reset {
            case .one(let category):
                L("The settings under “%@” go back to how the app started out.", category.title)
            case .all:
                L("Every setting in the app goes back to how it started out.")
            }
        } perform: { reset in
            switch reset {
            case .one(let category): category.reset(store: store, templates: visualTemplates)
            case .all: ResettableSettings.allCases.forEach { $0.reset(store: store, templates: visualTemplates) }
            }
        }
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

    private enum Reset {
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
                .settingHelp(L("Deletes every exercise you created yourself, with its MIDI pattern and scores. Exercises that came with the app or from the Community tab are kept."))

                countedButton(L("Delete Downloaded Exercises"), systemImage: "person.3",
                              count: store.downloadedExerciseIDs.count) {
                    pending = .downloaded
                }
                .settingHelp(L("Deletes every exercise you downloaded from the Community tab, with its MIDI pattern and scores. Your own exercises and the ones that came with the app are kept."))
            } header: {
                Text("Your exercises")
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
                    }
                }

                Button(role: .destructive) {
                    pending = .allBundled
                } label: {
                    Label("Revert All Bundled Exercises", systemImage: "arrow.uturn.backward")
                }
                .disabled(changed.isEmpty)
                .settingHelp(L("Puts every exercise that came with the app back to how it shipped, bringing back any you deleted."))
            } header: {
                Text("Bundled Exercises")
            }
        }
        .navigationTitle(L("Exercises"))
        .navigationBarTitleDisplayMode(.inline)
        .resetConfirmation($pending, confirmLabel: { reset in
            switch reset {
            case .own, .downloaded: L("Delete")
            case .bundled, .allBundled: L("Revert")
            }
        }) { reset in
            switch reset {
            case .own:
                L("Every exercise you created yourself will be deleted, along with its MIDI pattern and scores.")
            case .downloaded:
                L("Every exercise you downloaded from the Community tab will be deleted, along with its MIDI pattern and scores.")
            case .bundled(_, let name):
                L("“%@” goes back to how it came with the app.", name)
            case .allBundled:
                L("Every exercise that came with the app goes back to how it shipped, and any you deleted come back.")
            }
        } perform: { reset in
            switch reset {
            case .own: store.deleteOwnExercises()
            case .downloaded: store.deleteDownloadedExercises()
            case .bundled(let id, _): store.revertBundled(id)
            case .allBundled: store.revertAllBundled()
            }
        }
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
        .disabled(count == 0)
    }
}

// MARK: - Home

/// Reset ▸ Home: clears the three lists the Home tab builds over the library.
/// None of them delete an exercise — only its membership in the list.
struct HomeResetView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    private enum Reset {
        case favourites
        case routines
        case history
    }

    @State private var pending: Reset?

    var body: some View {
        Form {
            Section {
                countedButton(L("Clear Favourites"), systemImage: "star",
                              count: store.favourites.count) {
                    pending = .favourites
                }
                .settingHelp(L("Empties the Home tab's “Favourites” list. The exercises in it are kept."))

                countedButton(L("Delete Routines"), systemImage: "list.number",
                              count: store.routines.count) {
                    pending = .routines
                }
                .settingHelp(L("Deletes every routine you assembled. The exercises they were made of are kept."))

                countedButton(L("Clear Recently Played"), systemImage: "clock.arrow.circlepath",
                              count: store.recentlyPlayed.count) {
                    pending = .history
                }
                .settingHelp(L("Forgets what you played and when, emptying the Home tab's “Recent” list and the order “Recommended” picks by."))
            }
        }
        .navigationTitle(L("Home"))
        .navigationBarTitleDisplayMode(.inline)
        .resetConfirmation($pending, confirmLabel: { _ in L("Delete") }) { reset in
            switch reset {
            case .favourites:
                L("The Home tab's “Favourites” list will be emptied. The exercises in it are kept.")
            case .routines:
                L("Every routine will be deleted. The exercises they were made of are kept.")
            case .history:
                L("Your play history will be forgotten, emptying the Home tab's “Recent” list.")
            }
        } perform: { reset in
            switch reset {
            case .favourites: store.clearFavourites()
            case .routines: store.clearRoutines()
            case .history: store.clearPlayHistory()
            }
        }
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
        .disabled(count == 0)
    }
}

// MARK: - Confirmation

private extension View {
    /// The confirmation every Reset action goes through: nothing is deleted until
    /// the user picks the destructive button here (dismissing the dialog any other
    /// way cancels). `pending` holds what was asked for and is cleared whichever
    /// way the dialog closes, so the same state drives both what is presented and
    /// whether it's up at all. `confirmLabel` takes the action because one screen's
    /// rows don't all do the same thing — reverting isn't deleting.
    func resetConfirmation<Action>(
        _ pending: Binding<Action?>,
        confirmLabel: @escaping (Action) -> String,
        message: @escaping (Action) -> String,
        perform: @escaping (Action) -> Void
    ) -> some View {
        confirmationDialog(
            Text(L("This can't be undone.")),
            isPresented: Binding(get: { pending.wrappedValue != nil },
                                 set: { if !$0 { pending.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { action in
            Button(confirmLabel(action), role: .destructive) {
                perform(action)
                pending.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { pending.wrappedValue = nil }
        } message: { action in
            Text(message(action))
        }
    }
}
