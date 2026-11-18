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
/// Dragging a finger across the chart moves the bubble from point to point by
/// how far along the plot the finger is, whatever its height, and leaves it on
/// the last one when the finger lifts.
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

    /// The chart draws its own axes rather than using the semantic label
    /// colours, so it has to flip them with the appearance itself.
    @Environment(\.colorScheme) private var colorScheme

    /// The language dates are written in, which the axis also measures them in,
    /// so what it fits is what actually gets drawn.
    @Environment(\.locale) private var locale

    /// Everything the chart draws on top of its surface — axis lines, labels,
    /// and over in HistoryChartSelection the selection ring — in the colour
    /// that contrasts with it.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    /// Measured width of the plot, which is what decides how many x axis labels
    /// can stand side by side. Zero until the first layout pass, and the axis
    /// goes without labels that long rather than guessing at a width.
    @State private var plotWidth: CGFloat = 0

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
                .accessibilityLabel(p.writtenDate(dateStyle))
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
                HistoryChartSelection(marks: markPositions(proxy: proxy, in: geo),
                                      size: geo.size,
                                      dateStyle: dateStyle,
                                      tint: tint,
                                      selectedDate: $selectedDate)
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

    /// Screen position of every plotted point, in the coordinate space of the
    /// overlay's `GeometryReader`, along with where a drag across the plot picks
    /// it up (`HistoryChartMark.dragX`).
    private func markPositions(proxy: ChartProxy, in geo: GeometryProxy) -> [HistoryChartMark] {
        guard let plotAnchor = proxy.plotFrame else { return [] }
        let plot = geo[plotAnchor]
        let placed = points.compactMap { p -> (point: HistoryChartPoint, position: CGPoint)? in
            guard let x = proxy.position(forX: p.x),
                  let y = proxy.position(forY: p.value)
            else { return nil }
            return (p, CGPoint(x: plot.minX + x, y: plot.minY + y))
        }
        let dragXs = Self.dragPositions(of: placed.map(\.position.x),
                                        within: plot.minX...plot.maxX)
        return zip(placed, dragXs).map { placed, dragX in
            HistoryChartMark(point: placed.point, position: placed.position, dragX: dragX)
        }
    }

    /// The least room across the plot a drag gives each point, in points. About
    /// a dot's width, a little more than a full chart of points gets anyway:
    /// enough for the finger to stop on each of a stack of runs in turn, while
    /// a crowd of them is spread no further from where it is drawn than it has
    /// to be.
    private static let dragSpacing: CGFloat = 6

    /// Where a drag picks up each of the points at `xs` (oldest first, so
    /// left to right): at each point's own x, except where points crowd closer
    /// together than `dragSpacing`, as runs sung minutes apart do in a window a
    /// year wide. Those are spread apart to that spacing, centred on where they
    /// are, so a finger swept across them meets each in turn, oldest first. A
    /// spread that would run past the end of the plot is packed against it
    /// instead, so a finger can still reach every point. When even that leaves
    /// too little room, the spacing shrinks to what the plot can give them all.
    private static func dragPositions(of xs: [CGFloat],
                                      within bounds: ClosedRange<CGFloat>) -> [CGFloat] {
        let count = xs.count
        guard count > 1 else { return xs }
        let spacing = min(dragSpacing,
                          (bounds.upperBound - bounds.lowerBound) / CGFloat(count - 1))
        // Spaced out, the positions less each one's share of the spacing
        // (i × spacing) never decrease. The closest such sequence to where the
        // points are drawn averages each run of points that would otherwise
        // overlap, merging runs until none does (pool adjacent violators).
        var runs: [(sum: CGFloat, count: Int)] = []
        for (index, x) in xs.enumerated() {
            runs.append((x - CGFloat(index) * spacing, 1))
            while runs.count > 1 {
                let last = runs[runs.count - 1]
                let previous = runs[runs.count - 2]
                guard previous.sum / CGFloat(previous.count) > last.sum / CGFloat(last.count)
                else { break }
                runs.removeLast(2)
                runs.append((previous.sum + last.sum, previous.count + last.count))
            }
        }
        var positions: [CGFloat] = []
        for run in runs {
            let start = run.sum / CGFloat(run.count)
            for _ in 0..<run.count {
                positions.append(start + CGFloat(positions.count) * spacing)
            }
        }
        // Each point kept no nearer an end than the points beyond it need,
        // which leaves the spacing between them as it was.
        return positions.enumerated().map { index, x in
            min(max(x, bounds.lowerBound + CGFloat(index) * spacing),
                bounds.upperBound - CGFloat(count - 1 - index) * spacing)
        }
    }
}

