// Shared MIDI pitch constants and helpers used by EditingView and PlaybackView.

import Foundation

let hiPitch  = 83   // B5
let loPitch  = 24   // C1

private let _noteLabels = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

func pitchName(_ pitch: Int) -> String {
    "\(_noteLabels[pitch % 12])\((pitch / 12) - 1)"
}

/// Bit set of the black keys within an octave: C#, D#, F#, G#, A#.
private let _blackKeyMask = (1 << 1) | (1 << 3) | (1 << 6) | (1 << 8) | (1 << 10)

func isBlack(_ pitch: Int) -> Bool {
    // A literal array + `contains` allocates on every call, and the playback canvas
    // asks this for every visible row twice a frame — so it's a bit test instead.
    _blackKeyMask & (1 << (((pitch % 12) + 12) % 12)) != 0
}

// MARK: - Scoring

/// UserDefaults key for the microphone-delay compensation (in milliseconds). It
/// only shifts how the score is computed — playback and visuals are untouched.
let microphoneDelayKey = "microphoneDelayMs"

/// The microphone-delay setting expressed in beats at `bpm`. Scoring treats every
/// note as sounding this much later than it is drawn, which is the same comparison
/// as treating the detected pitch as having happened this much *earlier* — which is
/// how the review screen lines the sung line up with the notes.
func micDelayBeats(_ ms: Double, bpm: Double) -> Double { ms / 1000.0 * bpm / 60.0 }

/// How long the voice needs to travel from one pitch to another, and what the score
/// therefore lets a note off.
///
/// A pitch change is not instant. The larynx accelerates, glides, and settles again,
/// and all of that happens while the note being moved *to* is already sounding — so
/// the singer is off it at its start however well they sing. Scoring every note over
/// its full length charged that travel to the singer, which cost the most on exactly
/// the exercises that ask for the most: many onsets, far apart (see
/// `SkillLevel.ceilingScore`). So the note being arrived at asks for that much less.
///
/// The numbers are the mean of 33 subjects shifting pitch as fast as they could, over
/// the *complete* movement rather than the fast middle of it: 89.6 ms + 8.7 ms per
/// semitone rising, 100.4 + 5.8 falling (Xu & Sun, "Maximum speed of pitch change and
/// how it may relate to speech", JASA 111(3), 2002, Table V). The rising figures are
/// used both ways: Sundberg (1979) found that untrained voices drop faster than they
/// rise but trained ones do not, and the two formulas are within 8 ms of each other
/// anywhere it matters.
///
/// Note how flat that is — a semitone costs 98 ms and an octave 194, because nearly
/// all of it is the fixed price of starting and stopping a move rather than the
/// distance covered. It is also measured at maximum effort, which is the point: it is
/// meant to be the most a good singer could possibly need, so that what is left of a
/// note is time they really were expected to be on pitch.
enum PitchTravel {
    /// The fixed part: what it costs to get the voice moving and settled again,
    /// whatever the interval.
    static let onsetSeconds = 0.0896

    /// The part that grows with the distance travelled.
    static let perSemitoneSeconds = 0.0087

    /// How long a move of `semitones` takes, in seconds, up or down alike. Zero for
    /// no move at all.
    static func seconds(semitones: Int) -> Double {
        guard semitones != 0 else { return 0 }
        return onsetSeconds + perSemitoneSeconds * Double(abs(semitones))
    }

    /// How much of each note has to be sung on pitch for it to count as fully hit,
    /// in beats, in the order the notes are given.
    ///
    /// That is the note's own length, less the travel from the note before it — the
    /// pitch the voice is coming from. A note the voice was already at (a repeated
    /// pitch) is free, and so is a note the exercise leaves silence in front of,
    /// because the voice can do its travelling in the rest: only what the rest does
    /// not already cover comes off the note.
    ///
    /// A note can end up asking for nothing, when it is shorter than the travel it is
    /// reached by. There is no way to be on such a note for as long as it lasts, so
    /// the scorer treats it as all or nothing instead (see `Scorer.score`).
    static func requiredBeats(notes: [MIDINote], bpm: Double) -> [Double] {
        var required = notes.map { max(0, $0.length) }
        guard bpm > 0, notes.count > 1 else { return required }
        let secPerBeat = 60.0 / bpm

        // Written for one voice at a time: the note before this one is the last one to
        // have started before it. Notes sharing a start beat are nobody's predecessor,
        // so the walk steps back over them rather than reading one as the note sung
        // before the other.
        let order = notes.indices.sorted { notes[$0].beat < notes[$1].beat }
        for k in 1..<order.count {
            let i = order[k]
            let note = notes[i]
            var p = k - 1
            while p >= 0, notes[order[p]].beat >= note.beat { p -= 1 }
            guard p >= 0 else { continue }
            let from = notes[order[p]]

            let semitones = abs(note.pitch - from.pitch)
            guard semitones > 0 else { continue }
            let rest = max(0, note.beat - (from.beat + from.length)) * secPerBeat
            let travel = max(0, PitchTravel.seconds(semitones: semitones) - rest)
            required[i] = max(0, required[i] - travel / secPerBeat)
        }
        return required
    }
}

