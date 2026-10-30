//
//  RunStatisticsView.swift
//  Learn2Sing
//
//  The statistics the score screen shows below its chart, reached by scrolling
//  down: where the voice sat on the notes, with the path it took across a note on
//  average, and how fast it moved from one note to the next. Worked out and held
//  by the playback screen (see `RunStatistics`), never saved.
//

import SwiftUI
import UIKit

struct RunStatisticsView: View {
    /// Re-renders the statistics when the language is changed in Settings, which
    /// the tab bar the score screen keeps showing can reach.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// nil while they are still being worked out.
    let statistics: RunStatistics?

    var body: some View {
        VStack(spacing: 12) {
            if let statistics {
                NotePositionCard(statistics: statistics)
                NoteChangesCard(changes: statistics.noteChanges)
            } else {
                // Rarely seen: they take a few milliseconds, and are below the
                // first screen.
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }
}

/// One statistic's card, on the surface the score screen's own background sits a
/// step below in either appearance.
private struct StatisticsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The type a statistic's number is written in: the score's rounded face, a size
/// down from it.
private let statisticFont = Font.system(size: 34, weight: .bold, design: .rounded)

/// Where the voice sat on the notes: the average in cents, said in words, and the
/// line it took across a note on average, drawn over a note.
private struct NotePositionCard: View {
    let statistics: RunStatistics

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Where You Sang on the Notes")
                    .font(.headline)
                if let cents = statistics.averageCents {
                    Text(verbatim: Self.centsText(cents))
                        .font(statisticFont)
                        .monospacedDigit()
                    Text(Self.direction(cents))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    // Said only when some were left out: a note sung far off the
                    // centre, or hardly at all, says nothing about where it was held.
                    if statistics.measuredNotes < statistics.noteCount {
                        Text(L("Measured on %d of %d notes.", statistics.measuredNotes, statistics.noteCount))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                } else {
                    Text("No note was sung clearly enough to measure.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .explain(L("Where your voice sat on the notes while you held them, on average. A cent (ct) is a hundredth of a semitone: plus is above the center of the note, minus below it."))

            if statistics.averageCents != nil {
                NotePathGraphic(path: statistics.averagePath)
                    .frame(height: 120)
                    .explain(L("Your pitch line averaged over all the notes you sang, from the start of a note on the left to its end on the right. The dashed line is the exact pitch."))
            }
        }
    }

    /// The average to the whole cent, signed the way a tuner shows it, with the
    /// sign left off at zero, where it would mean nothing.
    private static func centsText(_ cents: Double) -> String {
        let whole = Int(cents.rounded())
        let number = whole > 0 ? "+\(whole)" : whole < 0 ? "\u{2212}\(-whole)" : "0"
        return L("%@ ct", number)
    }

    private static func direction(_ cents: Double) -> String {
        switch Int(cents.rounded()) {
        case 1...: L("On average, you sang above the center of the notes.")
        case ..<0: L("On average, you sang below the center of the notes.")
        default: L("On average, you sang right on the center of the notes.")
        }
    }
}

/// How fast the voice moved from one note to the next: the speed over all the
/// moves, the time a move took at it, and the moves up and down on their own when
/// the run had both.
private struct NoteChangesCard: View {
    let changes: RunStatistics.NoteChanges?

    /// The app's language, which `ContentView` sets, for the decimal comma.
    @Environment(\.locale) private var locale

    var body: some View {
        StatisticsCard {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speed Between Notes")
                    .font(.headline)
                if let changes {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: speedText(changes.semitonesPerSecond))
                            .font(statisticFont)
                            .monospacedDigit()
                        Text("semitones per second")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // To the nearest 10 ms: closer than that is more than one run
                    // can say.
                    Text(L("About %d ms per note change.",
                           Int((changes.secondsPerChange * 100).rounded()) * 10))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No note changes could be measured in this run.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let up = changes?.upwardSemitonesPerSecond,
               let down = changes?.downwardSemitonesPerSecond {
                Divider()
                VStack(spacing: 8) {
                    HStack {
                        Label("Going up", systemImage: "arrow.up.right")
                        Spacer()
                        Text(L("%@ semitones/s", speedText(up)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Label("Going down", systemImage: "arrow.down.right")
                        Spacer()
                        Text(L("%@ semitones/s", speedText(down)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
        }
        .explain(L("How fast your voice moved from one note to the next, measured on the changes you sang without a break. Going up and going down are shown separately when the exercise has both."))
    }

    /// A speed in semitones per second: whole ones, and a tenth more below ten,
    /// where a whole one is a big share of it.
    private func speedText(_ speed: Double) -> String {
        speed < 9.95
            ? String(format: "%.1f", locale: locale, speed)
            : String(Int(speed.rounded()))
    }
}

/// A note as the playback screen draws it, zoomed in until it fills the width, with
/// the run's average pitch line across it in the singer's line colour and the exact
/// pitch dashed through its middle. Drawn in the singer's own playback look, so it
/// reads as the note they sang against.
private struct NotePathGraphic: View {
    /// `RunStatistics.averagePath`: cents from the note's centre, start to end.
    let path: [Double?]

    @State private var visuals = VisualSettings.current

    var body: some View {
        Canvas { ctx, size in draw(ctx: ctx, size: size) }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Framed, so a look as light as the card it sits on still reads as a
            // picture of its own.
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityElement()
            .accessibilityLabel(L("Average pitch line across a note"))
    }

    /// How many cents above and below the note's centre are shown: the note's own
    /// row and one row either side of it, or two or three where the line reaches
    /// further out, so all of it is drawn.
    private var reach: Double {
        let furthest = path.compactMap { $0.map(abs) }.max() ?? 0
        // A little room past the line, so it doesn't run along the edge.
        for rows in [1.0, 2.0, 3.0] where furthest + 25 <= 50 + 100 * rows {
            return 50 + 100 * rows
        }
        return 350
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let s = visuals
        let reach = self.reach
        let rowH = size.height / CGFloat(reach / 50)
        let midY = size.height / 2
        func y(_ cents: Double) -> CGFloat { midY - CGFloat(cents / 100) * rowH }

        // ── Background: the playback screen's rows, or its plain colour ──────
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(s.showHorizontalLines ? Color(white: 0.11) : s.backgroundColor))
        if s.showHorizontalLines {
            var lines = Path()
            for edge in stride(from: 50.0, through: reach, by: 100) {
                for lineY in [y(edge), y(-edge)] {
                    lines.move(to: CGPoint(x: 0, y: lineY))
                    lines.addLine(to: CGPoint(x: size.width, y: lineY))
                }
            }
            ctx.stroke(lines, with: .color(white: 0.2), lineWidth: 0.5)
        }

        // ── The note ──────────────────────────────────────────────────────────
        let inset: CGFloat = 12
        let noteRect = CGRect(x: inset, y: midY - rowH / 2 + 1,
                              width: max(1, size.width - 2 * inset), height: max(1, rowH - 2))
        let radius = max(0, min(s.noteRoundness * noteRect.height / 2,
                                noteRect.width / 2, noteRect.height / 2))
        let note = Path(roundedRect: noteRect, cornerRadius: radius)
        ctx.fill(note, with: .color(s.noteColor))
        ctx.stroke(note, with: .color(s.noteColor.opacity(0.7)), lineWidth: 1)

        // ── The exact pitch, dashed in whichever of black and white the note's
        // colour lets it be seen in ──────────────────────────────────────────
        var centre = Path()
        centre.move(to: CGPoint(x: noteRect.minX + radius / 2, y: midY))
        centre.addLine(to: CGPoint(x: noteRect.maxX - radius / 2, y: midY))
        ctx.stroke(centre, with: .color(Self.isLight(s.noteColor) ? .black.opacity(0.45) : .white.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

        // ── The average line, broken wherever it has no value ─────────────────
        // Each value stands for its own stretch of the note and is drawn at that
        // stretch's middle; the first and last are carried out to the note's ends.
        let count = path.count
        guard count > 0 else { return }
        var line = Path()
        var penDown = false
        func point(_ x: CGFloat, _ cents: Double) {
            let p = CGPoint(x: x, y: y(cents))
            if penDown { line.addLine(to: p) } else { line.move(to: p); penDown = true }
        }
        for (k, value) in path.enumerated() {
            guard let value else { penDown = false; continue }
            if k == 0 { point(noteRect.minX, value) }
            point(noteRect.minX + (CGFloat(k) + 0.5) / CGFloat(count) * noteRect.width, value)
            if k == count - 1 { point(noteRect.maxX, value) }
        }
        ctx.stroke(line, with: .color(s.singerLineColor),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    /// Whether `color` is light enough that black shows up better on it than white.
    private static func isLight(_ color: Color) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
    }
}
