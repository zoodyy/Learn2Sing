//
//  ScoreHistory.swift
//  Learn2Sing
//
//  Persists every finished run's score per exercise and draws the score-over-time
//  line chart shown on the result screen.
//

import SwiftUI
import UIKit

/// One completed run of an exercise: when it finished and the score it earned.
/// Plain data, so it stays usable from the sorting and mapping closures the
/// profile document is built out of rather than picking up the module's default
/// main-actor isolation.
nonisolated struct ScoreEntry: Codable {
    var date: Date
    var score: Int          // whole-number percentage, 0...100
}

/// Score history storage, kept in UserDefaults under `scores_<uuid>` alongside the
/// exercise list and MIDI patterns that ExerciseStore manages.
enum ScoreHistory {
    nonisolated private static let keyPrefix = "scores_"

    nonisolated static func key(_ id: UUID) -> String { keyPrefix + id.uuidString }

    nonisolated static func entries(for id: UUID) -> [ScoreEntry] {
        guard let data = UserDefaults.standard.data(forKey: key(id)),
              let saved = try? JSONDecoder().decode([ScoreEntry].self, from: data)
        else { return [] }
        return saved
    }

    /// Appends a finished run. A 0% score is a silent or abandoned run, not a real
    /// attempt, so it is never saved.
    static func record(score: Int, for id: UUID, at date: Date = Date()) {
        guard score > 0 else { return }
        var all = entries(for: id)
        all.append(ScoreEntry(date: date, score: score))
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key(id))
        syncChanged()
    }

    /// Whether `score` would beat every run already recorded for this exercise —
    /// the personal record the score screen calls out. Asked before the run is
    /// recorded, since it is about to become part of the history it is measured
    /// against.
    ///
    /// A tie isn't a record, and neither is a first-ever score: with nothing to
    /// have beaten, every exercise would announce one the first time it is sung.
    static func isPersonalRecord(score: Int, for id: UUID) -> Bool {
        guard let best = entries(for: id).map(\.score).max() else { return false }
        return score > best
    }

    static func delete(for id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
        syncChanged()
    }

    /// Wipes every recorded score, including any left behind by exercises that
    /// are no longer in the library. Used by Settings ▸ Reset ▸ Scores.
    static func deleteAll() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
        syncChanged()
    }

    // MARK: - Profile sync

    /// Every recorded history, keyed by exercise UUID string — what the profile
    /// document carries. Histories left behind by deleted exercises are included,
    /// the same ones `deleteAll` clears, so an exercise that comes back from the
    /// server brings its scores with it. Nonisolated, like the reads it is made
    /// of: ProfileSync calls it off the main actor.
    nonisolated static func all() -> [String: [ScoreEntry]] {
        let defaults = UserDefaults.standard
        var histories: [String: [ScoreEntry]] = [:]
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            let idString = String(key.dropFirst(keyPrefix.count))
            guard let id = UUID(uuidString: idString) else { continue }
            let saved = entries(for: id)
            if !saved.isEmpty { histories[idString] = saved }
        }
        return histories
    }

    /// Merges histories restored from the server into whatever this device has.
    /// Runs already on the device are kept — the server copy carries only as much
    /// history as fits the profile document, so it can be the shorter of the two.
    static func merge(_ histories: [String: [ScoreEntry]]) {
        for (idString, remote) in histories {
            guard let id = UUID(uuidString: idString) else { continue }
            var merged = entries(for: id)
            // A run takes seconds to sing, so the second it finished in tells two
            // apart — which is as fine as the restored timestamps get.
            let known = Set(merged.map(second))
            merged.append(contentsOf: remote.filter { !known.contains(second($0)) })
            merged.sort { $0.date < $1.date }
            guard let data = try? JSONEncoder().encode(merged) else { continue }
            UserDefaults.standard.set(data, forKey: key(id))
        }
    }

    private nonisolated static func second(_ entry: ScoreEntry) -> Int {
        Int(entry.date.timeIntervalSince1970.rounded())
    }

    /// Scores ride along in the synced profile, so a change to them needs
    /// uploading just like an exercise edit does — and they are what the
    /// singer's skill level is worked out from, so it moves with them.
    private static func syncChanged() {
        Task { @MainActor in
            SkillLevelStore.shared.recompute()
            ProfileSync.shared.scheduleUpload()
        }
    }
}

