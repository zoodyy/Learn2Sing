//
//  SettingsView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(Instrument.storageKey) private var instrumentRaw = Instrument.piano.rawValue
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
