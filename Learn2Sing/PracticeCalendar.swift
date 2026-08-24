//
//  PracticeCalendar.swift
//  Learn2Sing
//
//  Records how long was practised on each day, and draws the Home tab's
//  "Calendar" category out of it: the last 30 days as one square each, warming
//  from grey to the app's accent colour with the time spent on them.
//

import SwiftUI

/// One day of the practice calendar: the day itself and how many seconds of
/// exercises were finished on it. Plain data, so it rides in an
/// `ExerciseListRow` — which is what carries it into the list's cell — without
/// picking up the module's default main-actor isolation.
nonisolated struct PracticeDay: Equatable, Hashable {
    var date: Date
    var seconds: Int
}

/// Practice-time storage, kept in UserDefaults under `practiceSeconds` alongside
/// the exercise library and the score histories.
///
/// A run counts only once it has played through to the end, and it counts for
/// its full length: an exercise walked out of halfway adds nothing at all,
/// rather than adding the part that was sung.
enum PracticeLog {
    private static let key = "practiceSeconds"

    /// How much history is kept. The calendar only ever draws the last 30 days;
    /// the rest is held so a reinstall restores more than the current month —
    /// but not for ever, since the whole log rides in the profile document.
    private static let keptDays = 400

    /// The day a date falls on, counted from 1 Jan 1970 in the user's own
    /// calendar. This is the unit the log is keyed by, so a run is filed under
    /// the local day it finished on rather than a UTC one.
    static func day(for date: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date(timeIntervalSince1970: 0)),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    /// The whole log: seconds practised, keyed by day number.
    static func all() -> [Int: Int] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        return stored.reduce(into: [:]) { log, entry in
            if let day = Int(entry.key) { log[day] = entry.value }
        }
    }

    /// Adds a finished run's full length to the day it finished on.
    static func record(seconds: Double, at date: Date = Date()) {
        guard seconds > 0 else { return }
        var log = all()
        log[day(for: date), default: 0] += Int(seconds.rounded())
        save(log)
    }

    /// The last `count` days, oldest first — what the calendar draws. Days
    /// nothing was practised on are in the list too, with no seconds against
    /// them, so the grid is always full.
    static func recentDays(_ count: Int, endingOn today: Date = Date()) -> [PracticeDay] {
        let calendar = Calendar.current
        let log = all()
        let start = calendar.startOfDay(for: today)
        return (0..<count).reversed().compactMap { back in
            guard let date = calendar.date(byAdding: .day, value: -back, to: start) else { return nil }
            return PracticeDay(date: date, seconds: log[day(for: date, calendar: calendar)] ?? 0)
        }
    }

    /// Days older than `keptDays` are dropped on the way out, so the log stays
    /// bounded however long the app is used.
    private static func save(_ log: [Int: Int]) {
        let cutoff = day(for: Date()) - keptDays
        let kept = log.filter { $0.key > cutoff && $0.value > 0 }
        UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: kept.map { (String($0.key), $0.value) }),
            forKey: key
        )
        syncChanged()
    }

    // MARK: - Profile sync

    /// The log as the profile document carries it: day number and seconds
    /// interleaved in one flat array, `[d₀, s₀, d₁, s₁, …]`, oldest first —
    /// the same shape (and for the same size reasons) as `ScoreHistoryDoc`.
    /// nil when nothing has been practised yet, so the key is left out entirely.
    static func doc() -> [Int]? {
        let log = all()
        guard !log.isEmpty else { return nil }
        return log.keys.sorted().flatMap { [$0, log[$0]!] }
    }

    /// Merges a restored log into whatever this device has, keeping whichever
    /// side recorded more for each day. Taking the larger rather than the sum
    /// means a restore that runs twice can't inflate the history.
    static func merge(doc: [Int]) {
        var log = all()
        for i in stride(from: 0, to: doc.count - 1, by: 2) {
            log[doc[i]] = max(log[doc[i]] ?? 0, doc[i + 1])
        }
        save(log)
    }

    /// Practice time rides along in the synced profile, so a change to it needs
    /// uploading just like a finished run's score does.
    private static func syncChanged() {
        Task { @MainActor in ProfileSync.shared.scheduleUpload() }
    }
}

