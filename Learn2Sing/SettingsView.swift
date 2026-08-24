//
//  SettingsView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    @State private var settingsPath = NavigationPath()

    /// The exercise driving the clap delay test. Built once so the intro and
    /// playback screens share the same instance; it isn't stored in the library.
    private let delayTestExercise = SettingsView.makeDelayTestExercise()

    var body: some View {
        NavigationStack(path: $settingsPath) {
            Form {
                Section {
                    hubLink(L("Profile"), systemImage: "person.crop.circle", route: .profile)

                    hubLink(L("Audio"), systemImage: "speaker.wave.2", route: .audio)
                        .settingHelp(L("Instruments, playback and recording devices, and the microphone delay used for scoring."))

                    hubLink(L("Visuals"), systemImage: "paintpalette", route: .visualsHub)
                        .settingHelp(L("Theme, orientation and the look of the playback screen."))

                    hubLink(L("Voice"), systemImage: "music.mic", route: .voice)
                        .settingHelp(L("Your vocal range and the test that measures it."))

                    hubLink(L("Exercises"), systemImage: "list.bullet", route: .exercises)
                        .settingHelp(L("How your exercise library is presented, including the Home tab's recommendations."))

                    hubLink(L("Backup"), systemImage: "externaldrive", route: .backup)
                        .settingHelp(L("Export your exercise library to a file, or import one."))

                    hubLink(L("Reset"), systemImage: "arrow.counterclockwise", route: .reset)
                        .settingHelp(L("Delete your scores, exercises and Home tab lists, or put your settings back to how the app started out."))

                    hubLink(L("Language"), systemImage: "globe", route: .language)
                        .settingHelp(L("The language the app is displayed in. Kept on this device only."))

                    hubLink(L("Request a new Feature/ Report a Bug"),
                            systemImage: "exclamationmark.bubble", route: .feedback)
                        .settingHelp(L("Write to the developer: report something that's broken, ask for a feature, or say what you make of the app."))
                }
            }
            .navigationTitle(L("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .stableTopEdgeFade()
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .audio:
                    AudioSettingsView(
                        openInstruments: { settingsPath.append(SettingsRoute.instruments) },
                        openDelayTest: { settingsPath.append(SettingsRoute.delayChoice) })
                case .instruments:
                    InstrumentsView { settingsPath.append(SettingsRoute.customInstrument($0)) }
                case .customInstrument(let id):
                    CustomInstrumentDetailView(instrument: CustomInstrumentStore.shared.binding(for: id))
                case .delayChoice:
                    DelayTestChoiceView(
                        openClapTest: { settingsPath.append(SettingsRoute.delayIntro) },
                        openSungTest: { settingsPath.append(SettingsRoute.delayExercisePicker) })
                case .delayIntro:
                    ExerciseIntroView(exercise: delayTestExercise) {
                        settingsPath.append(SettingsRoute.delayPlayback)
                    }
                case .delayPlayback:
                    PlaybackView(exercise: delayTestExercise, mode: .clapDelayTest)
                case .delayExercisePicker:
                    DelayTestExercisePickerView {
                        settingsPath.append(SettingsRoute.delayExercisePlayback($0))
                    }
                case .delayExercisePlayback(let id):
                    // The exercise is looked up on the way in rather than carried in
                    // the route, so the run always plays what the library holds now.
                    if let exercise = store.exercises.first(where: { $0.id == id }) {
                        PlaybackView(exercise: exercise, mode: .sungDelayTest,
                                     onDelayTestExit: returnToAudioSettings)
                    }
                case .voice:
                    VoiceSettingsView { settingsPath.append(SettingsRoute.vocalRangeTest) }
                case .vocalRangeTest:
                    VocalRangeTestView { settingsPath = NavigationPath() }
                case .visualsHub:
                    VisualsHubView(
                        openMenus: { settingsPath.append(SettingsRoute.visualsMenus) },
                        openPlayback: { settingsPath.append(SettingsRoute.visualsPlayback) })
                case .visualsMenus:
                    MenusVisualsView()
                case .visualsPlayback:
                    PlaybackVisualsView()
                case .profile:
                    ProfileView()
                case .exercises:
                    ExercisesSettingsView {
                        settingsPath.append(SettingsRoute.recommendationWhitelist)
                    }
                case .recommendationWhitelist:
                    RecommendationWhitelistView()
                case .backup:
                    BackupSettingsView()
                case .reset:
                    ResetSettingsView(
                        openScores: { settingsPath.append(SettingsRoute.resetScores) },
                        openSettings: { settingsPath.append(SettingsRoute.resetSettings) },
                        openExercises: { settingsPath.append(SettingsRoute.resetExercises) },
                        openHome: { settingsPath.append(SettingsRoute.resetHome) })
                case .resetScores:
                    ScoresResetView()
                case .resetSettings:
                    SettingsResetView()
                case .resetExercises:
                    ExercisesResetView()
                case .resetHome:
                    HomeResetView()
                case .language:
                    LanguageSettingsView()
                case .feedback:
                    FeedbackView()
                }
            }
            // Select the whole number when a numeric field anywhere on this stack is
            // tapped (e.g. the microphone delay on the Audio screen), so typing a new
            // value replaces the old one instead of inserting alongside it. Scoped to
            // numeric fields by keyboard type, matching the repetition fields.
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
    }

    /// Back to the Audio screen from the far end of the sung delay test, rather than
    /// to the exercise picker the test happens to have been reached through: the
    /// value it just measured is on that screen, in the microphone-delay field.
    /// Audio is the first thing pushed onto this stack — the test is only reachable
    /// from there — so everything after it goes.
    private func returnToAudioSettings() {
        guard settingsPath.count > 1 else { return }
        settingsPath.removeLast(settingsPath.count - 1)
    }

    /// A row that pushes a settings category screen onto the navigation stack.
    private func hubLink(_ title: String, systemImage: String, route: SettingsRoute) -> some View {
        SettingsHubRow(title: title, systemImage: systemImage) {
            settingsPath.append(route)
        }
    }

    /// Screens pushed onto the Settings navigation stack: the category hubs
    /// (Audio with its instruments screens, Visuals, Voice, Exercises, Backup,
    /// Reset with its four screens, Language, Profile, and the message form) and
    /// the microphone-delay and vocal-range tests they lead to. The delay test
    /// branches in two: the clap test's intro and playback, or the sung test's
    /// exercise picker and the run it starts.
    private enum SettingsRoute: Hashable {
        case audio
        case instruments
        case customInstrument(UUID)
        case delayChoice
        case delayIntro
        case delayPlayback
        case delayExercisePicker
        case delayExercisePlayback(UUID)
        case voice
        case vocalRangeTest
        case visualsHub
        case visualsMenus
        case visualsPlayback
        case profile
        case exercises
        case recommendationWhitelist
        case backup
        case reset
        case resetScores
        case resetSettings
        case resetExercises
        case resetHome
        case language
        case feedback
    }

    /// The throwaway exercise that drives the clap delay test, with the description
    /// shown on its intro screen. Its notes are generated in PlaybackView's clap-test
    /// mode rather than loaded from storage, so it never enters the user's library.
    private static func makeDelayTestExercise() -> Exercise {
        var exercise = Exercise(name: L("Microphone Delay Test"))
        exercise.bpm = 80
        exercise.details = L("""
        This test measures how long it takes your microphone to pick up sound, so \
        the app can line your singing up with the notes when scoring.

        A steady metronome will tick along with short markers labelled “clap”. \
        Clap your hands once on every tick. The first four ticks are just to help \
        you settle into the beat and aren't counted — keep clapping through the \
        rest, sixteen in all.

        When it finishes, the delay between your claps and the ticks is measured \
        and your microphone delay setting is updated automatically.

        For the most accurate result, use headphones so the metronome isn't picked \
        up by the microphone, and clap firmly.
        """)
        return exercise
    }
}

