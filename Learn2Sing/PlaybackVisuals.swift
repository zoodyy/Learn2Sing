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

// MARK: - Playhead style

/// How the vertical line under the singing indicator is drawn: as one continuous
/// line, or as a column of dots with one dot centred on every pitch row.
enum PlayheadStyle: String, CaseIterable, Identifiable {
    case line = "Line"
    case dots = "Dots"

    var id: String { rawValue }
}

// MARK: - Repetition counter placement

/// Where the "current / total repetitions" counter sits on the playback screen.
enum RepetitionCounterPosition: String, CaseIterable, Identifiable {
    case topRight     = "Top right"
    case bottomLeft   = "Bottom left"
    case bottomMiddle = "Bottom middle"
    case bottomRight  = "Bottom right"

    var id: String { rawValue }
}

// MARK: - Color <-> hex (so colours can live in UserDefaults / @AppStorage)

extension Color {
    /// Build a colour from a "#RRGGBB" (or "RRGGBBAA") hex string. Falls back to
    /// black for an unparseable string rather than failing.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// "#RRGGBB" representation, used to persist a colour picked from the wheel.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// The app's accent colour, read straight from the asset catalogue. `.accentColor`
    /// resolves against a view's tint, which there is none of where a stored default
    /// has to be turned into a hex string, so the colour set is named outright — the
    /// same name the app's global accent-colour build setting points at.
    static var appAccent: Color {
        if let accent = UIColor(named: "AccentColor") { return Color(uiColor: accent) }
        return .accentColor
    }

    /// "#RRGGBBAA" representation, used for colours whose opacity (including fully
    /// transparent) is meaningful, like the singer indicator's fill/stroke/trail.
    var hexStringWithAlpha: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()),
                      Int((b * 255).rounded()), Int((a * 255).rounded()))
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
    static let autoPitchNameColor = "vis_autoPitchNameColor"
    static let pitchNameColor     = "vis_pitchNameColor"
    static let textColor      = "vis_textColor"
    static let textFont       = "vis_textFont"
    static let singerSize        = "vis_singerSize"
    static let singerInnerColor  = "vis_singerInnerColor"
    static let singerOuterColor  = "vis_singerOuterColor"
    static let singerLineColor   = "vis_singerLineColor"
    static let playheadColor  = "vis_playheadColor"
    static let playheadStyle  = "vis_playheadStyle"
    static let hideUnusedDots = "vis_hideUnusedDots"
    static let showRepetitionCounter    = "vis_showRepetitionCounter"
    static let repetitionCounterPosition = "vis_repetitionCounterPosition"
    static let hideTabBar     = "vis_hideTabBar"

    /// Every key above, so Settings ▸ Reset can clear the lot without naming them
    /// one by one. Add new keys here as well as above.
    static let all = [
        noteColor, playingNoteColor, noteRoundness, verticalZoom, horizontalZoom,
        followVertical, showLines, background, showKeyboard, showPitches,
        autoPitchNameColor, pitchNameColor,
        textColor, textFont, singerSize, singerInnerColor, singerOuterColor,
        singerLineColor, playheadColor, playheadStyle, hideUnusedDots,
        showRepetitionCounter, repetitionCounterPosition, hideTabBar,
    ]
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
    static let autoPitchNameColor = true
    /// Only used once the automatic colour above is switched off; white at 50%, which
    /// is what the names are drawn in over the background while it is on.
    static let pitchNameColor     = "#FFFFFF80"
    static let textColor      = "#FF9500"   // orange, matching the original look
    static let textFont       = PlaybackFont.system.rawValue
    static let singerSize        = 1.0          // multiplier on the original dot radius
    static let singerInnerColor  = "#00FFFFFF"  // cyan, the original dot fill
    static let singerOuterColor  = "#FFFFFFFF"  // white, the original dot border
    static let singerLineColor   = "#00FFFFB2"  // cyan at ~70% opacity, the original trail
    static let playheadColor  = "#FFFFFFFF"     // white, the original playhead line
    static let playheadStyle  = PlayheadStyle.line.rawValue
    static let hideUnusedDots = false
    static let showRepetitionCounter    = false
    static let repetitionCounterPosition = RepetitionCounterPosition.bottomRight.rawValue
    static let hideTabBar     = false
}

