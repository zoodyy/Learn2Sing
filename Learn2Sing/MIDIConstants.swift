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

// MARK: - Vocal range

/// The singer's voice type. The preset cases are standard voice categories; the
/// `.custom` case lets the singer enter their own lowest and highest notes, which
/// the "Test Vocal Range" feature in Settings also fills in from the notes it
/// measures. Stored as the raw string in UserDefaults (with the custom low/high
/// notes stored separately). When set, exercises are transposed to fit the
/// voice's range (see `fitTranspose`).
enum VocalRange: String, CaseIterable, Identifiable {
    case bass         = "Bass"
    case baritone     = "Baritone"
    case tenor        = "Tenor"
    case alto         = "Alto"
    case mezzoSoprano = "Mezzo"
    case soprano      = "Soprano"
    case custom       = "Custom"

    var id: String { rawValue }

    /// UserDefaults key holding the selected range's raw value ("" = not set).
    static let storageKey = "vocalRange"

    /// UserDefaults keys holding the custom range's lowest/highest MIDI notes,
    /// used only when `.custom` is selected.
    static let customLowKey  = "vocalRangeCustomLow"
    static let customHighKey = "vocalRangeCustomHigh"

    /// The custom range shown before the singer has chosen their own, and the
    /// fallback if the stored values are missing (a comfortable baritone span).
    static let customDefault = (low: 45, high: 69)   // A2–A4

    /// The singer's stored custom low/high MIDI notes, clamped so low ≤ high.
    static var customRange: (low: Int, high: Int) {
        let defaults = UserDefaults.standard
        let low  = defaults.object(forKey: customLowKey)  as? Int ?? customDefault.low
        let high = defaults.object(forKey: customHighKey) as? Int ?? customDefault.high
        return (min(low, high), max(low, high))
    }

    /// Typical comfortable range for the voice type, as MIDI note numbers. For
    /// `.custom` this is the singer's own stored range.
    var typicalRange: (low: Int, high: Int) {
        switch self {
        case .bass:         return (40, 64)   // E2–E4
        case .baritone:     return (45, 69)   // A2–A4
        case .tenor:        return (48, 72)   // C3–C5
        case .alto:         return (53, 77)   // F3–F5
        case .mezzoSoprano: return (57, 81)   // A3–A5
        case .soprano:      return (60, 84)   // C4–C6
        case .custom:       return VocalRange.customRange
        }
    }

    /// Semitones to transpose an exercise spanning `[low, high]` (MIDI) so it sits
    /// within this voice's comfortable range. The lowest note is never left below
    /// the voice's lowest note — a hard floor. If the exercise's top then pokes
    /// above the voice's highest note it's dropped back down to fit, but only as
    /// far as that floor allows. Returns 0 when the exercise already fits.
    func fitTranspose(low: Int, high: Int) -> Int {
        let bounds = typicalRange
        // 1. Lift the exercise so its lowest note isn't below the voice's floor.
        let up = max(0, bounds.low - low)
        let liftedLow = low + up
        let liftedHigh = high + up
        // 2. If the top now exceeds the voice's ceiling, drop it back down — but not
        //    so far that the lowest note would fall below the floor.
        let over = max(0, liftedHigh - bounds.high)
        let down = min(over, liftedLow - bounds.low)
        return up - down
    }
}

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