/// A row that pushes another settings screen onto the navigation stack: a label
/// on the leading edge and a chevron on the trailing one. Shared by the Settings
/// hub and the Reset screens so they look identical. The title arrives already
/// translated (via `L(_:)`), since a `Label` built from a plain `String` is shown
/// verbatim.
struct SettingsHubRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
    }
}

/// The "Voice" hub reached from Settings: the user's vocal range and the test
/// that measures it. A screen of its own so further voice areas can be added.
struct VoiceSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""
    @AppStorage(VocalRange.customLowKey)  private var customLow  = VocalRange.customDefault.low
    @AppStorage(VocalRange.customHighKey) private var customHigh = VocalRange.customDefault.high

    /// Push the vocal-range test onto the shared Settings navigation stack.
    let openRangeTest: () -> Void

    private var isCustom: Bool { vocalRangeRaw == VocalRange.custom.rawValue }

    var body: some View {
        Form {
            Section {
                Picker("Vocal range", selection: $vocalRangeRaw) {
                    Text("Not set").tag("")
                    ForEach(VocalRange.allCases) { range in
                        Text(L(range.rawValue)).tag(range.rawValue)
                    }
                }
                .settingHelp(L("Choose your voice type, or pick “Custom” to enter your own lowest and highest notes. The test below can fill this in for you."))

                if isCustom {
                    Picker("Lowest note", selection: $customLow) {
                        ForEach(loPitch...hiPitch, id: \.self) { pitch in
                            Text(verbatim: pitchName(pitch)).tag(pitch)
                        }
                    }
                    .onChange(of: customLow) { _, newLow in
                        if newLow > customHigh { customHigh = newLow }
                    }

                    Picker("Highest note", selection: $customHigh) {
                        ForEach(loPitch...hiPitch, id: \.self) { pitch in
                            Text(verbatim: pitchName(pitch)).tag(pitch)
                        }
                    }
                    .onChange(of: customHigh) { _, newHigh in
                        if newHigh < customLow { customLow = newHigh }
                    }
                    .settingHelp(L("The lowest and highest notes you can comfortably sing. Exercises are transposed to fit between them."))
                }

                Button(action: openRangeTest) {
                    Label("Test Vocal Range", systemImage: "waveform")
                }
                .settingHelp(L("Sing your lowest and highest notes and the app sets them as your custom vocal range above."))
            } header: {
                Text("Vocal Range")
            }
        }
        .navigationTitle(L("Voice"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The "Exercises" hub reached from Settings: how the exercise library is
/// presented — the shape and size of the Home tab's "Recommended" category and
/// which exercises it may draw from.
struct ExercisesSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @AppStorage(RecommendedExercises.amountKey)
    private var recommendedAmount = RecommendedExercises.defaultAmount
    @AppStorage(RecommendedExercises.asListKey)
    private var recommendationsAsList = RecommendedExercises.defaultAsList

    /// Push the whitelist picker onto the shared Settings navigation stack.
    let openWhitelist: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Show recommendations as list", isOn: $recommendationsAsList)
                    .settingHelp(L("Lists the recommended exercises in the Home tab's “Recommended” category, one row each. Off, the category shows a single card instead, which plays them all as one queue."))

                Stepper(value: $recommendedAmount, in: RecommendedExercises.amountRange) {
                    HStack {
                        Text("Recommended exercises amount")
                        Spacer()
                        Text(verbatim: "\(recommendedAmount)").foregroundStyle(.secondary)
                    }
                }
                .settingHelp(L("How many exercises the Home tab's “Recommended” category suggests. It picks the whitelisted exercises you haven't practised in the longest."))

                Button(action: openWhitelist) {
                    HStack {
                        Text("Whitelisted exercises")
                        Spacer()
                        Text(verbatim: "\(store.recommendationWhitelist.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
                .settingHelp(L("The exercises recommendations are picked from. Everything that came with the app starts out selected; tap an exercise to add or remove it."))
            } header: {
                Text("Recommendations")
            }
        }
        .navigationTitle(L("Exercises"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The "Backup" hub reached from Settings: exporting the exercise library to a
/// file and importing one back in.
struct BackupSettingsView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    @State private var exportDocument: ExerciseDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var alertMessage: String?

    var body: some View {
        Form {
            Section {
                Button {
                    if let data = store.exportData() {
                        exportDocument = ExerciseDocument(data: data)
                        isExporting = true
                    } else {
                        alertMessage = L("Could not prepare the export file.")
                    }
                } label: {
                    Label("Export Exercises", systemImage: "square.and.arrow.up")
                }
                .settingHelp(L("Export saves every exercise and its settings to a file. Import merges exercises from a file into your library."))

                Button {
                    isImporting = true
                } label: {
                    Label("Import Exercises", systemImage: "square.and.arrow.down")
                }
                .settingHelp(L("Export saves every exercise and its settings to a file. Import merges exercises from a file into your library."))
            } header: {
                Text("Exercises")
            }
        }
        .navigationTitle(L("Backup"))
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: L("Learn2Sing Exercises")
        ) { result in
            if case .failure(let error) = result {
                alertMessage = L("Export failed: %@", error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url), store.importData(data) else {
                    alertMessage = L("That file could not be imported.")
                    return
                }
            case .failure(let error):
                alertMessage = L("Import failed: %@", error.localizedDescription)
            }
        }
        .alert("Exercises", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }
}

/// A plain-JSON document wrapper used by the export/import file dialogs.
struct ExerciseDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