// MARK: - Menu visuals

/// Stored keys for the "Menus" visual settings — the look of the app's own lists
/// and screens, as opposed to the playback canvas. Kept apart from `VisualKeys`
/// so visual templates, which capture the playback settings, don't carry them.
enum MenuVisualKeys {
    static let exercisePreviewColor = "menu_exercisePreviewColor"
}

enum MenuVisualDefaults {
    /// The accent colour itself rather than a literal copy of it, so the previews
    /// follow the app's tint if it is ever changed. Resolved afresh on every read:
    /// a colour the user picked is stored under the key above and stays put, while
    /// clearing that key — what Settings ▸ Reset does — lands back on whatever the
    /// accent colour is at the time.
    static var exercisePreviewColor: String { Color.appAccent.hexString }
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
    /// Draw the pitch names in a colour that stands out where each one sits — dark on
    /// the white keys, light on the black ones, light over the background with the
    /// keyboard hidden — instead of in `pitchNameColor`.
    var autoPitchNameColor: Bool
    var pitchNameColor: Color
    var textColor: Color
    var textFont: PlaybackFont
    var singerSize: Double
    var singerInnerColor: Color
    var singerOuterColor: Color
    var singerLineColor: Color
    var playheadColor: Color
    var playheadStyle: PlayheadStyle
    /// "Dots" style only: draw a dot on just those rows a note of the current
    /// repetition passes through, instead of on every row.
    var hideUnusedDots: Bool
    var showRepetitionCounter: Bool
    var repetitionCounterPosition: RepetitionCounterPosition
    // Hides the tab bar while an exercise plays. Not part of the drawn scene (so the
    // visuals preview ignores it), which is why it defaults here: the preview's
    // memberwise construction doesn't need to mention it.
    var hideTabBar: Bool = false

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
            autoPitchNameColor: bool(VisualKeys.autoPitchNameColor, VisualDefaults.autoPitchNameColor),
            pitchNameColor: Color(hex: str(VisualKeys.pitchNameColor, VisualDefaults.pitchNameColor)),
            textColor: Color(hex: str(VisualKeys.textColor, VisualDefaults.textColor)),
            textFont: PlaybackFont(rawValue: str(VisualKeys.textFont, VisualDefaults.textFont)) ?? .system,
            singerSize: dbl(VisualKeys.singerSize, VisualDefaults.singerSize),
            singerInnerColor: Color(hex: str(VisualKeys.singerInnerColor, VisualDefaults.singerInnerColor)),
            singerOuterColor: Color(hex: str(VisualKeys.singerOuterColor, VisualDefaults.singerOuterColor)),
            singerLineColor: Color(hex: str(VisualKeys.singerLineColor, VisualDefaults.singerLineColor)),
            playheadColor: Color(hex: str(VisualKeys.playheadColor, VisualDefaults.playheadColor)),
            playheadStyle: PlayheadStyle(
                rawValue: str(VisualKeys.playheadStyle, VisualDefaults.playheadStyle)) ?? .line,
            hideUnusedDots: bool(VisualKeys.hideUnusedDots, VisualDefaults.hideUnusedDots),
            showRepetitionCounter: bool(VisualKeys.showRepetitionCounter, VisualDefaults.showRepetitionCounter),
            repetitionCounterPosition: RepetitionCounterPosition(
                rawValue: str(VisualKeys.repetitionCounterPosition, VisualDefaults.repetitionCounterPosition)) ?? .bottomRight,
            hideTabBar: bool(VisualKeys.hideTabBar, VisualDefaults.hideTabBar))
    }
}

// MARK: - Scene layout

/// The scene's two fixed dimensions, before the zoom settings scale them: the width
/// of the keyboard column and the width of one beat. Shared so the live playback
/// screen, the visuals preview and the review screen all lay out identically.
let playbackKeyboardWidth: CGFloat = 38
let playbackBeatWidth: CGFloat = 40