/// The Home tab's "Calendar" category: the last 30 days as one square each,
/// oldest in the top-left corner and today in the bottom-right, with nothing
/// written on them — a day is read off its colour alone. A day nothing was
/// practised on is grey, and from there the squares warm through a faint pink,
/// a stronger pink and a bright purple, landing on the app's accent colour at
/// `fullDayMinutes` of practice and staying there beyond it.
///
/// Tapping a square puts up the same bubble the score chart shows for a data
/// point, pointing at the square and naming how long that day was practised
/// for; tapping it again puts the bubble away.
struct PracticeCalendarView: View {
    /// The days to draw, oldest first — `dayCount` of them.
    let days: [PracticeDay]

    /// How many days the calendar shows, which is also how many
    /// `PracticeLog.recentDays` is asked for.
    static let dayCount = 30

    /// The practice time a square needs to reach the accent colour.
    static let fullDayMinutes: Double = 25

    private static let columns = 10

    /// The gap between squares, as a fraction of a square's side. Expressing it
    /// this way rather than in points is what makes the grid's height a fixed
    /// ratio of its width — so it can be laid out in a single pass, with every
    /// square's position already known while that pass runs. Nothing has to be
    /// measured first, and the bubble can be placed the moment a square is
    /// tapped.
    private static let gapRatio: CGFloat = 0.22

    /// The calendar draws its own colours rather than using the semantic ones,
    /// so it has to flip the grey and the bubble's ink with the appearance
    /// itself.
    @Environment(\.colorScheme) private var colorScheme

    /// The whole environment, purely so the accent colour can be resolved to
    /// components: the ramp ends on exactly the colour the app is tinted with,
    /// rather than on a copy of it that could drift.
    @Environment(\.self) private var environment

    @Environment(\.locale) private var locale

    /// The tapped day, held by date rather than by index because the squares
    /// shift along a place at every midnight.
    @State private var selectedDate: Date?

    /// Measured size of the bubble, needed to place it above the square and
    /// keep it inside the grid. Zero until the first layout pass, which is why
    /// the bubble stays hidden that long.
    @State private var bubbleSize: CGSize = .zero

    private var rows: Int { max(1, (days.count + Self.columns - 1) / Self.columns) }