/// How much of a note has to be hit for it to count towards the score, as a
/// percentage of the note's drawn height. At 100 the whole note counts and a run
/// is scored exactly as it was before this setting existed; lower, and only that
/// share of the note's middle does, so the singer has to sit nearer the centre of
/// the pitch. Set in Settings ▸ Voice ▸ Score Calculation.
enum ScoreTargetWindow {
    static let storageKey = "scoreTargetWindowPercent"

    /// The whole note, so an install that never touches this scores as it always did.
    static let defaultPercent = 100

    /// Narrower than 5% the window is thinner than the pitch line drawn over it,
    /// which leaves nothing to aim at; 100 is the whole note.
    static let range = 5...100

    /// A percentage brought inside the range the slider offers, so a value restored
    /// from a profile written by a later version can't widen the window past the note,
    /// close it altogether, or show up on the settings screen as a number the slider
    /// has no room for.
    static func clamped(_ percent: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, percent))
    }

    /// The share of the note's height that counts, 0.05...1.
    static func fraction(percent: Int) -> Double {
        Double(clamped(percent)) / 100
    }

    /// The setting as it currently stands, for the places that read it once rather
    /// than binding to it.
    static var percent: Int {
        UserDefaults.standard.object(forKey: storageKey) as? Int ?? defaultPercent
    }
}

/// The microphone delay worked out from the singing itself, rather than measured by
/// one of the tests and typed in.
///
/// The delay is what lines a singer's voice up with the notes when the score is
/// worked out, and a new singer has no reason to go looking for it in Settings — so
/// with this on (which is how the app ships) every run that plays through to the end
/// is re-scored at every delay it could have been sung at, and the one that scores
/// highest becomes the setting. The score the singer is then shown is the one at that
/// delay, so the number on the screen is the best the run was worth. While it is on,
/// the delay field is read-only and the tests are put away: there is nothing left for
/// them to do.
enum AutoMicDelay {
    /// UserDefaults key for the switch in Settings ▸ Audio ▸ Scoring.
    static let enabledKey = "automaticMicrophoneDelay"

    /// On, so a singer who never opens Settings still gets scored against their own
    /// microphone rather than against a delay of zero.
    static let defaultEnabled = true

    /// The score a recognised delay has to beat before it replaces the one already
    /// set. Below it the run says more about the singing than about the microphone:
    /// a line that lies over the notes nowhere has a "best" offset, but it is noise,
    /// and adopting it would move a delay that a better run had got right.
    static let minimumScore = 40

    /// UserDefaults key recording that a run has scored above that with this on, so
    /// there is a delay worth protecting. Until then every run's best offset is
    /// adopted however low it scores: a singer whose microphone lags by half a second
    /// cannot score above the bar until the delay is roughly right, so holding out for
    /// the score first would leave them stuck at zero forever.
    ///
    /// Kept out of `UserSettings` for the same reason the tutorial's flag is: it
    /// records what has happened on this install rather than something the singer
    /// chose. A restored profile brings a delay measured on another device's
    /// microphone, which this device's first run should be free to correct.
    static let establishedKey = "automaticMicrophoneDelayEstablished"

    /// The setting as it currently stands, for the places that read it once rather
    /// than binding to it.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static var isEstablished: Bool {
        UserDefaults.standard.bool(forKey: establishedKey)
    }

    static func markEstablished() {
        UserDefaults.standard.set(true, forKey: establishedKey)
    }

    /// The largest delay any of this is allowed to arrive at, in milliseconds. Far
    /// past any real microphone's round trip, and the same ceiling the sung test's
    /// offset controls stop at.
    static let ceilingMs: Double = 2000

    /// The highest delay worth trying on this run, in milliseconds.
    ///
    /// A delay shifts the notes later for scoring, so a big enough one slides the last
    /// note clean past the end of the singing: nothing was sung while it sounds, it can
    /// never be hit, and the notes before it are all that is left to score. That is not
    /// a delay the run measured, it is the run being cut short, so the search stops at
    /// the largest offset that still leaves the last note sounding over something the
    /// singer sang.
    ///
    /// `samples` is the run's pitch line, oldest first; a sample with no pitch is
    /// silence rather than singing and doesn't hold the last note up.
    static func maxDelayMs(notes: [MIDINote], samples: [PitchSample], bpm: Double) -> Double {
        guard bpm > 0,
              let lastNote = notes.max(by: { ($0.beat, $0.length) < ($1.beat, $1.length) }),
              let lastSung = samples.last(where: { $0.pitch != nil })?.beat
        else { return 0 }
        // In beats the note may be shifted by, then back into milliseconds: the
        // shift that puts the note's start exactly on the final sung sample.
        let beats = lastSung - lastNote.beat
        return min(ceilingMs, max(0, beats * 60_000 / bpm))
    }
}

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
