import SwiftUI
import UIKit

// Customisable look of the note-scrolling playback screen. The settings are stored
// in UserDefaults and shared between the live PlaybackView and the preview in the
// Visuals → Playback settings screen, both of which render through
// `drawPlaybackScene` so the preview matches the real thing exactly.

// MARK: - Text font choices

/// Font family for the floating text labels on the playback screen.
enum PlaybackFont: String, CaseIterable, Identifiable {
    case system     = "System"
    case rounded    = "Rounded"
    case serif      = "Serif"
    case monospaced = "Monospaced"

    var id: String { rawValue }

    var design: Font.Design {
        switch self {
        case .system:     return .default
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }
}

// MARK: - Color <-> hex (so colours can live in UserDefaults / @AppStorage)

extension Color {
    /// Build a colour from a "#RRGGBB" (or "RRGGBBAA") hex string. Falls back to
    /// black for an unparseable string rather than failing.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// "#RRGGBB" representation, used to persist a colour picked from the wheel.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Stored keys & defaults

enum VisualKeys {
    static let noteColor        = "vis_noteColor"
    static let playingNoteColor = "vis_playingNoteColor"
    static let noteRoundness  = "vis_noteRoundness"
    static let verticalZoom   = "vis_verticalZoom"
    static let horizontalZoom = "vis_horizontalZoom"
    static let followVertical = "vis_followVertical"
    static let showLines      = "vis_showHorizontalLines"
    static let background     = "vis_backgroundColor"
    static let showKeyboard   = "vis_showKeyboard"
    static let showPitches    = "vis_showPitches"
    static let textColor      = "vis_textColor"
    static let textFont       = "vis_textFont"
}

/// Default values, used both for the @AppStorage controls and when resolving the
/// stored settings, so a never-touched setting reads the same in both places.
enum VisualDefaults {
    static let noteColor        = "#34C759"   // green, matching the original look
    static let playingNoteColor = "#FFFFFF"   // white, matching the original active-note look
    static let noteRoundness  = 0.2
    static let verticalZoom   = 1.0
    static let horizontalZoom = 1.0
    static let followVertical = false
    static let showLines      = true
    static let background     = "#0E0E14"
    static let showKeyboard   = true
    static let showPitches    = false
    static let textColor      = "#FF9500"   // orange, matching the original look
    static let textFont       = PlaybackFont.system.rawValue
}

// MARK: - Resolved settings

/// The visual settings as ready-to-use values (Colors, Bools, numbers), resolved
/// from the raw stored representation.
struct VisualSettings {
    var noteColor: Color
    var playingNoteColor: Color
    var noteRoundness: Double
    var verticalZoom: Double
    var horizontalZoom: Double
    var followNotesVertically: Bool
    var showHorizontalLines: Bool
    var backgroundColor: Color
    var showKeyboard: Bool
    var showPitches: Bool
    var textColor: Color
    var textFont: PlaybackFont

    /// The current settings read straight from UserDefaults (used by PlaybackView).
    static var current: VisualSettings {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        func str(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }
        return VisualSettings(
            noteColor: Color(hex: str(VisualKeys.noteColor, VisualDefaults.noteColor)),
            playingNoteColor: Color(hex: str(VisualKeys.playingNoteColor, VisualDefaults.playingNoteColor)),
            noteRoundness: dbl(VisualKeys.noteRoundness, VisualDefaults.noteRoundness),
            verticalZoom: dbl(VisualKeys.verticalZoom, VisualDefaults.verticalZoom),
            horizontalZoom: dbl(VisualKeys.horizontalZoom, VisualDefaults.horizontalZoom),
            followNotesVertically: bool(VisualKeys.followVertical, VisualDefaults.followVertical),
            showHorizontalLines: bool(VisualKeys.showLines, VisualDefaults.showLines),
            backgroundColor: Color(hex: str(VisualKeys.background, VisualDefaults.background)),
            showKeyboard: bool(VisualKeys.showKeyboard, VisualDefaults.showKeyboard),
            showPitches: bool(VisualKeys.showPitches, VisualDefaults.showPitches),
            textColor: Color(hex: str(VisualKeys.textColor, VisualDefaults.textColor)),
            textFont: PlaybackFont(rawValue: str(VisualKeys.textFont, VisualDefaults.textFont)) ?? .system)
    }
}

// MARK: - Scene layout

/// Maps musical coordinates (a beat position, a MIDI pitch) to screen points for one
/// rendered frame, encapsulating the keyboard width, per-semitone height (vertical
/// zoom), per-beat width (horizontal zoom) and the pitch sitting at the vertical
/// centre (which "follow notes vertically" moves).
struct SceneLayout {
    let size: CGSize
    let pianoW: CGFloat      // keyboard column width (0 when the keyboard is hidden)
    let rowH: CGFloat        // pixels per semitone
    let beatPx: CGFloat      // pixels per beat
    let playheadX: CGFloat   // x of the fixed playhead line
    let centerPitch: Double  // MIDI pitch drawn at the vertical centre