    /// Width to height of the whole grid, gaps included — see `gapRatio`.
    private var gridRatio: CGFloat {
        let columns = CGFloat(Self.columns), rows = CGFloat(self.rows)
        return (columns + (columns - 1) * Self.gapRatio) / (rows + (rows - 1) * Self.gapRatio)
    }

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
                / (CGFloat(Self.columns) + CGFloat(Self.columns - 1) * Self.gapRatio)
            let step = side * (1 + Self.gapRatio)
            // Resolved once for the whole grid rather than per square.
            let ramp = stops
            ZStack {
                ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                    RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                        .fill(colour(for: day.seconds, along: ramp))
                        .frame(width: side, height: side)
                        // Before the placement below, so the square itself is the
                        // element VoiceOver reads — nothing is written on it, so
                        // its label is the only way to hear what day it is.
                        .accessibilityElement()
                        .accessibilityLabel(label(for: day))
                        .position(centre(of: index, side: side, step: step))
                }
                if let index = days.firstIndex(where: { $0.date == selectedDate }) {
                    bubble(for: days[index],
                           at: centre(of: index, side: side, step: step),
                           clearance: side / 2 + 3,
                           in: geo.size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let tapped = day(at: location, step: step)
                withAnimation(.snappy(duration: 0.2)) {
                    // Tapping the square the bubble already points at puts it
                    // away — the grid leaves no empty space to tap instead, the
                    // way the score chart's plot does.
                    selectedDate = (tapped?.date == selectedDate) ? nil : tapped?.date
                }
            }
        }
        .aspectRatio(gridRatio, contentMode: .fit)
        // A day that dropped off the end takes the bubble with it.
        .onChange(of: days) { _, new in
            if let date = selectedDate, !new.contains(where: { $0.date == date }) {
                selectedDate = nil
            }
        }
    }

    // MARK: - Geometry

    /// Where a day's square sits: filled row by row, so the oldest day is the
    /// top-left one and today is the last of the bottom row.
    private func centre(of index: Int, side: CGFloat, step: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(index % Self.columns) * step + side / 2,
                y: CGFloat(index / Self.columns) * step + side / 2)
    }

    /// The day a tap landed on, or nil for a tap outside the grid. A tap in the
    /// gap between two squares counts for the one before it, so the small
    /// squares don't have to be hit dead-on.
    private func day(at location: CGPoint, step: CGFloat) -> PracticeDay? {
        guard location.x >= 0, location.y >= 0, step > 0 else { return nil }
        let column = Int(location.x / step), row = Int(location.y / step)
        guard column < Self.columns else { return nil }
        let index = row * Self.columns + column
        return days.indices.contains(index) ? days[index] : nil
    }

    // MARK: - Colour

    /// Everything drawn on top of the squares — the bubble's date line — in the
    /// colour that contrasts with the list behind them.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    /// The ramp a square's colour is picked off, evenly spaced from no practice
    /// at all to `fullDayMinutes`: grey, a faint bright pink, a darker pink, a
    /// bright purple, and the app's own accent colour at the end of it.
    private var stops: [(red: Double, green: Double, blue: Double)] {
        let accent = Color.accentColor.resolve(in: environment)
        return [
            colorScheme == .dark ? (0.227, 0.227, 0.235) : (0.898, 0.898, 0.918),
            (1.000, 0.702, 0.878),
            (1.000, 0.310, 0.698),
            (0.910, 0.420, 1.000),
            (Double(accent.red), Double(accent.green), Double(accent.blue)),
        ]
    }

    /// A day's colour: how far its practice time got towards a full day, walked
    /// along the ramp and mixed between the two stops it falls between.
    private func colour(for seconds: Int,
                        along stops: [(red: Double, green: Double, blue: Double)]) -> Color {
        let progress = min(Double(seconds) / (Self.fullDayMinutes * 60), 1)
        let scaled = progress * Double(stops.count - 1)
        let lower = min(Int(scaled), stops.count - 2)
        let t = scaled - Double(lower)
        let from = stops[lower], to = stops[lower + 1]
        return Color(.sRGB,
                     red: from.red + (to.red - from.red) * t,
                     green: from.green + (to.green - from.green) * t,
                     blue: from.blue + (to.blue - from.blue) * t)
    }

    // MARK: - Bubble

    /// How long a day was practised for. Written in minutes (and hours past the
    /// first one), dropping to seconds for a day with something on it but less
    /// than a minute, so a short session doesn't read as none at all — while a
    /// day with nothing still reads as the round "0 min".  The style is handed
    /// the environment's locale by hand: that is the app's chosen language,
    /// which is not necessarily the device's.
    private func durationStyle(_ seconds: Int) -> Duration.UnitsFormatStyle {
        Duration.UnitsFormatStyle(
            allowedUnits: (1..<60).contains(seconds) ? [.seconds] : [.hours, .minutes],
            width: .abbreviated
        ).locale(locale)
    }

    private func label(for day: PracticeDay) -> Text {
        Text(day.date, format: .dateTime.day().month(.wide).year())
            + Text(verbatim: ", ")
            + Text(Duration.seconds(day.seconds), format: durationStyle(day.seconds))
    }

    /// The bubble itself: the day's practice time over the day it was, with its
    /// tail on the tapped square. It sits above the square when there is room
    /// and flips below when there isn't, and slides sideways to stay inside the
    /// grid — the tail follows, so it keeps pointing at the square either way.
    /// Deliberately the same shape, type sizes and colours as the score chart's
    /// data-point bubble.
    private func bubble(for day: PracticeDay, at point: CGPoint,
                        clearance: CGFloat, in size: CGSize) -> some View {
        let tailHeight: CGFloat = 7
        let inset: CGFloat = 2        // keeps the bubble off the grid's own edges
        let pointsUp = point.y - clearance - bubbleSize.height < 0
        let top = pointsUp ? point.y + clearance : point.y - clearance - bubbleSize.height
        let centreX = min(max(point.x, bubbleSize.width / 2 + inset),
                          max(size.width - bubbleSize.width / 2 - inset,
                              bubbleSize.width / 2 + inset))
        let shape = SpeechBubble(tailX: point.x - (centreX - bubbleSize.width / 2),
                                 tailPointsUp: pointsUp,
                                 tailHeight: tailHeight)

        return VStack(spacing: 1) {
            Text(Duration.seconds(day.seconds), format: durationStyle(day.seconds))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(day.date, format: .dateTime.day().month(.abbreviated).year())
                .font(.caption2)
                .foregroundStyle(ink.opacity(0.7))
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .padding(pointsUp ? .top : .bottom, tailHeight)
        // A shade off the row it sits on either way, so the bubble lifts off the
        // squares without competing with them for attention.
        .background(shape.fill(Color(white: colorScheme == .dark ? 0.16 : 1.0)))
        .overlay(shape.stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
        // Hidden until measured, otherwise the first frame flashes in the
        // wrong place.
        .opacity(bubbleSize == .zero ? 0 : 1)
        .position(x: centreX, y: top + bubbleSize.height / 2)
        // Taps belong to the grid underneath, which puts the bubble away.
        .allowsHitTesting(false)
    }
}
