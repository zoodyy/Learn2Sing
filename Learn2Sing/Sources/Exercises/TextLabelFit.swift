import SwiftUI
import UIKit

// How text labels are shrunk where they'd run into something. Two things crowd a
// label: the notes around it, once a repetition sped up by "speed up per repetition"
// squeezes them closer than they were written, and the other labels. Either way the
// text shrinks about its middle, staying where it was placed, until there's
// `textLabelMargin` between it and whatever it was running into. Only something
// the text would actually run into counts: a note or label drawn clear above or
// below it never makes it shrink, however close it passes. Playback, the review
// screen, the exercise settings preview and the MIDI editor all fit their labels
// through here, so they agree on when a label shrinks and how far.

/// The room kept clear to the side between a label and a note it would otherwise
/// run into, and between two labels, in points: enough for the two to read as
/// separate things.
let textLabelMargin: CGFloat = 4

/// The smallest share of its written size a label is ever shrunk to. Below about
/// half of `midiTextFontSize` text stops being readable, and a label that can't be
/// read is no better than one that overlaps its neighbour, so the fitting stops here
/// and lets the two overlap.
let minimumTextLabelScale = 0.5

/// One label as the fitting sees it, in the points of the screen drawing it.
struct TextLabelBox {
    /// Where the label's middle is drawn.
    var centre: CGPoint
    /// What it draws at its written size: the box that shrinks about `centre`.
    var size: CGSize
    /// The largest share of that size it may be drawn at for some other reason, such
    /// as the notes around it (see `MIDIText.noteFitScale`). 1 when nothing else
    /// holds it back.
    var limit: Double = 1
}

/// The share of its written size each of `boxes` is drawn at, in the same order: as
/// large as its own `limit` allows, and small enough that no two labels come within
/// `textLabelMargin` of each other.
///
/// Two labels that crowd each other shrink alike, to the one scale that clears the
/// margin between them, rather than one giving up all the room while the other keeps
/// its size: shrinking just one would take it twice as far down to make the same
/// room, and the whole point is that both stay readable. A label crowded on several
/// sides takes the smallest of those scales. Since every pair gets at least the room
/// its own scale makes, and nothing is drawn larger than that, the labels clear one
/// another however the pairs chain together.
///
/// Two labels can be cleared either side by side or one above the other, whichever
/// takes less shrinking. Side by side they keep `textLabelMargin` apart; one above
/// the other their letters only have to stop overlapping. Rows are what set labels
/// apart vertically, and no tempo ever moves two of them closer that way, so two
/// labels whose letters don't touch are left at full size however close they pass
/// over one another. Neither way ever takes them under `minimumTextLabelScale`.
func fittedTextLabelScales(_ boxes: [TextLabelBox]) -> [Double] {
    var scales = boxes.map { min(1, $0.limit) }
    let margin = Double(textLabelMargin)
    for i in boxes.indices {
        for j in boxes.indices where j > i {
            let a = boxes[i], b = boxes[j]
            let dx = Double(abs(a.centre.x - b.centre.x))
            let dy = Double(abs(a.centre.y - b.centre.y))
            // At a common scale `s` the two reach `s` times half their summed sizes
            // towards each other; what's left of the distance between their middles
            // has to cover the margin side by side, and only has to stay positive
            // one above the other.
            let halfWidths = Double(a.size.width + b.size.width) / 2
            let halfHeights = Double(a.size.height + b.size.height) / 2
            let sideBySide = halfWidths > 0 ? (dx - margin) / halfWidths : .infinity
            let stacked = halfHeights > 0 ? dy / halfHeights : .infinity
            let fit = max(sideBySide, stacked)
            guard fit < 1 else { continue }
            scales[i] = min(scales[i], fit)
            scales[j] = min(scales[j], fit)
        }
    }
    return scales.map { max(minimumTextLabelScale, $0) }
}

