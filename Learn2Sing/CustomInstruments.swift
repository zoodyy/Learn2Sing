// User-uploaded playback instruments: a single recorded sound (MP3/WAV) that the
// player resamples up and down from its base pitch to cover every note.

import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Model & store

/// A user-uploaded playback sound. `baseFrequency` is the pitch of the recording
/// itself, so the player knows how far to shift it for each note.
struct CustomInstrument: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var fileName: String            // file inside the Instruments directory
    var baseFrequency: Double       // Hz of the recorded sound
}

/// Owns the user's custom instruments: the metadata list (UserDefaults) and the
/// audio files themselves (Documents/Instruments/).
final class CustomInstrumentStore: ObservableObject {
    static let shared = CustomInstrumentStore()

    @Published var instruments: [CustomInstrument] = []

    private let storeKey = "customInstruments"

    /// `selectedInstrument` values starting with this prefix select a custom
    /// instrument; the rest of the string is its UUID.
    static let selectionPrefix = "custom:"

    /// The `selectedInstrument` value that picks this custom instrument.
    static func selectionTag(_ id: UUID) -> String { selectionPrefix + id.uuidString }

    init() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let saved = try? JSONDecoder().decode([CustomInstrument].self, from: data)
        else { return }
        instruments = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(instruments) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Instruments", isDirectory: true)
    }

    func url(for instrument: CustomInstrument) -> URL {
        Self.directory.appendingPathComponent(instrument.fileName)
    }

    /// The custom instrument currently selected in Settings, if the selection is
    /// a custom one and it still exists.
    func selected() -> CustomInstrument? {
        guard let raw = UserDefaults.standard.string(forKey: Instrument.storageKey),
              raw.hasPrefix(Self.selectionPrefix),
              let id = UUID(uuidString: String(raw.dropFirst(Self.selectionPrefix.count)))
        else { return nil }
        return instruments.first { $0.id == id }
    }

    /// Copy a picked audio file into the app and register it as an instrument.
    /// The display name starts as the file's name; the pitch defaults to C4 (middle
    /// C) and should be corrected by the user to the recording's real pitch.
    @discardableResult
    func importFile(at url: URL) throws -> CustomInstrument {
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "audio" : url.pathExtension.lowercased()
        let fileName = "\(id.uuidString).\(ext)"
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: Self.directory.appendingPathComponent(fileName))
        let instrument = CustomInstrument(id: id,
                                          name: url.deletingPathExtension().lastPathComponent,
                                          fileName: fileName,
                                          baseFrequency: noteFrequency(60))   // C4
        instruments.append(instrument)
        save()
        return instrument
    }

    /// Remove an instrument and its audio file. If it was the selected playback
    /// instrument, the selection falls back to the default built-in.
    func delete(id: UUID) {
        guard let instrument = instruments.first(where: { $0.id == id }) else { return }
        instruments.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: url(for: instrument))
        save()
        if UserDefaults.standard.string(forKey: Instrument.storageKey) == Self.selectionTag(id) {
            UserDefaults.standard.set(Instrument.piano.rawValue, forKey: Instrument.storageKey)
        }
    }

    /// A safe two-way binding to a single instrument: edits write back (and
    /// persist) by id, so it never crashes if the instrument is deleted while a
    /// view holds it.
    func binding(for id: UUID) -> Binding<CustomInstrument> {
        Binding(
            get: {
                self.instruments.first(where: { $0.id == id })
                    ?? CustomInstrument(name: "", fileName: "", baseFrequency: noteFrequency(60))
            },
            set: { newValue in
                guard let idx = self.instruments.firstIndex(where: { $0.id == id }) else { return }
                self.instruments[idx] = newValue
                self.save()
            }
        )
    }
}

// MARK: - Pitch parsing & formatting

/// Frequency of a MIDI note number (A4 = 69 = 440 Hz).
func noteFrequency(_ midi: Double) -> Double {
    440.0 * pow(2.0, (midi - 69.0) / 12.0)
}

/// Parse the user's pitch input: either a note name ("C3", "f#2", "Eb3") or a
/// plain frequency in Hz ("130.81"). Returns nil when it's neither.
func parsePitchInput(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if let hz = Double(trimmed.replacingOccurrences(of: ",", with: ".")), hz > 0 {
        return hz
    }
    // Note name: letter, optional sharp/flat, octave (may be negative, e.g. A-1).
    let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    let chars = Array(trimmed.uppercased())
    guard let first = chars.first, var semitone = letters[first] else { return nil }
    var i = 1
    if i < chars.count, chars[i] == "#" || chars[i] == "♯" {
        semitone += 1; i += 1
    } else if i < chars.count, chars[i] == "B" || chars[i] == "♭", i + 1 < chars.count {
        semitone -= 1; i += 1
    }
    guard let octave = Int(String(chars[i...])) else { return nil }
    return noteFrequency(Double((octave + 1) * 12 + semitone))
}

