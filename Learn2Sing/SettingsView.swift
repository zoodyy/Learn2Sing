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
    @FocusState private var micDelayFocused: Bool
    @ObservedObject private var routes = AudioRouteManager.shared
    @EnvironmentObject private var store: ExerciseStore

    @State private var exportDocument: ExerciseDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Instrument", selection: $instrumentRaw) {
                        ForEach(Instrument.allCases) { instrument in
                            Text(instrument.rawValue).tag(instrument.rawValue)
                        }
                    }
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
                } header: {
                    Text("Scoring")
                } footer: {
                    Text("Compensates for the lag between singing and pitch detection. Only the score is affected — playback and visuals are unchanged.")
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
            .toolbar {
                // The decimal pad has no return key, so give it a Done button to
                // dismiss it. Ungated (this view has only one numeric field) so the
                // accessory is reliably installed when the keyboard first appears.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { micDelayFocused = false }
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