    var centerY: CGFloat { size.height / 2 }

    /// Vertical centre of the row for a (possibly fractional) MIDI pitch.
    func y(_ pitch: Double) -> CGFloat { centerY - CGFloat(pitch - centerPitch) * rowH }

    /// X position of something at `noteBeat`, given the current playhead `beat`.
    func x(_ noteBeat: Double, beat: Double) -> CGFloat { playheadX + CGFloat(noteBeat - beat) * beatPx }

    /// Highest / lowest integer MIDI pitch visible on screen, clamped to valid MIDI.
    var topPitch: Int { min(127, Int((centerPitch + Double(centerY / rowH)).rounded(.up))) }
    var bottomPitch: Int { max(0, Int((centerPitch - Double((size.height - centerY) / rowH)).rounded(.down))) }
}

/// Smoothly eases the vertical centre toward a target pitch so "follow notes
/// vertically" recentres each repetition without jumping.
final class VerticalFollower {
    private var shown: Double?
    var current: Double? { shown }

    func step(target: Double, factor: Double) -> Double {
        if let c = shown { shown = c + (target - c) * factor } else { shown = target }
        return shown ?? target
    }

    func reset() { shown = nil }
}

// MARK: - Shared scene renderer

/// Draws the scrolling note scene used by both the live playback screen and the
/// visuals-customisation preview, honouring `settings`. Pure drawing — the caller
/// supplies the data, the current beat, the singer's pitch and a pre-built trail
/// path (which depends on the same layout).
func drawPlaybackScene(ctx: GraphicsContext, layout: SceneLayout, beat: Double,
                       notes: [MIDINote], texts: [MIDIText],
                       trailPath: Path, singerPitch: Double?,
                       settings: VisualSettings) {
    let size = layout.size
    let pianoW = layout.pianoW
    let rowH = layout.rowH
    let lo = layout.bottomPitch
    let hi = layout.topPitch
    guard hi >= lo else { return }

    let activePitches = Set(
        notes.filter { beat >= $0.beat && beat < $0.beat + $0.length }.map { $0.pitch }
    )

    // ── Note-area background ──────────────────────────────────────────────
    // With horizontal lines on, shade alternating black/white-key rows and draw
    // separators (the original look); with them off, fill a single plain colour.
    if settings.showHorizontalLines {
        for pitch in lo...hi {
            let yTop = layout.y(Double(pitch)) - rowH / 2
            ctx.fill(
                Path(CGRect(x: pianoW, y: yTop, width: size.width - pianoW, height: rowH)),
                with: .color(isBlack(pitch) ? Color(white: 0.08) : Color(white: 0.14)))
        }
        var hLines = Path()
        for pitch in lo...(hi + 1) {
            let y = layout.y(Double(pitch)) + rowH / 2
            hLines.move(to: CGPoint(x: pianoW, y: y))
            hLines.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(hLines, with: .color(white: 0.2), lineWidth: 0.5)
    } else {
        ctx.fill(Path(CGRect(x: pianoW, y: 0, width: size.width - pianoW, height: size.height)),
                 with: .color(settings.backgroundColor))
    }

    // ── Keyboard column ───────────────────────────────────────────────────
    if settings.showKeyboard && pianoW > 0 {
        for pitch in lo...hi {
            let yTop = layout.y(Double(pitch)) - rowH / 2
            let active = activePitches.contains(pitch)
            let bg: Color = active ? .yellow : (isBlack(pitch) ? Color(white: 0.07) : Color(white: 0.82))
            ctx.fill(Path(CGRect(x: 0, y: yTop, width: pianoW - 1, height: rowH)), with: .color(bg))
        }
        var border = Path()
        border.move(to: CGPoint(x: pianoW - 0.5, y: 0))
        border.addLine(to: CGPoint(x: pianoW - 0.5, y: size.height))
        ctx.stroke(border, with: .color(.gray.opacity(0.4)), lineWidth: 1)
    }

    // ── Pitch names ───────────────────────────────────────────────────────
    // Drawn on the keys when the keyboard is shown, otherwise along the left edge
    // over the background. Skipped when rows are too short to fit legible text.
    if settings.showPitches && rowH >= 9 {
        let fontSize = min(rowH * 0.55, 11)
        ctx.drawLayer { layer in
            for pitch in lo...hi {
                let y = layout.y(Double(pitch))
                if settings.showKeyboard && pianoW > 0 {
                    let color: Color = isBlack(pitch) ? .white.opacity(0.85) : .black.opacity(0.7)
                    layer.draw(Text(pitchName(pitch)).font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(color),
                               at: CGPoint(x: pianoW / 2, y: y), anchor: .center)
                } else {
                    layer.draw(Text(pitchName(pitch)).font(.system(size: fontSize, weight: .medium))
                                .foregroundColor(.white.opacity(0.5)),
                               at: CGPoint(x: pianoW + 4, y: y), anchor: .leading)
                }
            }
        }
    }

    // ── Notes ───────────────────────────────────────────────────────────────
    for note in notes {
        let noteX = layout.x(note.beat, beat: beat)
        let noteW = CGFloat(note.length) * layout.beatPx
        let leftEdge = max(noteX, pianoW)
        let rightEdge = min(noteX + noteW, size.width)
        guard rightEdge > leftEdge else { continue }

        let cy = layout.y(Double(note.pitch))
        let rect = CGRect(x: leftEdge, y: cy - rowH / 2 + 1,
                          width: rightEdge - leftEdge - 1, height: max(1, rowH - 2))
        let radius = max(0, min(settings.noteRoundness * rect.height / 2, rect.width / 2, rect.height / 2))
        let path = Path(roundedRect: rect, cornerRadius: radius)

        let isActive = activePitches.contains(note.pitch) && beat >= note.beat
        if isActive {
            ctx.fill(path, with: .color(settings.playingNoteColor))
            ctx.stroke(path, with: .color(.yellow), lineWidth: 1.5)
        } else {
            ctx.fill(path, with: .color(settings.noteColor))
            ctx.stroke(path, with: .color(settings.noteColor.opacity(0.7)), lineWidth: 1)
        }
    }

    // ── Text labels ───────────────────────────────────────────────────────
    if !texts.isEmpty {
        ctx.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: pianoW, y: 0, width: size.width - pianoW, height: size.height)))
            for label in texts {
                let x = layout.x(label.beat, beat: beat)
                let y = layout.y(Double(label.pitch))
                layer.draw(
                    Text(label.text)
                        .font(.system(size: 12, weight: .semibold, design: settings.textFont.design))
                        .foregroundColor(settings.textColor),
                    at: CGPoint(x: x + 3, y: y), anchor: .leading)
            }
        }
    }

    // ── Playhead ────────────────────────────────────────────────────────────
    var glow = Path()
    glow.move(to: CGPoint(x: layout.playheadX, y: 0))
    glow.addLine(to: CGPoint(x: layout.playheadX, y: size.height))
    ctx.stroke(glow, with: .color(.white.opacity(0.12)), lineWidth: 10)
    var line = Path()
    line.move(to: CGPoint(x: layout.playheadX, y: 0))
    line.addLine(to: CGPoint(x: layout.playheadX, y: size.height))
    ctx.stroke(line, with: .color(.white), lineWidth: 2)

    // ── Singer's pitch history (trailing line) ───────────────────────────────
    ctx.drawLayer { layer in
        layer.clip(to: Path(CGRect(x: pianoW, y: 0, width: size.width - pianoW, height: size.height)))
        layer.stroke(trailPath, with: .color(.cyan.opacity(0.7)), lineWidth: 2.5)
    }

    // ── Singer's current pitch (dot at the playhead) ──────────────────────────
    if let pitch = singerPitch {
        let r = min(rowH * 0.85, 11)
        let y = min(max(layout.y(pitch), r), size.height - r)
        let dot = Path(ellipseIn: CGRect(x: layout.playheadX - r, y: y - r, width: 2 * r, height: 2 * r))
        ctx.fill(dot, with: .color(.cyan))
        ctx.stroke(dot, with: .color(.white), lineWidth: 1.5)
    }
}
