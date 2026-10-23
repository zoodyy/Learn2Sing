//
//  HistoryLineChart.swift
//  Learn2Sing
//
//  The line chart the app draws a history in: an exercise's scores over time
//  (ScoreHistoryChart) and the time sung on each day (PracticeTimeChart). One
//  view for both, so the two can't drift apart in how they look.
//

import SwiftUI
import Charts
import UIKit

/// One point of a `HistoryLineChart`: when it happened, where it goes along the
/// x scale, its value, and that value written out for the bubble and VoiceOver.
struct HistoryChartPoint {
    let date: Date
    /// Where the point sits on the x scale: the date's seconds for a chart laid
    /// out along time, or a plain position for one laid out by order.
    let x: Double
    let value: Double
    let valueText: String
    /// What the bubble and VoiceOver say in place of `date` written in the
    /// chart's `dateStyle`, for a point that stands for a stretch of time rather
    /// than one moment: the practice chart's runs of several days.
    var dateText: String? = nil
}

/// The chart itself, without anything around it: the line through `points`,
/// the y axis down the leading edge, and the x axis labelled with round dates
/// and times that fit the measured plot. Whoever draws it decides what is
/// plotted, and what is written while there is nothing to plot.
///
/// Tapping a plotted point marks it and shows its value and date in a bubble
/// pointing at it; tapping away from every point puts the bubble away again.
struct HistoryLineChart: View {
    /// Oldest first, at most one per date: the chart keys its marks by date.
    let points: [HistoryChartPoint]
    let xDomain: ClosedRange<Double>
    /// The stretch of time the x axis spans, which its labels are written for;
    /// nil for a chart laid out by order rather than along time, where a
    /// position on the axis stands for no moment and nothing is written under it.
    let dateWindow: ClosedRange<Date>?
    /// What the y axis measures, as Audio Graphs names it.
    let valueName: String
    let yDomain: ClosedRange<Double>
    /// Where the y axis is labelled, and what it says there.
    let yTicks: [Double]
    let yLabel: (Double) -> String
    /// How a point's date is written in its bubble, and read out by VoiceOver,
    /// unless the point brings its own `dateText`.
    let dateStyle: Date.FormatStyle
    /// Whether the x axis may count in hours and minutes. False for a chart of
    /// whole days, where a tick between two of them would stand for nothing.
    var labelsTimesOfDay = true
    let tint: Color

    /// The tapped point, held by date rather than by index because the points
    /// are handed over afresh on every redraw. Held by whoever draws the chart,
    /// which knows when what it plots has changed underneath the selection.
    @Binding var selectedDate: Date?

    /// The chart draws its own axes and bubble rather than using the semantic
    /// label colours, so it has to flip them with the appearance itself.
    @Environment(\.colorScheme) private var colorScheme

    /// The language dates are written in, which the axis also measures them in,
    /// so what it fits is what actually gets drawn.
    @Environment(\.locale) private var locale

    /// Everything the chart draws on top of its surface — axis lines, labels,
    /// the selection ring — in the colour that contrasts with it.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    /// Measured size of the bubble, needed to place it above the point and keep
    /// it inside the chart. Zero until the first layout pass, which is why the
    /// bubble stays hidden that long.
    @State private var bubbleSize: CGSize = .zero

    /// Measured width of the plot, which is what decides how many x axis labels
    /// can stand side by side. Zero until the first layout pass, and the axis
    /// goes without labels that long rather than guessing at a width.
    @State private var plotWidth: CGFloat = 0

    /// How far from a point a tap still counts as hitting it. A comfortable
    /// touch target, and doubles as the "tapped nothing" threshold that
    /// dismisses the bubble.
    private let hitRadius: CGFloat = 44