/// One estimate from the pitch detector: the musical beat it was heard at, and the
/// (fractional) MIDI pitch — `nil` where nothing was detected, which breaks the
/// drawn line instead of jumping it across the gap.
struct PitchSample {
    let beat: Double
    let pitch: Double?
}

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
    let centerY: CGFloat     // screen y at which `centerPitch` is drawn

    init(size: CGSize, pianoW: CGFloat, rowH: CGFloat, beatPx: CGFloat,
         playheadX: CGFloat, centerPitch: Double, centerY: CGFloat? = nil) {
        self.size = size
        self.pianoW = pianoW
        self.rowH = rowH
        self.beatPx = beatPx
        self.playheadX = playheadX
        self.centerPitch = centerPitch
        // Defaults to the canvas midpoint; callers can shift it (e.g. to centre content
        // within the safe area rather than the full screen).
        self.centerY = centerY ?? size.height / 2
    }

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

// MARK: - Repetition pitches (for the "hide dots in unused pitches" option)

/// The pitches a note lands on during the repetition that is currently being sung.
/// `repeatSpan` is one repetition's length in beats — including any silence between
/// repetitions — as used to expand the pattern; with 0 (content that doesn't repeat)
/// every note counts.
///
/// The switch to the next repetition happens as soon as the current one's last note
/// has stopped sounding, rather than at the span boundary, so during the silence
/// between two repetitions the dots already show the one about to start. The final
/// repetition keeps its pitches once it ends — there is nothing after it to show.
func repetitionPitches(notes: [MIDINote], beat: Double, repeatSpan: Double) -> Set<Int> {
    guard repeatSpan > 0 else { return Set(notes.map(\.pitch)) }

    // Runs on every rendered frame, so it walks the notes a few times rather than
    // building a dictionary of sets covering every repetition to then use one of them.
    func repetition(of note: MIDINote) -> Int { Int(floor(note.beat / repeatSpan + 1e-6)) }

    var firstRep = Int.max
    var lastRep = Int.min
    for note in notes {
        let rep = repetition(of: note)
        if rep < firstRep { firstRep = rep }
        if rep > lastRep { lastRep = rep }
    }
    // Clamped so the lead-in (a negative beat) shows the first repetition's dots and
    // anything past the end keeps the last one's.
    guard firstRep <= lastRep else { return [] }
    var index = min(max(Int(floor(beat / repeatSpan)), firstRep), lastRep)

    if index < lastRep {
        var end = -Double.infinity
        for note in notes where repetition(of: note) == index {
            end = max(end, note.beat + note.length)
        }
        if end > -.infinity, beat >= end { index += 1 }
    }

    var pitches = Set<Int>()
    for note in notes where repetition(of: note) == index { pitches.insert(note.pitch) }
    return pitches
}

// MARK: - Shared scene renderer