/// A score history as the profile document carries it: whole-second timestamps
/// and scores interleaved in one flat array, `[t₀, s₀, t₁, s₁, …]`.
///
/// Histories are the only part of the profile that grows without bound, so they
/// travel as bare numbers — about a third the size the locally stored
/// `ScoreEntry` objects encode to. The second a run finished in is all the chart
/// needs, and the compact form keeps the whole profile, which is re-uploaded on
/// every edit, cheap to send.
nonisolated struct ScoreHistoryDoc: Codable {
    private var values: [Int]

    init(_ entries: [ScoreEntry]) {
        values = entries
            .sorted { $0.date < $1.date }
            .flatMap { [Int($0.date.timeIntervalSince1970.rounded()), $0.score] }
    }

    /// The runs it holds, oldest first. A trailing value without its pair (never
    /// written by this app) is ignored rather than read past.
    var entries: [ScoreEntry] {
        stride(from: 0, to: values.count - 1, by: 2).map { i in
            ScoreEntry(date: Date(timeIntervalSince1970: Double(values[i])), score: values[i + 1])
        }
    }

    init(from decoder: Decoder) throws {
        values = try decoder.singleValueContainer().decode([Int].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Time windows the score-history chart can be narrowed to.
enum ScoreRange: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case halfYear = "6m"
    case year = "1y"
    case all = "All"

    var id: String { rawValue }

    /// Window length in seconds, or nil for the full history.
    var duration: TimeInterval? {
        switch self {
        case .day:      24 * 3600
        case .week:     7 * 24 * 3600
        case .month:    30 * 24 * 3600
        case .halfYear: 182 * 24 * 3600
        case .year:     365 * 24 * 3600
        case .all:      nil
        }
    }
}

/// Line chart of an exercise's past scores. The y axis is score in %; the x axis
/// is real time under a fixed window (a day with 100 runs spans no more width
/// than a day with 1) and plain run order under "All", where every run is given
/// the same width and the axis therefore goes unlabelled. Runs that would land
/// on the same x position are averaged into one point, and the lowest 5% of
/// scores in the window are dropped as outliers.
///
/// Tapping a plotted point marks it and shows its score and time in a bubble
/// pointing at it; tapping away from every point puts the bubble away again.
/// The chart itself is `HistoryLineChart`, which the Home tab's practice time
/// is drawn in as well.
struct ScoreHistoryChart: View {
    let entries: [ScoreEntry]
    let tint: Color

    /// The empty period's message is drawn in the chart's own ink rather than a
    /// semantic label colour, so it has to flip with the appearance itself.
    @Environment(\.colorScheme) private var colorScheme

    /// The surface a score chart is drawn on: the black it was designed against
    /// in dark mode, and a light card in light mode. Shared by the result screen
    /// (full-bleed) and the exercise intro screen's card, so the chart reads the
    /// same in both.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(.secondarySystemBackground)
    }

    /// Everything the chart draws on top of `surface`, in the colour that
    /// contrasts with it.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    @State private var range: ScoreRange = .all

    /// The tapped point (see `HistoryLineChart.selectedDate`), held here so a
    /// change of window can put it away.
    @State private var selectedDate: Date?

    /// Upper bound on plotted points: the window is split into this many equal
    /// time slots and runs sharing a slot are averaged together.
    private let maxPoints = 60

    var body: some View {
        VStack(spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(ScoreRange.allCases) { r in
                    Text(L(r.rawValue)).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .explain(L("How far back the chart looks, from the last day to everything you have sung."))

            let visible = points
            if visible.isEmpty {
                Text("No scores in this period.")
                    .font(.subheadline)
                    .foregroundStyle(ink.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 120)
                    .explain(L("Your scores for this exercise over time. Nothing was sung in the period picked above."))
            } else {
                let window = dateWindow
                HistoryLineChart(points: plottedPoints(visible),
                                 xDomain: xDomain(window: window, count: visible.count),
                                 dateWindow: window,
                                 valueName: L("Score"),
                                 yDomain: 0...100,
                                 yTicks: [0, 25, 50, 75, 100],
                                 yLabel: { "\(Int($0))%" },
                                 dateStyle: .dateTime.day().month(.abbreviated).year()
                                    .hour().minute(),
                                 tint: tint,
                                 selectedDate: $selectedDate)
                    // Time runs left to right here in every language, as it does
                    // across the notes. The point marker and its bubble are placed
                    // with `.position`, which a mirrored app would measure from the
                    // right, away from the point the chart reports.
                    .environment(\.layoutDirection, .leftToRight)
                    .explain(L("Your scores for this exercise over time, oldest on the left. Tap a point to see its score and date."))
            }
        }
        // A different window plots different points, so whatever was selected in
        // the old one no longer has a mark to point at.
        .onChange(of: range) { selectedDate = nil }
    }

    /// The stretch of time a fixed window covers: exactly its duration up to
    /// now, so the line sits where it happened inside the window. Nil for "All",
    /// which lays its runs out by order rather than by time.
    private var dateWindow: ClosedRange<Date>? {
        guard let duration = range.duration else { return nil }
        let now = Date()
        return now.addingTimeInterval(-duration)...now
    }

    /// The x scale the marks are plotted against: seconds for a fixed window,
    /// run positions (0, 1, 2, …) for "All", which puts the first and last of
    /// `count` runs on the plot's edges with the rest evenly spread between them.
    private func xDomain(window: ClosedRange<Date>?, count: Int) -> ClosedRange<Double> {
        if let window {
            return window.lowerBound.timeIntervalSinceReferenceDate
                ... window.upperBound.timeIntervalSinceReferenceDate
        }
        // A lone run has no spacing to speak of, so it sits in the middle of an
        // arbitrary window rather than in a zero-wide one.
        guard count > 1 else { return -1...1 }
        return 0...Double(count - 1)
    }

    /// `visible` placed on the x scale. A fixed window puts every run at the
    /// time it happened, so runs minutes apart nearly overlap; "All" gives each
    /// run the same width instead, so three of them are three equal steps apart
    /// whether they came minutes or months after one another.
    private func plottedPoints(_ visible: [ScoreEntry]) -> [HistoryChartPoint] {
        visible.enumerated().map { index, entry in
            HistoryChartPoint(date: entry.date,
                              x: range.duration == nil
                                  ? Double(index) : entry.date.timeIntervalSinceReferenceDate,
                              value: Double(entry.score),
                              valueText: "\(entry.score)%")
        }
    }

    /// The runs the chart draws, oldest first: window → drop the lowest 5% of
    /// scores → average them down to at most `maxPoints` groups.
    private var points: [ScoreEntry] {
        var visible = entries
        if let duration = range.duration {
            let start = Date().addingTimeInterval(-duration)
            visible = visible.filter { $0.date >= start }
        }
        visible.sort { $0.date < $1.date }

        let drop = visible.count / 20
        if drop > 0 {
            let lowest = Set(visible.indices
                .sorted { visible[$0].score < visible[$1].score }
                .prefix(drop))
            visible = visible.indices.filter { !lowest.contains($0) }.map { visible[$0] }
        }

        guard visible.count > maxPoints else { return visible }

        // Runs are gathered into groups and each group averaged into one point.
        // A fixed window groups equal stretches of time, keeping the line's
        // shape; "All" groups equal numbers of runs, since there every run is
        // given the same width and an evening of practice must not shrink to a
        // single point just because it was over quickly.
        let groups: [[ScoreEntry]]
        if range.duration == nil {
            groups = (0..<maxPoints).map { i in
                // Never empty: there are more runs than groups.
                Array(visible[(i * visible.count / maxPoints)
                              ..< ((i + 1) * visible.count / maxPoints)])
            }
        } else {
            guard let first = visible.first, let last = visible.last,
                  last.date > first.date
            else { return visible }

            let slotLength = last.date.timeIntervalSince(first.date) / Double(maxPoints)
            var slots: [Int: [ScoreEntry]] = [:]
            for entry in visible {
                let slot = min(maxPoints - 1,
                               Int(entry.date.timeIntervalSince(first.date) / slotLength))
                slots[slot, default: []].append(entry)
            }
            groups = slots.keys.sorted().map { slots[$0]! }
        }

        return groups.map { group in
            let meanScore = group.reduce(0) { $0 + $1.score } / group.count
            let meanTime = group.reduce(0.0) { $0 + $1.date.timeIntervalSince1970 }
                / Double(group.count)
            return ScoreEntry(date: Date(timeIntervalSince1970: meanTime), score: meanScore)
        }
    }
}

/// Rounded rectangle with a triangular tail on one of the horizontal edges,
/// drawn as a single outline so it fills and strokes as one shape.
///
/// `rect` covers the tail as well: the body is inset by `tailHeight` on the side
/// the tail sticks out of, which is what the matching `.padding` at the call site
/// leaves room for.
///
/// Shared with the Home tab's practice calendar, whose squares put up the same
/// kind of bubble as the history chart's data points.
struct SpeechBubble: Shape {
    /// Where the tail's tip sits horizontally, in the shape's own coordinates.
    /// Clamped to the straight part of the edge, so the tail can't grow out of a
    /// rounded corner when the bubble has slid sideways to stay on screen.
    var tailX: CGFloat
    /// Tail on the top edge (bubble below the point) rather than the bottom.
    var tailPointsUp: Bool
    var tailHeight: CGFloat
    var tailWidth: CGFloat = 13
    var cornerRadius: CGFloat = 9

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX,
                          y: tailPointsUp ? rect.minY + tailHeight : rect.minY,
                          width: rect.width,
                          height: max(rect.height - tailHeight, 0))
        let r = min(cornerRadius, min(body.width, body.height) / 2)
        let tip = min(max(tailX, body.minX + r + tailWidth / 2),
                      max(body.maxX - r - tailWidth / 2, body.minX + r + tailWidth / 2))

        var path = Path()
        // Clockwise from the top-left corner, cutting the tail into whichever
        // horizontal edge it belongs on.
        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if tailPointsUp {
            path.addLine(to: CGPoint(x: tip - tailWidth / 2, y: body.minY))
            path.addLine(to: CGPoint(x: tip, y: rect.minY))
            path.addLine(to: CGPoint(x: tip + tailWidth / 2, y: body.minY))
        }
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.minY + r), radius: r,
                    startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(center: CGPoint(x: body.maxX - r, y: body.maxY - r), radius: r,
                    startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        if !tailPointsUp {
            path.addLine(to: CGPoint(x: tip + tailWidth / 2, y: body.maxY))
            path.addLine(to: CGPoint(x: tip, y: rect.maxY))
            path.addLine(to: CGPoint(x: tip - tailWidth / 2, y: body.maxY))
        }
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.maxY - r), radius: r,
                    startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(center: CGPoint(x: body.minX + r, y: body.minY + r), radius: r,
                    startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}