    var body: some View {
        // Dots make sparse history readable (and a lone point visible at all,
        // since a single LineMark draws nothing); dense lines skip them.
        let showsDots = points.count <= 30
        Chart(points, id: \.date) { p in
            LineMark(x: .value("Time", p.x), y: .value(valueName, p.value))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                // The x value is a plotting position rather than a date, so the
                // point's own date is spelled out for VoiceOver instead.
                .accessibilityLabel(dateText(p))
                .accessibilityValue(Text(verbatim: p.valueText))
            if showsDots {
                PointMark(x: .value("Time", p.x), y: .value(valueName, p.value))
                    .foregroundStyle(tint)
                    .symbolSize(30)
            }
        }
        .chartYScale(domain: yDomain)
        .chartXScale(domain: xDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine().foregroundStyle(ink.opacity(0.15))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(verbatim: yLabel(v)) }
                }
                .font(Self.axisLabelStyle)
                .foregroundStyle(ink.opacity(0.5))
            }
        }
        .chartXAxis {
            let ticks = xAxisTicks
            if ticks.isEmpty {
                // A chart laid out by order has nothing truthful to write under
                // the plot, but the row a label would have taken is still
                // reserved — an unwritten one, holding the space open. Otherwise
                // the plot would grow into it and the chart would change size
                // with what it shows.
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
                        // The placement is the chart's own default, spelled out
                        // because `AxisTick` measures the label as drawn there.
                        AxisValueLabel(anchor: .topLeading,
                                       collisionResolution: .disabled,
                                       horizontalSpacing: Self.labelInset) {
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
        .frame(minHeight: 120)
    }

    // MARK: - X axis

    /// Font the axis labels are drawn in — and measured in, when working out how
    /// many of them fit next to each other.
    private static let axisLabelStyle: Font = .caption
    private static var axisLabelFont: UIFont { .preferredFont(forTextStyle: .caption1) }

    /// Smallest gap left between two neighbouring x axis labels.
    private static let labelGap: CGFloat = 10

    /// How far after its tick an x axis label starts: the 4 points the chart
    /// leaves by default (measured on iOS 26.2), passed to every label so the
    /// one number decides both where it is drawn and where it is measured.
    private static let labelInset: CGFloat = 4

    /// A tick on the x axis: what it says, and where it and its label land along
    /// the plot.
    private struct AxisTick {
        /// Where the tick sits on the x scale — the same kind of value the marks
        /// are plotted at.
        let x: Double
        let label: String
        /// Where the tick lands across the plot, from its leading edge.
        let position: CGFloat
        let width: CGFloat

        /// The chart writes a label after its tick rather than centred under
        /// it, so the whole of the label's width lies to the right of the tick.
        var leading: CGFloat { position + HistoryLineChart.labelInset }
        var trailing: CGFloat { leading + width }
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
        guard let domain = dateWindow else { return [] }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard plotWidth > 0, span > 0 else { return [] }

        let calendar = Calendar.current
        let font = Self.axisLabelFont
        let spansYears = calendar.component(.year, from: domain.lowerBound)
            != calendar.component(.year, from: domain.upperBound)

        var widest: [AxisTick] = []
        // Spacings that would fill the window with ticks cannot fit their labels
        // whatever those say, so they are passed over unbuilt — and so are
        // spacings shorter than a day on a chart of whole days.
        for step in Self.axisSteps
        where span / step.length <= 30 && (labelsTimesOfDay || !step.isTimeOfDay) {
            let format = step.labelFormat(span: span, spansYears: spansYears).locale(locale)
            let ticks = step.ticks(in: domain, calendar: calendar).map { date -> AxisTick in
                let label = format.format(date)
                return AxisTick(
                    x: date.timeIntervalSinceReferenceDate,
                    label: label,
                    position: plotWidth * date.timeIntervalSince(domain.lowerBound) / span,
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

    /// `ticks` with any whose label would hang over the plot's trailing edge
    /// dropped — only those at the right-hand end can, since every label runs
    /// on to the right of its tick — or nil when what is left still crowds
    /// together. A label hanging over would be cut off wherever the chart's
    /// surroundings clip, as the Time Spent Singing screen's list row does.
    private func fitted(_ ticks: [AxisTick]) -> [AxisTick]? {
        let inside = ticks.filter { $0.trailing <= plotWidth }
        for (left, right) in zip(inside, inside.dropFirst())
        where right.leading - left.trailing < Self.labelGap {
            return nil
        }
        return inside
    }

    // MARK: - Point selection

    /// A plotted point together with where it ended up on screen.
    private struct MarkPosition {
        let point: HistoryChartPoint
        let position: CGPoint
    }

    /// Screen position of every plotted point, in the coordinate space of the
    /// overlay's `GeometryReader`.
    private func markPositions(proxy: ChartProxy, in geo: GeometryProxy) -> [MarkPosition] {
        guard let plotAnchor = proxy.plotFrame else { return [] }
        let plot = geo[plotAnchor]
        return points.compactMap { p in
            guard let x = proxy.position(forX: p.x),
                  let y = proxy.position(forY: p.value)
            else { return nil }
            return MarkPosition(point: p,
                                position: CGPoint(x: plot.minX + x, y: plot.minY + y))
        }
    }

    /// The tap target laid over the plot, plus the marker and bubble for the
    /// point that is currently selected.
    private func selectionLayer(marks: [MarkPosition], size: CGSize) -> some View {
        let selected = selectedDate.flatMap { date in
            marks.first { $0.point.date == date }
        }
        return ZStack {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let hit = nearestMark(to: location, among: marks)
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedDate = hit?.point.date
                    }
                }

            if let selected {
                marker.position(selected.position)
                bubble(for: selected.point, at: selected.position, in: size)
            }
        }
    }

    /// A point's date as its bubble writes it and VoiceOver reads it.
    private func dateText(_ point: HistoryChartPoint) -> Text {
        if let text = point.dateText {
            Text(verbatim: text)
        } else {
            Text(point.date, format: dateStyle)
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

    /// The bubble itself: value and date, with its tail on the selected point.
    /// It sits above the point when there is room and flips below when there
    /// isn't, and slides sideways to stay inside the chart — the tail follows,
    /// so it keeps pointing at the point either way.
    private func bubble(for point: HistoryChartPoint, at position: CGPoint,
                        in size: CGSize) -> some View {
        let tailHeight: CGFloat = 7
        let gap: CGFloat = 7          // clearance between the marker and the tail tip
        let inset: CGFloat = 2        // keeps the bubble off the chart's own edges
        let pointsUp = position.y - gap - bubbleSize.height < 0
        let top = pointsUp ? position.y + gap : position.y - gap - bubbleSize.height
        let centerX = min(max(position.x, bubbleSize.width / 2 + inset),
                          max(size.width - bubbleSize.width / 2 - inset,
                              bubbleSize.width / 2 + inset))
        let shape = SpeechBubble(tailX: position.x - (centerX - bubbleSize.width / 2),
                                 tailPointsUp: pointsUp,
                                 tailHeight: tailHeight)

        return VStack(spacing: 1) {
            Text(verbatim: point.valueText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            dateText(point)
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
}

/// One of the spacings the history chart's x axis picks its ticks from: a
/// calendar unit, and how many of it stand between one tick and the next.
private struct AxisStep {
    let unit: Calendar.Component
    let count: Int

    init(_ unit: Calendar.Component, _ count: Int) {
        self.unit = unit
        self.count = count
    }

    /// Whether the step is shorter than a day, so that its ticks fall at times
    /// of day rather than on whole days.
    var isTimeOfDay: Bool { unit == .minute || unit == .hour }

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