/// A plotted point together with where it ended up on screen.
private struct HistoryChartMark {
    let point: HistoryChartPoint
    let position: CGPoint
    /// Where along the plot a dragging finger picks this point up: its own x,
    /// unless it sits closer to its neighbours than a finger can tell apart
    /// (see `HistoryLineChart.dragPositions`).
    let dragX: CGFloat
}

extension HistoryChartPoint {
    /// The point's date as its bubble writes it and VoiceOver reads it.
    fileprivate func writtenDate(_ style: Date.FormatStyle) -> Text {
        if let dateText {
            Text(verbatim: dateText)
        } else {
            Text(date, format: style)
        }
    }
}

/// What lies over a history chart's plot: the touch surface, plus the marker
/// and bubble for the point that is currently selected.
///
/// A view of its own, so that moving the selection redraws only this and not
/// the chart under it. A drag moves the selection on at every point the finger
/// passes, and redrawing the chart each time, axis labels fitted all over
/// again, cost more than a frame per point.
private struct HistoryChartSelection: View {
    let marks: [HistoryChartMark]
    /// The overlay's size, which the bubble is kept inside.
    let size: CGSize
    let dateStyle: Date.FormatStyle
    let tint: Color
    @Binding var selectedDate: Date?

    /// The bubble and marker are drawn in the chart's own ink, which flips with
    /// the appearance.
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { colorScheme == .dark ? .white : .black }

    /// Measured size of the bubble, needed to place it above the point and keep
    /// it inside the chart. Zero until the first layout pass, which is why the
    /// bubble stays hidden that long.
    @State private var bubbleSize: CGSize = .zero

    /// How far from a point a tap still counts as hitting it. A comfortable
    /// touch target, and doubles as the "tapped nothing" threshold that
    /// dismisses the bubble.
    private let hitRadius: CGFloat = 44

    /// Steps a drag's selection through the points it passes, rather than
    /// letting it jump over them. A reference held in state, so the stepping
    /// redraws nothing until it moves the selection.
    @State private var follower = DragFollower()