/// A user-facing description of a frequency: its Hz value plus the nearest note
/// name, with the offset in cents when it isn't spot on — "130.8 Hz · C3".
func describePitch(_ hz: Double) -> String {
    guard hz > 0 else { return "" }
    let midi = 69.0 + 12.0 * log2(hz / 440.0)
    let nearest = min(127, max(0, Int(midi.rounded())))
    let cents = Int(((midi - Double(nearest)) * 100).rounded())
    let note = cents == 0 ? pitchName(nearest) : String(format: "%@ %+d¢", pitchName(nearest), cents)
    return String(format: "%.1f Hz · %@", hz, note)
}

/// The text to prefill the pitch field with: the plain note name when the stored
/// frequency sits exactly on a note, otherwise the Hz value.
func pitchInputText(_ hz: Double) -> String {
    guard hz > 0 else { return "" }
    let midi = 69.0 + 12.0 * log2(hz / 440.0)
    let nearest = midi.rounded()
    if abs(midi - nearest) < 0.005, (0...127).contains(Int(nearest)) {
        return pitchName(Int(nearest))
    }
    return String(format: "%.2f", hz)
}

// MARK: - Management screens

/// The "Instruments" screen inside the Audio settings: pick one of the built-in
/// playback sounds, or manage the uploaded ones — add via the file picker, swipe
/// to delete, tap a row to edit its name and pitch on the detail screen.
struct InstrumentsView: View {
    @ObservedObject private var store = CustomInstrumentStore.shared
    @AppStorage(Instrument.storageKey) private var instrumentRaw = Instrument.piano.rawValue

    /// Pushes the detail screen for a custom instrument onto the Settings stack.
    let onSelect: (UUID) -> Void

    @State private var isImporting = false
    @State private var alertMessage: String?

    var body: some View {
        Form {
            Section("Built-in") {
                ForEach(Instrument.allCases) { instrument in
                    Button {
                        instrumentRaw = instrument.rawValue
                    } label: {
                        HStack {
                            Text(instrument.rawValue)
                            Spacer()
                            if instrumentRaw == instrument.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section {
                ForEach(store.instruments) { instrument in
                    Button {
                        onSelect(instrument.id)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(instrument.name)
                                Text(describePitch(instrument.baseFrequency))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if instrumentRaw == CustomInstrumentStore.selectionTag(instrument.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    for offset in offsets {
                        store.delete(id: store.instruments[offset].id)
                    }
                }
            } header: {
                Text("Custom")
            } footer: {
                Text("Upload an MP3 or WAV file containing a single sound. Playback shifts it up and down from its pitch to reach every note. After uploading, set the pitch the recording actually has.")
            }
        }
        .navigationTitle("Instruments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.mp3, .wav]
        ) { result in
            switch result {
            case .success(let url):
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let instrument = try store.importFile(at: url)
                    onSelect(instrument.id)   // straight to naming & pitch
                } catch {
                    alertMessage = "That file could not be imported: \(error.localizedDescription)"
                }
            case .failure(let error):
                alertMessage = "Import failed: \(error.localizedDescription)"
            }
        }
        .alert("Instruments", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }
}

/// Edit screen for one uploaded instrument: display name, the recording's pitch
/// (note name or Hz), selecting it for playback, and deleting it.
struct CustomInstrumentDetailView: View {
    @Binding var instrument: CustomInstrument
    @ObservedObject private var store = CustomInstrumentStore.shared
    @AppStorage(Instrument.storageKey) private var instrumentRaw = Instrument.piano.rawValue
    @Environment(\.dismiss) private var dismiss

    @State private var pitchText = ""
    @State private var isConfirmingDelete = false

    private var isSelected: Bool {
        instrumentRaw == CustomInstrumentStore.selectionTag(instrument.id)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $instrument.name)
            }

            Section {
                TextField("e.g. C3 or 130.81", text: $pitchText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: pitchText) { _, newValue in
                        if let hz = parsePitchInput(newValue) {
                            instrument.baseFrequency = hz
                        }
                    }
                HStack {
                    Text("Interpreted as")
                    Spacer()
                    if let hz = parsePitchInput(pitchText) {
                        Text(describePitch(hz)).foregroundStyle(.secondary)
                    } else {
                        Text("Not recognized").foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Pitch of the Recording")
            } footer: {
                Text("The note (e.g. C3) or frequency in Hz (e.g. 130.81) of the recorded sound. Playback shifts the recording up or down from here to reach each note.")
            }

            Section {
                Button {
                    instrumentRaw = CustomInstrumentStore.selectionTag(instrument.id)
                } label: {
                    HStack {
                        Text("Use for Playback")
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(isSelected)
            }

            Section {
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Delete Instrument", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(instrument.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pitchText = pitchInputText(instrument.baseFrequency) }
        .alert("Delete Instrument?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                let id = instrument.id
                dismiss()
                // Delete after the pop so no view is bound to the removed instrument.
                DispatchQueue.main.async { store.delete(id: id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(instrument.name)\" and its audio file will be deleted. This cannot be undone.")
        }
    }
}
