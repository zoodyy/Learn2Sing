//
//  ScoreHistory.swift
//  Learn2Sing
//
//  Persists every finished run's score per exercise and draws the score-over-time
//  line chart shown on the result screen.
//

import SwiftUI
import Charts

/// One completed run of an exercise: when it finished and the score it earned.
struct ScoreEntry: Codable {
    var date: Date
    var score: Int          // whole-number percentage, 0...100
}

/// Score history storage, kept in UserDefaults under `scores_<uuid>` alongside the
/// exercise list and MIDI patterns that ExerciseStore manages.
enum ScoreHistory {
    static func key(_ id: UUID) -> String { "scores_\(id.uuidString)" }

    static func entries(for id: UUID) -> [ScoreEntry] {
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
    }

    static func delete(for id: UUID) {
        UserDefaults.standard.removeObject(forKey: key(id))
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

/// Line chart of an exercise's past scores. The x axis is real time (a day with
/// 100 runs spans no more width than a day with 1), the y axis is score in %.
/// Runs that would land on the same x position are averaged into one point, and
/// the lowest 5% of scores in the window are dropped as outliers.
struct ScoreHistoryChart: View {
    let entries: [ScoreEntry]
    let tint: Color

    @State private var range: ScoreRange = .all

    /// Upper bound on plotted points: the window is split into this many equal
    /// time slots and runs sharing a slot are averaged together.
    private let maxPoints = 60

    var body: some View {
        VStack(spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(ScoreRange.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)

            if points.isEmpty {
                Text("No scores in this period")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 120)
            } else {
                chart
            }
        }
    }

    private var chart: some View {
        Chart(points, id: \.date) { p in
            LineMark(x: .value("Time", p.date), y: .value("Score", p.score))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            // Dots make sparse history readable (and a lone run visible at all,
            // since a single LineMark draws nothing); dense lines skip them.
            if points.count <= 30 {
                PointMark(x: .value("Time", p.date), y: .value("Score", p.score))
                    .foregroundStyle(tint)
                    .symbolSize(30)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text("\(v)%") }
                }
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.white.opacity(0.15))
                AxisValueLabel()
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(minHeight: 120)
    }

    /// Fixed windows always span exactly their duration up to now, so the line sits
    /// where it happened inside the window; "All" hugs the recorded history.
    private var xDomain: ClosedRange<Date> {
        let now = Date()
        if let duration = range.duration {
            return now.addingTimeInterval(-duration)...now
        }
        guard let first = points.first?.date, let last = points.last?.date, first < last else {
            let center = points.first?.date ?? now
            return center.addingTimeInterval(-3600)...center.addingTimeInterval(3600)
        }
        return first...last
    }

    /// The plotted points: window → drop the lowest 5% of scores → average runs
    /// that share one of `maxPoints` equal time slots.
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

        guard visible.count > maxPoints,
              let first = visible.first, let last = visible.last,
              last.date > first.date
        else { return visible }

        let slotLength = last.date.timeIntervalSince(first.date) / Double(maxPoints)
        var slots: [Int: [ScoreEntry]] = [:]
        for entry in visible {
            let slot = min(maxPoints - 1,
                           Int(entry.date.timeIntervalSince(first.date) / slotLength))
            slots[slot, default: []].append(entry)
        }
        return slots.keys.sorted().map { slot in
            let group = slots[slot]!
            let meanScore = group.reduce(0) { $0 + $1.score } / group.count
            let meanTime = group.reduce(0.0) { $0 + $1.date.timeIntervalSince1970 }
                / Double(group.count)
            return ScoreEntry(date: Date(timeIntervalSince1970: meanTime), score: meanScore)
        }
    }
}
