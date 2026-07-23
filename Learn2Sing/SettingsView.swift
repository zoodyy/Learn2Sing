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
    @State private var settingsPath = NavigationPath()

    /// The exercise driving the microphone-delay test. Built once so the intro and
    /// playback screens share the same instance; it isn't stored in the library.
    private let delayTestExercise = SettingsView.makeDelayTestExercise()

    var body: some View {
        NavigationStack(path: $settingsPath) {
            Form {
                Section {
                    hubLink("Profile", systemImage: "person.crop.circle", route: .profile)

                    hubLink("Audio", systemImage: "speaker.wave.2", route: .audio)
                        .settingHelp("Instruments, playback and recording devices, and the microphone delay used for scoring.")

                    hubLink("Visuals", systemImage: "paintpalette", route: .visualsHub)
                        .settingHelp("Theme, orientation and the look of the playback screen.")

                    hubLink("Voice", systemImage: "music.mic", route: .voice)
                        .settingHelp("Your vocal range and the test that measures it.")

                    hubLink("Backup", systemImage: "externaldrive", route: .backup)
                        .settingHelp("Export your exercise library to a file, or import one.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .stableTopEdgeFade()
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .audio:
                    AudioSettingsView(
                        openInstruments: { settingsPath.append(SettingsRoute.instruments) },
                        openDelayTest: { settingsPath.append(SettingsRoute.delayIntro) })
                case .instruments:
                    InstrumentsView { settingsPath.append(SettingsRoute.customInstrument($0)) }
                case .customInstrument(let id):
                    CustomInstrumentDetailView(instrument: CustomInstrumentStore.shared.binding(for: id))
                case .delayIntro:
                    ExerciseIntroView(exercise: delayTestExercise) {
                        settingsPath.append(SettingsRoute.delayPlayback)
                    }
                case .delayPlayback:
                    PlaybackView(exercise: delayTestExercise, mode: .delayTest)
                case .voice:
                    VoiceSettingsView { settingsPath.append(SettingsRoute.vocalRangeTest) }
                case .vocalRangeTest:
                    VocalRangeTestView { settingsPath = NavigationPath() }
                case .visualsHub:
                    VisualsHubView { settingsPath.append(SettingsRoute.visualsPlayback) }
                case .visualsPlayback:
                    PlaybackVisualsView()
                case .profile:
                    ProfileView()
                case .backup:
                    BackupSettingsView()
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

    /// A row that pushes a settings category screen onto the navigation stack.
    private func hubLink(_ title: String, systemImage: String, route: SettingsRoute) -> some View {
        Button {
            settingsPath.append(route)
        } label: {
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

    /// Screens pushed onto the Settings navigation stack: the category hubs
    /// (Audio with its instruments screens, Visuals, Voice, Backup, Profile) and
    /// the microphone-delay and vocal-range tests they lead to.
    private enum SettingsRoute: Hashable {
        case audio
        case instruments
        case customInstrument(UUID)
        case delayIntro
        case delayPlayback
        case voice
        case vocalRangeTest
        case visualsHub
        case visualsPlayback
        case profile
        case backup
    }

    /// The throwaway exercise that drives the delay test, with the description shown
    /// on its intro screen. Its notes are generated in PlaybackView's delay-test
    /// mode rather than loaded from storage, so it never enters the user's library.
    private static func makeDelayTestExercise() -> Exercise {
        var exercise = Exercise(name: "Microphone Delay Test")
        exercise.bpm = 80
        exercise.details = """
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
        """
        return exercise
    }
}

/// The "Voice" hub reached from Settings: the user's vocal range and the test
/// that measures it. A screen of its own so further voice areas can be added.
struct VoiceSettingsView: View {
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
                        Text(range.rawValue).tag(range.rawValue)
                    }
                }
                .settingHelp("Choose your voice type, or pick “Custom” to enter your own lowest and highest notes. The test below can fill this in for you.")

                if isCustom {
                    Picker("Lowest note", selection: $customLow) {
                        ForEach(loPitch...hiPitch, id: \.self) { pitch in
                            Text(pitchName(pitch)).tag(pitch)
                        }
                    }
                    .onChange(of: customLow) { _, newLow in
                        if newLow > customHigh { customHigh = newLow }
                    }

                    Picker("Highest note", selection: $customHigh) {
                        ForEach(loPitch...hiPitch, id: \.self) { pitch in
                            Text(pitchName(pitch)).tag(pitch)
                        }
                    }
                    .onChange(of: customHigh) { _, newHigh in
                        if newHigh < customLow { customLow = newHigh }
                    }
                    .settingHelp("The lowest and highest notes you can comfortably sing. Exercises are transposed to fit between them.")
                }

                Button(action: openRangeTest) {
                    Label("Test Vocal Range", systemImage: "waveform")
                }
                .settingHelp("Sing your lowest and highest notes and the app sets them as your custom vocal range above.")
            } header: {
                Text("Vocal Range")
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The "Backup" hub reached from Settings: exporting the exercise library to a
/// file and importing one back in.
struct BackupSettingsView: View {
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
                        alertMessage = "Could not prepare the export file."
                    }
                } label: {
                    Label("Export Exercises", systemImage: "square.and.arrow.up")
                }
                .settingHelp("Export saves every exercise and its settings to a file. Import merges exercises from a file into your library.")

                Button {
                    isImporting = true
                } label: {
                    Label("Import Exercises", systemImage: "square.and.arrow.down")
                }
                .settingHelp("Export saves every exercise and its settings to a file. Import merges exercises from a file into your library.")
            } header: {
                Text("Exercises")
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Learn2Sing Exercises"
        ) { result in
            if case .failure(let error) = result {
                alertMessage = "Export failed: \(error.localizedDescription)"
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
                    alertMessage = "That file could not be imported."
                    return
                }
            case .failure(let error):
                alertMessage = "Import failed: \(error.localizedDescription)"
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
