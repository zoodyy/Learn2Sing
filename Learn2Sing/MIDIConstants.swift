// Shared MIDI pitch constants and helpers used by EditingView and PlaybackView.

import Foundation

let hiPitch  = 83   // B5
let loPitch  = 24   // C1

private let _noteLabels = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

func pitchName(_ pitch: Int) -> String {
    "\(_noteLabels[pitch % 12])\((pitch / 12) - 1)"
}

func isBlack(_ pitch: Int) -> Bool {
    [1, 3, 6, 8, 10].contains(pitch % 12)
}

// MARK: - Scoring

/// UserDefaults key for the microphone-delay compensation (in milliseconds). It
/// only shifts how the score is computed — playback and visuals are untouched.
let microphoneDelayKey = "microphoneDelayMs"

// MARK: - Instrument selection

enum Instrument: String, CaseIterable, Identifiable {
    case piano  = "Piano"
    case sine   = "Sin Wave"
    case guitar = "Guitar"
    case voice  = "Voice"

    var id: String { rawValue }

    static let storageKey = "selectedInstrument"

    /// The instrument currently chosen in Settings (defaults to piano).
    static var current: Instrument {
        Instrument(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "")
            ?? .piano
    }
}