/// Draws the scrolling note scene used by both the live playback screen and the
/// visuals-customisation preview, honouring `settings`. Pure drawing — the caller
/// supplies the data, the current beat, the singer's pitch and a pre-built trail
/// path (which depends on the same layout).
/// `repetition` is the (current, total) repetition pair, 1-based. When it is non-nil
/// and the counter is enabled, a "current / total" badge is drawn at the configured
/// corner. Callers pass nil to hide it (e.g. exercises that don't repeat). `safeTop`
/// and `safeBottom` keep that badge clear of on-screen chrome in the live view.
/// `playheadTop` is the y at which the playhead line begins, so the live view can stop
/// it level with the top of the toolbar buttons instead of running to the screen edge.
/// `repeatSpan` is one repetition's length in beats, needed only by the dotted
/// playhead's "hide dots in unused pitches" option to tell the repetitions apart.
func drawPlaybackScene(ctx: GraphicsContext, layout: SceneLayout, beat: Double,
                       notes: [MIDINote], texts: [MIDIText],
                       trailPath: Path, singerPitch: Double?,
                       settings: VisualSettings,
                       repetition: (current: Int, total: Int)? = nil,
                       safeTop: CGFloat = 0, safeBottom: CGFloat = 0,
                       playheadTop: CGFloat = 0, repeatSpan: Double = 0) {
    let size = layout.size
    let pianoW = layout.pianoW
    let rowH = layout.rowH
    let lo = layout.bottomPitch
    let hi = layout.topPitch
    guard hi >= lo else { return }

    // ── Note-area background ──────────────────────────────────────────────
    // With horizontal lines on, shade alternating black/white-key rows and draw
    // separators (the original look); with them off, fill a single plain colour.
    // Rows of the same shade go into one path: at a low vertical zoom there are over
    // a hundred of them, and a fill per row costs far more than the drawing itself.
    if settings.showHorizontalLines {
        var blackRows = Path()
        var whiteRows = Path()
        let rowWidth = size.width - pianoW
        for pitch in lo...hi {
            let rect = CGRect(x: pianoW, y: layout.y(Double(pitch)) - rowH / 2,
                              width: rowWidth, height: rowH)
            if isBlack(pitch) { blackRows.addRect(rect) } else { whiteRows.addRect(rect) }
        }
        ctx.fill(blackRows, with: .color(white: 0.08))
        ctx.fill(whiteRows, with: .color(white: 0.14))

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
        // The sounding pitches are only needed to light up the keys, so they're
        // gathered here rather than for every frame the keyboard is switched off.
        var activePitches = Set<Int>()
        for note in notes where beat >= note.beat && beat < note.beat + note.length {
            activePitches.insert(note.pitch)
        }

        var activeKeys = Path()
        var blackKeys = Path()
        var whiteKeys = Path()
        for pitch in lo...hi {
            let rect = CGRect(x: 0, y: layout.y(Double(pitch)) - rowH / 2,
                              width: pianoW - 1, height: rowH)
            if activePitches.contains(pitch) { activeKeys.addRect(rect) }
            else if isBlack(pitch) { blackKeys.addRect(rect) }
            else { whiteKeys.addRect(rect) }
        }
        ctx.fill(whiteKeys, with: .color(white: 0.82))
        ctx.fill(blackKeys, with: .color(white: 0.07))
        ctx.fill(activeKeys, with: .color(.yellow))

        var border = Path()
        border.move(to: CGPoint(x: pianoW - 0.5, y: 0))
        border.addLine(to: CGPoint(x: pianoW - 0.5, y: size.height))
        ctx.stroke(border, with: .color(.gray.opacity(0.4)), lineWidth: 1)
    }

    // ── Vertical extent shared by the pitch names and the playhead ─────────
    // A row only counts as visible when everything belonging to it fits between the
    // top of the playhead line (clear of the toolbar buttons) and the bottom edge:
    // the whole row band, from the horizontal separator above it to the one below,
    // plus the name drawn on it when that text is taller than the row. Names go on
    // exactly those rows; the dotted playhead puts one dot on each of them, so its
    // last dot is level with the last name; and the continuous line runs from the
    // separator above the first row to the separator below the last. With names
    // hidden (or rows too short for legible text) there is nothing to align to, so
    // the line spans everything below the toolbar as before.
    let headTop = min(max(0, playheadTop), size.height)
    let nameFontSize = min(rowH * 0.55, 11)
    // Clearance a row needs either side of its centre: half a row, or half the name's
    // text height where that overflows the row.
    let rowMargin = max(rowH / 2, nameFontSize * 0.7)
    let namePitches: [Int] = (settings.showPitches && rowH >= 9)
        ? (lo...hi).filter { pitch in
              let y = layout.y(Double(pitch))
              return y - rowMargin >= headTop && y + rowMargin <= size.height
          }
        : []
    // `namePitches` runs low → high pitch, i.e. bottom → top of the screen.
    let headLineTop = namePitches.last.map { layout.y(Double($0)) - rowH / 2 } ?? headTop
    let headBottom = namePitches.first.map { layout.y(Double($0)) + rowH / 2 } ?? size.height

    // ── Pitch names ───────────────────────────────────────────────────────
    // Drawn on the keys when the keyboard is shown, otherwise along the left edge
    // over the background. Their colour is the chosen one, or — while it is left
    // automatic — one that stands out against whatever each name sits on: the keys
    // are drawn in fixed shades, so on them that means dark on the white ones and
    // light on the black ones.
    if !namePitches.isEmpty {
        let fontSize = nameFontSize
        let onKeys = settings.showKeyboard && pianoW > 0
        ctx.drawLayer { layer in
            for pitch in namePitches {
                let y = layout.y(Double(pitch))
                let color: Color
                if !settings.autoPitchNameColor {
                    color = settings.pitchNameColor
                } else if onKeys {
                    color = isBlack(pitch) ? .white.opacity(0.85) : .black.opacity(0.7)
                } else {
                    color = .white.opacity(0.5)
                }
                let text = Text(pitchName(pitch)).font(.system(size: fontSize, weight: .medium))
                    .foregroundColor(color)
                if onKeys {
                    layer.draw(text, at: CGPoint(x: pianoW / 2, y: y), anchor: .center)
                } else {
                    layer.draw(text, at: CGPoint(x: pianoW + 4, y: y), anchor: .leading)
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

        let isActive = beat >= note.beat && beat < note.beat + note.length
        if isActive {
            // Stroke in the same colour as the fill so the active note isn't a hair
            // smaller than the others, which carry an outward 1pt stroke of their own.
            ctx.fill(path, with: .color(settings.playingNoteColor))
            ctx.stroke(path, with: .color(settings.playingNoteColor), lineWidth: 1)
        } else {
            ctx.fill(path, with: .color(settings.noteColor))
            ctx.stroke(path, with: .color(settings.noteColor.opacity(0.7)), lineWidth: 1)
        }
    }

    // ── Text labels ───────────────────────────────────────────────────────
    // Only the labels that can actually land on screen are drawn: laying out a `Text`
    // is one of the most expensive things in this pass, and a repeated exercise can
    // carry a hundred labels of which a handful are ever visible. `labelMargin` is a
    // generous allowance for a label whose start has scrolled past the left edge but
    // whose tail is still showing.
    if !texts.isEmpty {
        let labelMargin: CGFloat = 240
        let leftBeat = beat + Double((pianoW - labelMargin - layout.playheadX) / layout.beatPx)
        let rightBeat = beat + Double((size.width - layout.playheadX) / layout.beatPx)
        let anyVisible = texts.contains { $0.beat > leftBeat && $0.beat < rightBeat }
        if anyVisible {
            ctx.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: pianoW, y: 0,
                                           width: size.width - pianoW, height: size.height)))
                for label in texts where label.beat > leftBeat && label.beat < rightBeat {
                    let y = layout.y(Double(label.pitch))
                    guard y > -24, y < size.height + 24 else { continue }   // clear of the label's own height
                    layer.draw(
                        Text(label.text)
                            .font(.system(size: 12, weight: .semibold, design: settings.textFont.design))
                            .foregroundColor(settings.textColor),
                        at: CGPoint(x: layout.x(label.beat, beat: beat) + 3, y: y), anchor: .leading)
                }
            }
        }
    }

    // ── Playhead ────────────────────────────────────────────────────────────
    // Either a continuous line from `headLineTop` to `headBottom`, or — in "dots"
    // style — a column of dots, one centred on each named pitch row. Both carry the
    // same soft glow behind them, tinted with the chosen colour.
    let headColor = settings.playheadColor
    switch settings.playheadStyle {
    case .line:
        guard headBottom > headLineTop else { break }
        var glow = Path()
        glow.move(to: CGPoint(x: layout.playheadX, y: headLineTop))
        glow.addLine(to: CGPoint(x: layout.playheadX, y: headBottom))
        ctx.stroke(glow, with: .color(headColor.opacity(0.12)), lineWidth: 10)
        var line = Path()
        line.move(to: CGPoint(x: layout.playheadX, y: headLineTop))
        line.addLine(to: CGPoint(x: layout.playheadX, y: headBottom))
        ctx.stroke(line, with: .color(headColor), lineWidth: 2)
    case .dots:
        // Dots scale with the row height so they stay clear of each other at any
        // vertical zoom, capped so they don't swell into blobs when zoomed right in.
        let r = max(1, min(rowH * 0.18, 4))
        let glowR = r + 3
        var dots = Path()
        var glow = Path()
        // One dot per named row; with names hidden, every row between the toolbar
        // and the bottom edge gets one.
        var dotPitches = namePitches.isEmpty
            ? (lo...hi).filter { (headTop...size.height).contains(layout.y(Double($0))) }
            : namePitches
        // "Hide dots in unused pitches": keep only the rows a note of the repetition
        // being sung passes through, so the dots spell out the coming pattern.
        if settings.hideUnusedDots {
            let used = repetitionPitches(notes: notes, beat: beat, repeatSpan: repeatSpan)
            dotPitches = dotPitches.filter { used.contains($0) }
        }
        for pitch in dotPitches {
            let y = layout.y(Double(pitch))
            dots.addEllipse(in: CGRect(x: layout.playheadX - r, y: y - r,
                                       width: 2 * r, height: 2 * r))
            glow.addEllipse(in: CGRect(x: layout.playheadX - glowR, y: y - glowR,
                                       width: 2 * glowR, height: 2 * glowR))
        }
        ctx.fill(glow, with: .color(headColor.opacity(0.12)))
        ctx.fill(dots, with: .color(headColor))
    }

    // ── Singer's pitch history (trailing line) ───────────────────────────────
    ctx.drawLayer { layer in
        layer.clip(to: Path(CGRect(x: pianoW, y: 0, width: size.width - pianoW, height: size.height)))
        layer.stroke(trailPath, with: .color(settings.singerLineColor), lineWidth: 2.5)
    }

    // ── Singer's current pitch (dot at the playhead) ──────────────────────────
    if let pitch = singerPitch {
        let r = min(rowH * 0.85, 11) * settings.singerSize
        let y = min(max(layout.y(pitch), r), size.height - r)
        let dot = Path(ellipseIn: CGRect(x: layout.playheadX - r, y: y - r, width: 2 * r, height: 2 * r))
        ctx.fill(dot, with: .color(settings.singerInnerColor))
        ctx.stroke(dot, with: .color(settings.singerOuterColor), lineWidth: 1.5)
    }

    // ── Repetition counter ────────────────────────────────────────────────────
    // A "current / total" badge showing which repetition is playing. Drawn last so it
    // sits above the notes; only shown when enabled and the exercise actually repeats.
    if settings.showRepetitionCounter, let rep = repetition, rep.total > 1 {
        let resolved = ctx.resolve(
            Text(verbatim: "\(rep.current)/\(rep.total)")
                .font(.system(size: 15, weight: .semibold, design: settings.textFont.design))
                .foregroundColor(.white))
        let textSize = resolved.measure(in: size)
        let padH: CGFloat = 9, padV: CGFloat = 4
        let badge = CGSize(width: textSize.width + 2 * padH, height: textSize.height + 2 * padV)
        let margin: CGFloat = 10
        let topY = safeTop + margin
        let bottomY = size.height - safeBottom - margin - badge.height
        let origin: CGPoint
        switch settings.repetitionCounterPosition {
        case .topRight:     origin = CGPoint(x: size.width - margin - badge.width, y: topY)
        case .bottomLeft:   origin = CGPoint(x: margin, y: bottomY)
        case .bottomMiddle: origin = CGPoint(x: (size.width - badge.width) / 2, y: bottomY)
        case .bottomRight:  origin = CGPoint(x: size.width - margin - badge.width, y: bottomY)
        }
        let pill = Path(roundedRect: CGRect(origin: origin, size: badge), cornerRadius: badge.height / 2)
        ctx.fill(pill, with: .color(.black.opacity(0.55)))
        ctx.draw(resolved, at: CGPoint(x: origin.x + badge.width / 2, y: origin.y + badge.height / 2),
                 anchor: .center)
    }
}