    var body: some View {
        let selected = selectedDate.flatMap { date in
            marks.first { $0.point.date == date }
        }
        ZStack {
            ChartTouchSurface(
                onTap: { location in
                    follower.stop()
                    let hit = nearestMark(to: location)
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedDate = hit?.point.date
                    }
                },
                onDrag: { drag in
                    // Straight onto each point, without the tap's animation:
                    // the bubble has to keep up with the finger, not trail it.
                    follower.show = { index in
                        guard marks.indices.contains(index) else { return }
                        let mark = marks[index]
                        guard mark.point.date != selectedDate else { return }
                        selectedDate = mark.point.date
                    }
                    switch drag {
                    case .began(let start, let finger):
                        // The point the finger landed on first: by the time
                        // it has moved far enough to be dragging, it can be
                        // past it and the next one too.
                        follower.jump(to: draggedIndex(at: start.x))
                        follower.follow(to: draggedIndex(at: finger.x))
                    case .moved(let finger), .ended(let finger):
                        follower.follow(to: draggedIndex(at: finger.x))
                    case .cancelled:
                        follower.stop()
                    }
                })
                // Nothing to read out: VoiceOver reads the points themselves.
                .accessibilityHidden(true)

            if let selected {
                marker.position(selected.position)
                bubble(for: selected.point, at: selected.position)
            }
        }
        .onDisappear { follower.stop() }
    }

    /// The nearest point to a tap, or nil when the tap landed near none of them.
    private func nearestMark(to location: CGPoint) -> HistoryChartMark? {
        marks
            .map { ($0, hypot($0.position.x - location.x, $0.position.y - location.y)) }
            .filter { $0.1 <= hitRadius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Which point is under a dragging finger at `x`, by how far along the plot
    /// the finger is and nothing else: its height makes no difference, so a
    /// sweep from the first point to the last brings up every point on the
    /// way, in order, and the finger can stay below the line, out of the
    /// bubble's way. Points stacked almost on top of one another are picked up
    /// a little apart (see `HistoryChartMark.dragX`), so the sweep steps
    /// through those too.
    private func draggedIndex(at x: CGFloat) -> Int? {
        marks.indices.min { abs(marks[$0].dragX - x) < abs(marks[$1].dragX - x) }
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
    private func bubble(for point: HistoryChartPoint, at position: CGPoint) -> some View {
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
            point.writtenDate(dateStyle)
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

// MARK: - Touch

/// A finger on a history chart. Read by UIKit rather than by SwiftUI gestures,
/// because only a UIKit recognizer can make the screen's own gestures wait for
/// it: a drag that starts on the chart is the chart's, so the screen must not
/// scroll under it and the back swipe must not take the screen away with it.
///
/// What a press turns out to be is ChartTouchRecognizer's to tell: a tap,
/// reported once as it lifts, or a drag, reported from the moment it sets off
/// and on every move after that.
private struct ChartTouchSurface: UIViewRepresentable {
    /// A tap, at the point it landed.
    let onTap: (CGPoint) -> Void
    /// A drag across the chart, as it goes.
    let onDrag: (ChartDrag) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = ChartTouchRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handle(_:)))
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onDrag = onDrag
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onDrag: onDrag) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: (CGPoint) -> Void
        var onDrag: (ChartDrag) -> Void

        init(onTap: @escaping (CGPoint) -> Void, onDrag: @escaping (ChartDrag) -> Void) {
            self.onTap = onTap
            self.onDrag = onDrag
        }

        @objc func handle(_ recognizer: ChartTouchRecognizer) {
            if recognizer.state == .cancelled {
                onDrag(.cancelled)
                return
            }
            // A press the help has taken does nothing else, not even what was
            // recognized from it a moment before the help went up.
            guard !recognizer.yieldedToHelp else { return }
            switch recognizer.state {
            case .began:
                onDrag(.began(from: recognizer.startLocation, to: recognizer.fingerLocation))
            case .changed:
                onDrag(.moved(to: recognizer.fingerLocation))
            case .ended where recognizer.isDrag:
                // The bubble ends up on the point under the finger as it lifts.
                onDrag(.ended(at: recognizer.fingerLocation))
            case .ended:
                onTap(recognizer.fingerLocation)
            default:
                break
            }
        }

        /// Scrolling the screen and swiping back off it wait to see whether a
        /// press on the chart turns into a drag, and lose to it when it does:
        /// they are what that same drag would otherwise do as well.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            Self.isScreenGesture(other, around: gestureRecognizer)
        }

        /// Alongside everything else, SwiftUI's gestures included: the chart's
        /// press-and-hold help has to go on watching the press, and gives up on
        /// it by itself once the finger moves far enough to be dragging.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !Self.isScreenGesture(other, around: gestureRecognizer)
        }

        /// A finger put down on a screen still coasting from a flick is
        /// stopping it, not picking a point, just as it would be over a button.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard let view = gestureRecognizer.view else { return true }
            return !sequence(first: view, next: { $0.superview })
                .contains { ($0 as? UIScrollView)?.isDecelerating == true }
        }

        /// Whether `other` belongs to the screen the chart is on rather than to
        /// anything in it: the scrolling of whatever the chart sits in, or the
        /// navigation controller's back swipes, from the edge and from anywhere.
        private static func isScreenGesture(_ other: UIGestureRecognizer,
                                            around recognizer: UIGestureRecognizer) -> Bool {
            if let scrollView = other.view as? UIScrollView {
                return other === scrollView.panGestureRecognizer
            }
            guard let navigation = recognizer.view?.enclosingNavigationController else {
                return false
            }
            return other === navigation.interactivePopGestureRecognizer
                || other === navigation.interactiveContentPopGestureRecognizer
        }
    }
}

/// A drag across a history chart, in the touch surface's own coordinates.
private enum ChartDrag {
    /// The press has moved far enough to be a drag: where it went down, and
    /// where the finger is now.
    case began(from: CGPoint, to: CGPoint)
    case moved(to: CGPoint)
    /// The finger lifted, here.
    case ended(at: CGPoint)
    /// The touch was taken away, by the help going up or the chart going away.
    case cancelled
}

/// Moves a drag's selection through every point between the one showing and
/// the one under the finger, a point a frame, rather than jumping straight
/// there. Jumping would skip the points the finger passed over while the press
/// was still deciding whether it was a drag, and any a quick finger crosses
/// between two of its moves.
///
/// At a finger's usual pace that is the point under it every time, at once. A
/// finger that gets ahead is followed a point a frame while it is up to
/// `stepsBehind` points ahead, so each of those comes up, and in longer strides
/// beyond that, so however fast the finger goes the bubble is never more than
/// about that many frames behind it.
private final class DragFollower: NSObject {
    /// Puts up the point at an index into the marks.
    var show: (Int) -> Void = { _ in }

    /// How many points the finger can be ahead and still have each of them
    /// come up in turn. Covers what a press crosses before it counts as a drag
    /// (10 pt, at least 5 pt a point) with room to spare.
    private let stepsBehind = 6

