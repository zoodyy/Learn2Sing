// The app types that ExerciseDifficulty.swift and ExerciseTimeline.swift are
// written against, cut down to what those two files touch, so both compile here
// unchanged, straight out of the app's sources (see seed_bundled.py).
//
// Copies, not the originals: the originals live in SwiftUI/UIKit files that
// don't build on macOS. Keep them in step with
//   Exercise, RepeatLayout, tempo/repeatLayout   Sources/Exercises/ExercisesView.swift
//   MIDINote, MIDIText, label geometry           Sources/Exercises/EditingView.swift
//   ExerciseBundle                               Sources/Exercises/ExerciseStore.swift
// A change to how a run is laid out that isn't copied here makes this tool rate
// a different run from the one the app plays.

import AppKit
import Foundation

enum ExerciseVisibility: String, Codable {
    case `private`, `public`
}

struct Exercise: Identifiable, Codable {
    var id = UUID()
    var name: String
    var details: String = ""
    var category: String = ""
    var pitchShift: Int = 0
    var bpm: Double = 120
    var repeatCount: Int = 1
    var transposePerRepeat: Int = 0
    var switchDirectionAfter: Int = 0
    var speedPerRepeat: Int = 0
    var beatsBetweenReps: Double = 0
    var visibility: ExerciseVisibility = .private
    var uploaderName: String = ""
    var downloadedFrom: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, name, details, category, pitchShift, bpm, speed, repeatCount, transposePerRepeat,
             switchDirectionAfter, speedPerRepeat, beatsBetweenReps, visibility, uploaderName,
             downloadedFrom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        pitchShift = try c.decodeIfPresent(Int.self, forKey: .pitchShift) ?? 0
        if let bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) {
            self.bpm = bpm
        } else if let speed = try c.decodeIfPresent(Double.self, forKey: .speed) {
            bpm = (120.0 * speed / 100.0).rounded()
        }
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        transposePerRepeat = try c.decodeIfPresent(Int.self, forKey: .transposePerRepeat) ?? 0
        switchDirectionAfter = try c.decodeIfPresent(Int.self, forKey: .switchDirectionAfter) ?? 0
        speedPerRepeat = try c.decodeIfPresent(Int.self, forKey: .speedPerRepeat) ?? 0
        beatsBetweenReps = try c.decodeIfPresent(Double.self, forKey: .beatsBetweenReps) ?? 0
        visibility = try c.decodeIfPresent(ExerciseVisibility.self, forKey: .visibility) ?? .private
        uploaderName = try c.decodeIfPresent(String.self, forKey: .uploaderName) ?? ""
        downloadedFrom = try c.decodeIfPresent(String.self, forKey: .downloadedFrom)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
    }
}

struct RepeatLayout {
    private(set) var span: Double
    private(set) var starts: [Double]
    private(set) var scales: [Double]

    init() {
        span = 0
        starts = []
        scales = []
    }

    init(span: Double, count: Int, scale: (Int) -> Double = { _ in 1 }) {
        self.span = span
        starts = []
        scales = []
        var start = 0.0
        for rep in 0..<max(0, count) {
            let s = scale(rep)
            starts.append(start)
            scales.append(s)
            start += span * s
        }
    }

    var count: Int { starts.count }
}

extension Exercise {
    static let repetitionTempoLimits = (min: 20.0, max: 400.0)

    func tempo(forRepetition rep: Int) -> Double {
        let raw = bpm + Double(rep) * Double(speedPerRepeat)
        return min(max(raw, Self.repetitionTempoLimits.min), Self.repetitionTempoLimits.max)
    }

    func repeatLayout(span: Double) -> RepeatLayout {
        RepeatLayout(span: span, count: max(1, repeatCount)) { rep in
            bpm > 0 ? bpm / tempo(forRepetition: rep) : 1
        }
    }
}

/// Only ever passed as nil here: the rating is taken at the written pitches.
struct VocalRange {
    func fitTranspose(low: Int, high: Int) -> Int { 0 }
}

struct MIDINote: Identifiable, Codable {
    var id = UUID()
    var pitch: Int
    var beat: Double
    var length: Double

    private enum CodingKeys: String, CodingKey { case id, pitch, beat, length }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pitch = try c.decode(Int.self, forKey: .pitch)
        beat = try c.decode(Double.self, forKey: .beat)
        length = try c.decode(Double.self, forKey: .length)
    }
}

struct MIDIText: Identifiable, Codable {
    var id = UUID()
    var text: String
    var pitch: Int
    var beat: Double
    var fontScale: Double = 1

    private enum CodingKeys: String, CodingKey { case id, text, pitch, beat }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        pitch = try c.decode(Int.self, forKey: .pitch)
        beat = try c.decode(Double.self, forKey: .beat)
    }
}

struct ExerciseBundle: Codable {
    var exercises: [Exercise]
    var categories: [String]? = nil
    var midi: [String: [MIDINote]]
    var texts: [String: [MIDIText]]? = nil
}

// MARK: - Label geometry

private let beatW: CGFloat = 52
private let textChipPadding: CGFloat = 5
let midiTextFontSize: CGFloat = 12

/// The app measures with UIFont's system font; AppKit's is the same face (SF Pro
/// Text at this size), so the widths agree to well under a point.
enum TextWidths {
    static func width(of text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: midiTextFontSize, weight: .semibold)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

func midiTextChipWidth(_ text: String) -> CGFloat {
    max(beatW * 0.5, TextWidths.width(of: text) + textChipPadding * 2)
}

func midiTextHalfWidth(_ text: String) -> Double {
    Double(midiTextChipWidth(text) / beatW) / 2
}

func midiTextReach(_ text: String) -> Double {
    Double((TextWidths.width(of: text) + textChipPadding * 2) / beatW) / 2
}

extension MIDIText {
    var centreBeat: Double {
        get { beat + midiTextHalfWidth(text) }
        set { beat = newValue - midiTextHalfWidth(text) }
    }
}