extension MIDIText {
    /// The largest share of its written size this label may be drawn at and still keep
    /// clear of the notes around it, when its text reaches `halfWidth` points either
    /// side of its middle and its letters `reach` points above and below it, on a
    /// screen giving a beat `beatPx` points and a row `rowH`. Always 1 at the written
    /// tempo, where the label stands exactly as it was written.
    ///
    /// A repetition squeezed to a faster tempo (`tempoScale` below 1) narrows its
    /// notes but not the text over them, closing the gap between the text and every
    /// note it used to clear to the side. Only a note the letters would actually run
    /// into is a reason to shrink: one in a row the letters reach into, above or below
    /// as well as their own. A note drawn clear above or below them can pass over or
    /// under the text however tightly it's squeezed, since no tempo moves it any
    /// nearer that way. Each note the text would run into is kept `textLabelMargin`
    /// away to the side — or as far as it was at the written tempo, where the text
    /// was written closer than that — by shrinking the text about its middle, unless
    /// shrinking it less already pulls the letters out of that note's row. A note the
    /// text already reached over at the written tempo is left out: the label was
    /// written across it, and belongs there at every tempo.
    ///
    /// Worked out in points rather than beats or rows because the text is drawn at a
    /// size of its own, whatever the zoom: how many beats and rows it covers, and so
    /// which notes it runs into, depends on how many points the screen gives each.
    func noteFitScale(halfWidth: CGFloat, reach: TextLetterReach,
                      beatPx: CGFloat, rowH: CGFloat) -> Double {
        guard tempoScale < 1, halfWidth > 0, beatPx > 0 else { return 1 }
        let half = Double(halfWidth)
        let margin = Double(textLabelMargin)
        // A note is drawn a row high, less a point above and below.
        let noteHalfHeight = Double(max(1, rowH - 2)) / 2
        var fit = 1.0
        for gap in noteGaps {                                   // nearest first
            let written = gap.beats * Double(beatPx)            // the note's distance from the middle, as written
            let squeezed = written * tempoScale
            // Clear of this note to the side at full size, and so of every note further out.
            if squeezed - margin >= half { break }
            // How far the near edge of the note's row is above or below the middle,
            // and how far the letters reach that way. Negative on the label's own row.
            let edge = Double(abs(gap.rows)) * Double(rowH) - noteHalfHeight
            let towards = Double(gap.rows > 0 ? reach.above : reach.below)
            guard edge < towards else { continue }              // the letters stop short of its row
            guard written >= half else { continue }             // the text reached over it as written
            let clearance = min(margin, written - half)
            let sideBySide = (squeezed - clearance) / half
            let outOfItsRow = towards > 0 ? edge / towards : 0
            fit = min(fit, max(sideBySide, outOfItsRow))
        }
        return fit
    }
}

// MARK: - Text measurement

private extension PlaybackFont {
    var systemDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .system:     return .default
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }
}

/// The label texts measured in the semibold `midiTextFontSize` they're written at,
/// each string once per font: a string's width never changes, and the roll asks for
/// every label's width on every redraw — which during a drag is every touch — as
/// playback does on every frame. Measured per `PlaybackFont` because playback may
/// draw the labels in any of them, and a monospaced label lays out wider than the
/// system font the editor uses.
enum TextWidths {
    private static var fonts: [PlaybackFont: UIFont] = [:]
    private static var widths: [PlaybackFont: [String: CGFloat]] = [:]

    private static func font(_ design: PlaybackFont) -> UIFont {
        if let known = fonts[design] { return known }
        let system = UIFont.systemFont(ofSize: midiTextFontSize, weight: .semibold)
        let font = system.fontDescriptor.withDesign(design.systemDesign)
            .map { UIFont(descriptor: $0, size: midiTextFontSize) } ?? system
        fonts[design] = font
        return font
    }

    static func width(of text: String, in design: PlaybackFont = .system) -> CGFloat {
        if let known = widths[design]?[text] { return known }
        let width = (text as NSString).size(withAttributes: [.font: font(design)]).width
        widths[design, default: [:]][text] = width
        return width
    }

    /// How tall the letters stand, from the top of a capital to the bottom of a
    /// descender: what two labels one above the other have to keep apart. Shorter
    /// than the line the text is laid out in, which leaves room for accents and
    /// line spacing that the letters themselves don't fill.
    static func letterHeight(in design: PlaybackFont = .system) -> CGFloat {
        let font = font(design)
        return font.capHeight - font.descender
    }

    /// The same letters measured from the point a label is drawn at, the middle of
    /// the line it's laid out in. They don't sit evenly about it: the line keeps
    /// room above the capitals for accents, so the letters sit low in it, and a
    /// note in the row below comes nearer them than one in the row above.
    static func letterReach(in design: PlaybackFont = .system) -> TextLetterReach {
        let font = font(design)
        let baseline = (font.ascender + font.descender) / 2     // below the middle
        return TextLetterReach(above: font.capHeight - baseline,
                               below: baseline - font.descender)
    }
}

/// How far a label's letters reach above and below the middle it's drawn at, at
/// the size it was written at (see `TextWidths.letterReach`).
struct TextLetterReach {
    var above: CGFloat
    var below: CGFloat
}