    private var shown: Int?
    private var target: Int?
    private var link: CADisplayLink?
    /// Set when a point has just been put up out of turn, so the next one
    /// waits for a frame rather than replacing it before it is ever drawn.
    private var mustWaitForFrame = false

    /// Shows `index` straight away, wherever the selection was.
    func jump(to index: Int?) {
        stop()
        guard let index else { return }
        shown = index
        target = index
        show(index)
        mustWaitForFrame = true
    }

    /// Heads for `index`, stepping through every point on the way.
    func follow(to index: Int?) {
        guard let index else { return }
        guard shown != nil else {
            jump(to: index)
            return
        }
        target = index
        guard link == nil, index != shown else { return }
        if !mustWaitForFrame { step() }
        if shown != target { startLink() }
    }

    func stop() {
        link?.invalidate()
        link = nil
        mustWaitForFrame = false
    }

    private func startLink() {
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func frame() {
        mustWaitForFrame = false
        step()
        if shown == target { stop() }
    }

    private func step() {
        guard let shown, let target, shown != target else { return }
        let ahead = target - shown
        // ⌈|ahead| / stepsBehind⌉: one point at a time while the finger is up
        // to `stepsBehind` points ahead, strides that grow with the gap beyond.
        let stride = (abs(ahead) + stepsBehind - 1) / stepsBehind
        let next = shown + (ahead > 0 ? stride : -stride)
        self.shown = next
        show(next)
    }
}

/// Tells apart what a press on a history chart is:
///
/// - **A tap** lifts without having moved further than a hold may. It is
///   recognized once, as it lifts.
/// - **A drag** moves further than that. It begins there, follows the finger
///   wherever it goes after that, up and down included, and ends when the
///   finger lifts.
/// - **A hold** is whatever the chart's press-and-hold help takes. The help
///   gives up on a press at exactly the distance a drag starts at
///   (`SettingHelpBubble.holdMovement`), and this gives the press up the moment
///   the help announces it has it (`helpTookPress`). So a press is never taken
///   by both, and the finger has right up to the help going up to set off on a
///   drag instead.
private final class ChartTouchRecognizer: UIGestureRecognizer {
    /// Whether the press became a drag: what tells the `.ended` that lifts a
    /// drag from the one that recognizes a tap.
    private(set) var isDrag = false

    /// Whether the help took the press, after which nothing it was recognized
    /// as is acted on.
    private(set) var yieldedToHelp = false

    /// Where the finger went down, in the view's own coordinates.
    private(set) var startLocation: CGPoint = .zero

    /// Where the finger is, in the view's own coordinates; where it lifted, once
    /// it has.
    private(set) var fingerLocation: CGPoint = .zero

    /// The one finger followed. Any others that land meanwhile are ignored,
    /// rather than taken for a gesture of their own.
    private var finger: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        NotificationCenter.default.addObserver(self, selector: #selector(helpTookPress),
                                               name: SettingHelpBubble.holdRecognized,
                                               object: nil)
    }

    /// The help went up for the press being followed. Usually that is a press
    /// still resting, but the help can also be recognized on the very move that
    /// sets a drag off, or the lift that ends a tap, when that comes just as the
    /// hold time runs out: the press is let go of whatever it has been
    /// recognized as, and `yieldedToHelp` keeps the coordinator from acting on
    /// a drag or a tap recognized in that same instant.
    @objc private func helpTookPress() {
        guard finger != nil else { return }
        yieldedToHelp = true
        switch state {
        case .possible:
            state = .failed
        case .began, .changed:
            state = .cancelled
        default:
            break
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard finger == nil, let touch = touches.first else {
            touches.forEach { ignore($0, for: event) }
            return
        }
        touches.filter { $0 !== touch }.forEach { ignore($0, for: event) }
        finger = touch
        startLocation = touch.location(in: view)
        fingerLocation = startLocation
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        fingerLocation = finger.location(in: view)
        switch state {
        case .possible:
            guard hypot(fingerLocation.x - startLocation.x, fingerLocation.y - startLocation.y)
                    > SettingHelpBubble.holdMovement
            else { return }
            isDrag = true
            state = .began
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        fingerLocation = finger.location(in: view)
        switch state {
        case .possible, .began, .changed:
            state = .ended
        default:
            break
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let finger, touches.contains(finger) else { return }
        state = isDrag ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        finger = nil
        isDrag = false
        yieldedToHelp = false
    }
}

private extension UIView {
    /// The navigation controller the screen holding this view was pushed onto.
    var enclosingNavigationController: UINavigationController? {
        let controller = sequence(first: self as UIResponder, next: { $0.next })
            .first { $0 is UIViewController } as? UIViewController
        return controller?.navigationController
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
