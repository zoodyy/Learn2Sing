//
//  ScoreHistory.swift
//  Learn2Sing
//
//  Persists every finished run's score per exercise and draws the score-over-time
//  line chart shown on the result screen.
//

import SwiftUI
import Charts
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
    private static let keyPrefix = "scores_"

    static func key(_ id: UUID) -> String { keyPrefix + id.uuidString }

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
    /// server brings its scores with it.
    static func all() -> [String: [ScoreEntry]] {
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
struct ScoreHistoryChart: View {
    let entries: [ScoreEntry]
    let tint: Color

    /// The chart draws its own axes and bubble rather than using the semantic
    /// label colours, so it has to flip them with the appearance itself.
    @Environment(\.colorScheme) private var colorScheme

    /// The language dates are written in, which the axis also measures them in,
    /// so what it fits is what actually gets drawn.
    @Environment(\.locale) private var locale

    /// The surface a score chart is drawn on: the black it was designed against
    /// in dark mode, and a light card in light mode. Shared by the result screen
    /// (full-bleed) and the exercise intro screen's card, so the chart reads the
    /// same in both.
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(.secondarySystemBackground)
    }

    /// Everything the chart draws on top of `surface` — axis lines, labels, the
    /// selection ring — in the colour that contrasts with it.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    @State private var range: ScoreRange = .all

    /// The tapped point, held by date rather than by index because `points` is
    /// recomputed on every redraw (the chart keys its marks by date too, and the
    /// averaging below leaves one point per slot, so dates stay unique).
    @State private var selectedDate: Date?

    /// Measured size of the bubble, needed to place it above the point and keep
    /// it inside the chart. Zero until the first layout pass, which is why the
    /// bubble stays hidden that long.
    @State private var bubbleSize: CGSize = .zero

    /// Measured width of the plot, which is what decides how many x axis labels
    /// can stand side by side. Zero until the first layout pass, and the axis
    /// goes without labels that long rather than guessing at a width.
    @State private var plotWidth: CGFloat = 0

    /// Upper bound on plotted points: the window is split into this many equal
    /// time slots and runs sharing a slot are averaged together.
    private let maxPoints = 60

    /// How far from a point a tap still counts as hitting it. A comfortable
    /// touch target, and doubles as the "tapped nothing" threshold that
    /// dismisses the bubble.
    private let hitRadius: CGFloat = 44

    var body: some View {
        VStack(spacing: 10) {
            Picker("Range", selection: $range) {
                ForEach(ScoreRange.allCases) { r in
                    Text(L(r.rawValue)).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .explain(L("How far back the chart looks, from the last day to everything you have sung."))

            if points.isEmpty {
                Text("No scores in this period")
                    .font(.subheadline)
                    .foregroundStyle(ink.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 120)
                    .explain(L("Your scores for this exercise over time. Nothing was sung in the period picked above."))
            } else {
                chart
                    .explain(L("Your scores for this exercise over time, oldest on the left. Tap a point to see its score and date."))
            }
        }
    }

    private var chart: some View {
        let plotted = plottedPoints
        // Dots make sparse history readable (and a lone run visible at all,
        // since a single LineMark draws nothing); dense lines skip them.
        let showsDots = plotted.count <= 30
        return Chart(plotted, id: \.entry.date) { p in
            LineMark(x: .value("Time", p.x), y: .value("Score", p.entry.score))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                // The x value is a plotting position rather than a date, so the
                // run's own time is spelled out for VoiceOver instead.
                .accessibilityLabel(Text(p.entry.date, format: .dateTime.day()
                    .month(.abbreviated).year().hour().minute()))
                .accessibilityValue(Text(verbatim: "\(p.entry.score)%"))
            if showsDots {
                PointMark(x: .value("Time", p.x), y: .value("Score", p.entry.score))
                    .foregroundStyle(tint)
                    .symbolSize(30)
            }
        }
        .chartYScale(domain: 0...100)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine().foregroundStyle(ink.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Int.self) { Text(verbatim: "\(v)%") }
                }
                .font(Self.axisLabelStyle)
                .foregroundStyle(ink.opacity(0.5))
            }
        }
        .chartXAxis {
            let ticks = xAxisTicks
            if ticks.isEmpty {
                // "All" has nothing truthful to write under the plot, but the
                // row a label would have taken is still reserved — an unwritten
                // one, holding the space open. Otherwise the plot would grow
                // into it and the chart would change size with the range.
                AxisMarks(values: [xDomain.lowerBound]) { _ in
                    AxisValueLabel(collisionResolution: .disabled) {
                        Text(verbatim: "0").hidden()
                    }
                    .font(Self.axisLabelStyle)
                }
            } else {
                AxisMarks(values: ticks.map(\.x)) { value in
                    AxisGridLine().foregroundStyle(ink.opacity(0.15))
                    if ticks.indices.contains(value.index) {
                        // These are already spaced to clear each other, and the
                        // chart's own collision handling would only slide the
                        // outermost label sideways off the tick it belongs to.
                        AxisValueLabel(collisionResolution: .disabled) {
                            Text(verbatim: ticks[value.index].label)
                        }
                        .font(Self.axisLabelStyle)
                        .foregroundStyle(ink.opacity(0.5))
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: {
                plotWidth = $0
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                selectionLayer(marks: markPositions(proxy: proxy, in: geo),
                               size: geo.size)
            }
        }
        // A different window plots different points, so whatever was selected in
        // the old one no longer has a mark to point at.
        .onChange(of: range) { selectedDate = nil }
        .frame(minHeight: 120)
    }

    // MARK: - X axis

    /// Font the axis labels are drawn in — and measured in, when working out how
    /// many of them fit next to each other.
    private static let axisLabelStyle: Font = .caption
    private static var axisLabelFont: UIFont { .preferredFont(forTextStyle: .caption1) }

    /// Smallest gap left between two neighbouring x axis labels.
    private static let labelGap: CGFloat = 10

    /// A tick on the x axis: what it says, and where it and its label land along
    /// the plot.
    private struct AxisTick {
        /// Where the tick sits on the x scale — the same kind of value the marks
        /// are plotted at.
        let x: Double
        let label: String
        let center: CGFloat
        let width: CGFloat

        var leading: CGFloat { center - width / 2 }
        var trailing: CGFloat { center + width / 2 }
    }

    /// Spacings the x axis picks its ticks from, closest together first.
    private static let axisSteps: [AxisStep] = [
        AxisStep(.minute, 1), AxisStep(.minute, 2), AxisStep(.minute, 5),
        AxisStep(.minute, 10), AxisStep(.minute, 15), AxisStep(.minute, 30),
        AxisStep(.hour, 1), AxisStep(.hour, 2), AxisStep(.hour, 3),
        AxisStep(.hour, 6), AxisStep(.hour, 12),
        AxisStep(.day, 1), AxisStep(.day, 2),
        AxisStep(.weekOfYear, 1), AxisStep(.weekOfYear, 2),
        AxisStep(.month, 1), AxisStep(.month, 3), AxisStep(.month, 6),
        AxisStep(.year, 1), AxisStep(.year, 2), AxisStep(.year, 5), AxisStep(.year, 10),
    ]

    /// What gets written under the plot: the closest spacing whose labels all fit
    /// across the measured plot without touching. Since a tick less than a day
    /// apart from the next has to name the time and one a day or more apart does
    /// not, climbing to a wider spacing drops the times first and then thins the
    /// dates out — every second day, every week, every month — until they fit.
    ///
    /// Empty until the plot has been measured, so no label is drawn in a place
    /// that is about to move.
    private var xAxisTicks: [AxisTick] {
        // "All" spaces its runs evenly, so a position along the axis no longer
        // stands for a moment in time and there is nothing truthful to write
        // under it.
        guard let domain = dateWindow else { return [] }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard plotWidth > 0, span > 0 else { return [] }

        let calendar = Calendar.current
        let font = Self.axisLabelFont
        let spansYears = calendar.component(.year, from: domain.lowerBound)
            != calendar.component(.year, from: domain.upperBound)

        var widest: [AxisTick] = []
        // Spacings that would fill the window with ticks cannot fit their labels
        // whatever those say, so they are passed over unbuilt.
        for step in Self.axisSteps where span / step.length <= 30 {
            let format = step.labelFormat(span: span, spansYears: spansYears).locale(locale)
            let ticks = step.ticks(in: domain, calendar: calendar).map { date -> AxisTick in
                let label = format.format(date)
                return AxisTick(
                    x: date.timeIntervalSinceReferenceDate,
                    label: label,
                    center: plotWidth * date.timeIntervalSince(domain.lowerBound) / span,
                    width: label.size(withAttributes: [.font: font]).width)
            }
            if let fitted = fitted(ticks), !fitted.isEmpty { return fitted }
            // A spacing so wide that the window holds no round point of it at
            // all leaves nothing to draw, so it is no reason to stop climbing.
            if ticks.count > 1 { widest = ticks }
        }
        // Even the widest spacing that had ticks crowds a plot this narrow: keep
        // every second one of them, then every third, until they have room.
        guard widest.count > 1 else { return [] }
        for keepEvery in 2...widest.count {
            let thinned = widest.enumerated().filter { $0.offset % keepEvery == 0 }.map(\.element)
            if let fitted = fitted(thinned) { return fitted }
        }
        return []
    }

    /// `ticks` with any whose label would hang over an edge of the plot dropped —
    /// only the outermost ever can — or nil when what is left still crowds
    /// together.
    private func fitted(_ ticks: [AxisTick]) -> [AxisTick]? {
        let inside = ticks.filter { $0.leading >= 0 && $0.trailing <= plotWidth }
        for (left, right) in zip(inside, inside.dropFirst())
        where right.leading - left.trailing < Self.labelGap {
            return nil
        }
        return inside
    }

    // MARK: - Point selection

    /// A plotted point together with where it ended up on screen.
    private struct MarkPosition {
        let entry: ScoreEntry
        let position: CGPoint
    }

    /// Screen position of every plotted point, in the coordinate space of the
    /// overlay's `GeometryReader`.
    private func markPositions(proxy: ChartProxy, in geo: GeometryProxy) -> [MarkPosition] {
        guard let plotAnchor = proxy.plotFrame else { return [] }
        let plot = geo[plotAnchor]
        return plottedPoints.compactMap { p in
            guard let x = proxy.position(forX: p.x),
                  let y = proxy.position(forY: p.entry.score)
            else { return nil }
            return MarkPosition(entry: p.entry,
                                position: CGPoint(x: plot.minX + x, y: plot.minY + y))
        }
    }

    /// The tap target laid over the plot, plus the marker and bubble for the
    /// point that is currently selected.
    private func selectionLayer(marks: [MarkPosition], size: CGSize) -> some View {
        let selected = selectedDate.flatMap { date in
            marks.first { $0.entry.date == date }
        }
        return ZStack {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let hit = nearestMark(to: location, among: marks)
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedDate = hit?.entry.date
                    }
                }

            if let selected {
                marker.position(selected.position)
                bubble(for: selected.entry, at: selected.position, in: size)
            }
        }
    }

    /// The nearest point to a tap, or nil when the tap landed near none of them.
    private func nearestMark(to location: CGPoint, among marks: [MarkPosition]) -> MarkPosition? {
        marks
            .map { ($0, hypot($0.position.x - location.x, $0.position.y - location.y)) }
            .filter { $0.1 <= hitRadius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Ring drawn over the selected point, so it stays identifiable while the
    /// bubble is up (the chart hides its own dots once the line gets dense).
    private var marker: some View {
        Circle()
            .fill(tint)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(ink.opacity(0.9), lineWidth: 2))
            .allowsHitTesting(false)
    }

    /// The bubble itself: score and time, with its tail on the selected point.
    /// It sits above the point when there is room and flips below when there
    /// isn't, and slides sideways to stay inside the chart — the tail follows,
    /// so it keeps pointing at the point either way.
    private func bubble(for entry: ScoreEntry, at point: CGPoint, in size: CGSize) -> some View {
        let tailHeight: CGFloat = 7
        let gap: CGFloat = 7          // clearance between the marker and the tail tip
        let inset: CGFloat = 2        // keeps the bubble off the chart's own edges
        let pointsUp = point.y - gap - bubbleSize.height < 0
        let top = pointsUp ? point.y + gap : point.y - gap - bubbleSize.height
        let centerX = min(max(point.x, bubbleSize.width / 2 + inset),
                          max(size.width - bubbleSize.width / 2 - inset,
                              bubbleSize.width / 2 + inset))
        let shape = SpeechBubble(tailX: point.x - (centerX - bubbleSize.width / 2),
                                 tailPointsUp: pointsUp,
                                 tailHeight: tailHeight)

        return VStack(spacing: 1) {
            Text(verbatim: "\(entry.score)%")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(entry.date, format: .dateTime.day().month(.abbreviated).year()
                                              .hour().minute())
                .font(.caption2)
                .foregroundStyle(ink.opacity(0.7))
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .padding(pointsUp ? .top : .bottom, tailHeight)
        // A shade off the surface either way, so the bubble lifts off the chart
        // without competing with the line for attention.
        .background(shape.fill(Color(white: colorScheme == .dark ? 0.16 : 1.0)))
        .overlay(shape.stroke(tint.opacity(0.8), lineWidth: 1))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
        // Hidden until measured, otherwise the first frame flashes in the
        // wrong place.
        .opacity(bubbleSize == .zero ? 0 : 1)
        .position(x: centerX, y: top + bubbleSize.height / 2)
        // Taps belong to the layer underneath, which dismisses the bubble.
        .allowsHitTesting(false)
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
    /// run positions (0, 1, 2, …) for "All", which puts the first and last runs
    /// on the plot's edges with the rest evenly spread between them.
    private var xDomain: ClosedRange<Double> {
        if let window = dateWindow {
            return window.lowerBound.timeIntervalSinceReferenceDate
                ... window.upperBound.timeIntervalSinceReferenceDate
        }
        // A lone run has no spacing to speak of, so it sits in the middle of an
        // arbitrary window rather than in a zero-wide one.
        guard points.count > 1 else { return -1...1 }
        return 0...Double(points.count - 1)
    }

    /// A plotted run: the score it earned, and where along the x axis it goes.
    private struct PlottedPoint {
        let entry: ScoreEntry
        let x: Double
    }

    /// `points` placed on the x scale. A fixed window puts every run at the time
    /// it happened, so runs minutes apart nearly overlap; "All" gives each run
    /// the same width instead, so three of them are three equal steps apart
    /// whether they came minutes or months after one another.
    private var plottedPoints: [PlottedPoint] {
        let visible = points
        guard range.duration != nil else {
            return visible.enumerated().map { PlottedPoint(entry: $1, x: Double($0)) }
        }
        return visible.map {
            PlottedPoint(entry: $0, x: $0.date.timeIntervalSinceReferenceDate)
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

/// One of the spacings the score chart's x axis picks its ticks from: a calendar
/// unit, and how many of it stand between one tick and the next.
private struct AxisStep {
    let unit: Calendar.Component
    let count: Int

    init(_ unit: Calendar.Component, _ count: Int) {
        self.unit = unit
        self.count = count
    }

    /// Roughly how long the step lasts. Only used to guess how many ticks a
    /// window would hold, before any of them are worked out.
    var length: TimeInterval {
        let unitLength: TimeInterval = switch unit {
        case .minute:     60
        case .hour:       3_600
        case .day:        86_400
        case .weekOfYear: 7 * 86_400
        case .month:      30.44 * 86_400
        default:          365.25 * 86_400
        }
        return unitLength * Double(count)
    }

    /// How a tick of this spacing has to be written for the reader to place it,
    /// in a window `span` seconds wide that does or doesn't run from one calendar
    /// year into the next.
    func labelFormat(span: TimeInterval, spansYears: Bool) -> Date.FormatStyle {
        switch unit {
        // Within a single day the time alone says it; over a longer window the
        // same clock time comes round again, so the date comes with it.
        case .minute, .hour:
            span > 26 * 3_600
                ? .dateTime.day().month(.abbreviated).hour().minute()
                : .dateTime.hour().minute()
        case .day, .weekOfYear:
            spansYears
                ? .dateTime.day().month(.abbreviated).year()
                : .dateTime.day().month(.abbreviated)
        case .month:
            spansYears
                ? .dateTime.month(.abbreviated).year()
                : .dateTime.month(.abbreviated)
        default:
            .dateTime.year()
        }
    }

    /// Every tick of this spacing inside `domain`, counted off from a round point
    /// on the clock or the calendar — a whole hour, a midnight, the first of a
    /// month — rather than from the window's own edge, so the labels come out as
    /// round times and dates.
    func ticks(in domain: ClosedRange<Date>, calendar: Calendar) -> [Date] {
        guard var tick = anchor(for: domain.lowerBound, calendar: calendar) else { return [] }
        var dates: [Date] = []
        // The anchor sits at or before the window, so the first few steps can
        // still fall short of it. Counting the steps rather than the ticks keeps
        // a calendar that refuses to advance from spinning here.
        for _ in 0..<200 {
            if tick > domain.upperBound { break }
            if tick >= domain.lowerBound { dates.append(tick) }
            guard let next = calendar.date(byAdding: unit, value: count, to: tick),
                  next > tick
            else { break }
            tick = next
        }
        return dates
    }

    /// The round point ticks are counted off from: at or before `date`, and
    /// divided evenly by this step, so ticks land on the same positions in every
    /// hour, day, month or year rather than drifting between them.
    private func anchor(for date: Date, calendar: Calendar) -> Date? {
        switch unit {
        case .minute:     return calendar.dateInterval(of: .hour, for: date)?.start
        case .hour:       return calendar.dateInterval(of: .day, for: date)?.start
        case .day:        return calendar.dateInterval(of: .month, for: date)?.start
        case .weekOfYear: return calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case .month:      return calendar.dateInterval(of: .year, for: date)?.start
        default:
            // Years count off from one divisible by the step, so a ten-year
            // spacing lands on the decades.
            guard let yearStart = calendar.dateInterval(of: .year, for: date)?.start else {
                return nil
            }
            let year = calendar.component(.year, from: yearStart)
            return calendar.date(byAdding: .year, value: -(year % count), to: yearStart)
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
/// kind of bubble as this chart's data points.
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
