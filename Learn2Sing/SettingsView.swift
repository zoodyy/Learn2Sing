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
    @AppStorage(Instrument.storageKey) private var instrumentRaw = Instrument.piano.rawValue
    @AppStorage(AudioRouteManager.speakerKey) private var speaker = AudioRouteManager.automatic
    @AppStorage(AudioRouteManager.micKey) private var microphone = AudioRouteManager.builtInMic
    @AppStorage(microphoneDelayKey) private var micDelayMs = 0.0
    @AppStorage(VocalRange.storageKey) private var vocalRangeRaw = ""
    @FocusState private var micDelayFocused: Bool
    @ObservedObject private var routes = AudioRouteManager.shared
    @EnvironmentObject private var store: ExerciseStore

    @State private var exportDocument: ExerciseDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var alertMessage: String?
    @State private var settingsPath = NavigationPath()

    /// The exercise driving the microphone-delay test. Built once so the intro and
    /// playback screens share the same instance; it isn't stored in the library.
    private let delayTestExercise = SettingsView.makeDelayTestExercise()

    var body: some View {
        NavigationStack(path: $settingsPath) {
            Form {
                Section("Playback") {
                    Picker("Instrument", selection: $instrumentRaw) {
                        ForEach(Instrument.allCases) { instrument in
                            Text(instrument.rawValue).tag(instrument.rawValue)
                        }
                    }
                }

                Section {
                    Button {
                        settingsPath.append(SettingsRoute.visualsHub)
                    } label: {
                        HStack {
                            Label("Visuals", systemImage: "paintpalette")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Picker("Vocal range", selection: $vocalRangeRaw) {
                        Text("Not set").tag("")
                        ForEach(VocalRange.allCases) { range in
                            Text(range.rawValue).tag(range.rawValue)
                        }
                    }

                    Button {
                        settingsPath.append(SettingsRoute.vocalRangeTest)
                    } label: {
                        Label("Test Vocal Range", systemImage: "waveform")
                    }
                } header: {
                    Text("Vocal Range")
                } footer: {
                    Text("Sing your lowest and highest notes and the app estimates your voice type, then sets it above.")
                }

                Section {
                    Picker("Speaker", selection: $speaker) {
                        ForEach(options(routes.outputOptions, including: speaker), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Picker("Microphone", selection: $microphone) {
                        ForEach(options(routes.inputOptions, including: microphone), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                } header: {
                    Text("Audio Devices")
                } footer: {
                    Text("“Automatic” uses connected earphones (e.g. AirPods) when available, otherwise the phone.")
                }

                Section {
                    HStack {
                        Text("Microphone delay")
                        Spacer()
                        TextField("0", value: $micDelayMs, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .focused($micDelayFocused)
                            .frame(width: 70)
                        Text("ms").foregroundStyle(.secondary)
                    }

                    Button {
                        settingsPath.append(SettingsRoute.delayIntro)
                    } label: {
                        Label("Test for delay", systemImage: "metronome")
                    }
                } header: {
                    Text("Scoring")
                } footer: {
                    Text("Compensates for the lag between singing and pitch detection. Only the score is affected — playback and visuals are unchanged. Run the test to measure it automatically.")
                }

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

                    Button {
                        isImporting = true
                    } label: {
                        Label("Import Exercises", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("Exercises")
                } footer: {
                    Text("Export saves every exercise and its settings to a file. Import merges exercises from a file into your library.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .delayIntro:
                    ExerciseIntroView(exercise: delayTestExercise) {
                        settingsPath.append(SettingsRoute.delayPlayback)
                    }
                case .delayPlayback:
                    PlaybackView(exercise: delayTestExercise, mode: .delayTest)
                case .vocalRangeTest:
                    VocalRangeTestView { settingsPath = NavigationPath() }
                case .visualsHub:
                    VisualsHubView { settingsPath.append(SettingsRoute.visualsPlayback) }
                case .visualsPlayback:
                    PlaybackVisualsView()
                }
            }
            // The decimal pad has no return key. A keyboard toolbar (`.toolbar(.keyboard)`)
            // doesn't attach reliably inside a TabView, so instead show a Done bar pinned
            // above the keyboard while editing, and also let a scroll dismiss it.
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if micDelayFocused {
                    HStack {
                        Spacer()
                        Button("Done") { micDelayFocused = false }
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .onAppear { routes.refreshOptions() }
            // Select the whole number when the delay field is tapped, so typing a new
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

    /// The device list to show in a picker, guaranteeing the current selection is
    /// present even when that device is no longer connected (so it doesn't vanish).
    private func options(_ list: [String], including selection: String) -> [String] {
        list.contains(selection) ? list : list + [selection]
    }

    /// Screens pushed onto the Settings navigation stack: the microphone-delay
    /// test's intro/description screen and its clap-along playback, plus the
    /// vocal-range test.
    private enum SettingsRoute: Hashable {
        case delayIntro
        case delayPlayback
        case vocalRangeTest
        case visualsHub
        case visualsPlayback
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
