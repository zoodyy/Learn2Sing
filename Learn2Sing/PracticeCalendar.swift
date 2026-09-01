//
//  PracticeCalendar.swift
//  Learn2Sing
//
//  Records how long was practised on each day, and draws the Home tab's
//  "Calendar" category out of it: the last 30 days as one square each, grey to
//  start with and taking on the app's accent colour — nothing else — as the
//  time spent on them grows.
//

import SwiftUI
import UIKit

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

    /// Wipes every recorded day. Used by Settings ▸ Reset ▸ Home ▸ Clear
    /// Practice Time.
    static func deleteAll() {
        UserDefaults.standard.removeObject(forKey: key)
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

/// A tapped square, as the calendar hands it on: the day it stands for, and
/// where it and its grid are on screen.
///
/// The bubble is drawn over the list rather than inside the calendar's own row
/// (see `PracticeCalendarBubble`), so it travels in coordinates both sides
/// agree on — global ones. The grid comes along because the bubble is placed
/// against it exactly as it would have been from the inside: above the square
/// when the grid has room above it, below when it hasn't, slid sideways to stay
/// within the grid's width.
nonisolated struct PracticeCalendarSelection: Equatable {
    var day: PracticeDay
    /// The tapped square, in global coordinates.
    var square: CGRect
    /// The whole grid of squares, in global coordinates.
    var grid: CGRect
}

/// The Home tab's "Calendar" category: the last 30 days as one square each,
/// oldest in the top-left corner and today in the bottom-right, with no numbers
/// on them — a day is read off its colour. A day nothing was practised on is
/// grey, and the only colour that goes over that grey is the app's own accent
/// one: it fades in in step with the time spent on the day, covering the grey
/// completely at `goalMinutes` — the daily practice time from Settings ▸
/// Exercises, the same one the "Recommended" category fills — and staying there
/// beyond it. A day that reached it is ticked, so the days that count can be
/// picked out at a glance rather than judged off the end of a fade.
///
/// Tapping a square reports it, and the screen it went up on draws the bubble —
/// the same one the score chart shows for a data point — over the list. The
/// bubble is not drawn from here because a hosted SwiftUI view is clipped to
/// the row it is in, and a bubble pointing at a square in the middle row has
/// nowhere near enough room inside three rows of squares: it has to reach past
/// the card, onto the list's own background.
struct PracticeCalendarView: View {
    /// The days to draw, oldest first — `dayCount` of them.
    let days: [PracticeDay]

    /// The practice time a day needs for its square to reach the accent colour
    /// and be ticked: the daily practice time from Settings ▸ Exercises.
    let goalMinutes: Int

    /// The square a tap landed on, or nil for a tap that landed on none — which
    /// is what the screen puts the bubble away on.
    var onSelect: (PracticeCalendarSelection?) -> Void

    /// How many days the calendar shows, which is also how many
    /// `PracticeLog.recentDays` is asked for.
    static let dayCount = 30

    private static let columns = 10

    /// The gap between squares, as a fraction of a square's side. Expressing it
    /// this way rather than in points is what makes the grid's height a fixed
    /// ratio of its width — so it can be laid out in a single pass, with every
    /// square's position already known while that pass runs. Nothing has to be
    /// measured first, and the bubble can be placed the moment a square is
    /// tapped.
    private static let gapRatio: CGFloat = 0.22

    /// The calendar draws its own colours rather than using the semantic ones,
    /// so it has to flip the grey with the appearance itself.
    @Environment(\.colorScheme) private var colorScheme

    /// The app's chosen language, which is not necessarily the device's — the
    /// squares' accessibility labels are written in it.
    @Environment(\.locale) private var locale

    private var rows: Int { max(1, (days.count + Self.columns - 1) / Self.columns) }

    /// The goal as the log counts practice, in seconds. Floored at a minute so a
    /// nonsense setting can't tick every square, empty days included.
    private var goalSeconds: Double { Double(max(1, goalMinutes)) * 60 }

    /// Whether a day met the goal — what puts the tick on its square.
    private func reachedGoal(_ day: PracticeDay) -> Bool {
        Double(day.seconds) >= goalSeconds
    }

    /// Width to height of a whole grid `rows` rows deep, gaps included — see
    /// `gapRatio`.
    private static func gridRatio(rows: Int) -> CGFloat {
        let columns = CGFloat(Self.columns), rows = CGFloat(rows)
        return (columns + (columns - 1) * gapRatio) / (rows + (rows - 1) * gapRatio)
    }

    /// The shape of the card the calendar fills at its usual `dayCount` days.
    /// The Home tab's recommendation card is drawn to it too, so the tab's two
    /// full-width cards are exactly the same size.
    static let cardAspectRatio: CGFloat = gridRatio(rows: (dayCount + columns - 1) / columns)

    /// Width to height of the whole grid, gaps included — see `gapRatio`.
    private var gridRatio: CGFloat { Self.gridRatio(rows: rows) }

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
                / (CGFloat(Self.columns) + CGFloat(Self.columns - 1) * Self.gapRatio)
            let step = side * (1 + Self.gapRatio)
            ZStack {
                ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                    let square = RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    square
                        .fill(emptyDay)
                        .frame(width: side, height: side)
                        // The day's practice time, laid over that grey in the
                        // accent colour: a day with nothing on it leaves the
                        // grey as it is, and a day that reached the goal hides
                        // it altogether.
                        .overlay {
                            square.fill(Color.accentColor.opacity(opacity(for: day.seconds)))
                        }
                        // The tick a day that reached the goal wears. Drawn on
                        // the square rather than beside it: the grid's shape is
                        // fixed, and the square is by then the accent colour,
                        // which white sits on cleanly in either appearance.
                        .overlay {
                            if reachedGoal(day) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: side * 0.52, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        // Before the placement below, so the square itself is the
                        // element VoiceOver reads — the tick is the only thing
                        // written on it, so its label is the only way to hear
                        // what day it is.
                        .accessibilityElement()
                        .accessibilityLabel(label(for: day))
                        .position(centre(of: index, side: side, step: step))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                onSelect(selection(at: location, side: side, step: step,
                                   grid: geo.frame(in: .global)))
            }
        }
        .aspectRatio(gridRatio, contentMode: .fit)
    }

    // MARK: - Geometry

    /// Where a day's square sits: filled row by row, so the oldest day is the
    /// top-left one and today is the last of the bottom row.
    private func centre(of index: Int, side: CGFloat, step: CGFloat) -> CGPoint {
        CGPoint(x: CGFloat(index % Self.columns) * step + side / 2,
                y: CGFloat(index / Self.columns) * step + side / 2)
    }

    /// The square a tap landed on, in global coordinates, or nil for a tap
    /// outside the grid. A tap in the gap between two squares counts for the
    /// one before it, so the small squares don't have to be hit dead-on.
    private func selection(at location: CGPoint, side: CGFloat, step: CGFloat,
                           grid: CGRect) -> PracticeCalendarSelection? {
        guard location.x >= 0, location.y >= 0, step > 0 else { return nil }
        let column = Int(location.x / step), row = Int(location.y / step)
        guard column < Self.columns else { return nil }
        let index = row * Self.columns + column
        guard days.indices.contains(index) else { return nil }
        let middle = centre(of: index, side: side, step: step)
        return PracticeCalendarSelection(
            day: days[index],
            square: CGRect(x: grid.minX + middle.x - side / 2,
                           y: grid.minY + middle.y - side / 2,
                           width: side, height: side),
            grid: grid
        )
    }

    // MARK: - Colour

    /// The square every day starts as, and the one a day with nothing
    /// practised on it stays: a grey that sits just off the card behind it,
    /// either way round the appearance is.
    private var emptyDay: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 0.227, green: 0.227, blue: 0.235)
            : Color(.sRGB, red: 0.898, green: 0.898, blue: 0.918)
    }

    /// How strongly the accent colour is laid over that grey: how far the day's
    /// practice time got towards the daily goal, taken straight as an opacity.
    /// Half the goal is drawn at half strength, and the goal and anything past
    /// it is the accent colour outright — which is what the tick is white on.
    private func opacity(for seconds: Int) -> Double {
        min(Double(seconds) / goalSeconds, 1)
    }

    // MARK: - Accessibility

    /// How long a day was practised for. Written in minutes (and hours past the
    /// first one), dropping to seconds for a day with something on it but less
    /// than a minute, so a short session doesn't read as none at all — while a
    /// day with nothing still reads as the round "0 min". The style is handed
    /// the environment's locale by hand: that is the app's chosen language,
    /// which is not necessarily the device's.
    static func durationStyle(_ seconds: Int, locale: Locale) -> Duration.UnitsFormatStyle {
        Duration.UnitsFormatStyle(
            allowedUnits: (1..<60).contains(seconds) ? [.seconds] : [.hours, .minutes],
            width: .abbreviated
        ).locale(locale)
    }

    /// What VoiceOver reads for a square: the day, its practice time, and — for
    /// a day that reached the goal — what the tick on it means, which is
    /// otherwise only there to be seen.
    private func label(for day: PracticeDay) -> Text {
        var parts = [
            day.date.formatted(.dateTime.day().month(.wide).year().locale(locale)),
            Duration.seconds(day.seconds)
                .formatted(Self.durationStyle(day.seconds, locale: locale)),
        ]
        if reachedGoal(day) { parts.append(L("Goal reached")) }
        // Assembled as one string rather than as concatenated `Text`s: every
        // piece is localized by hand already (a hosted view doesn't inherit the
        // app's chosen language), so there is nothing left for `Text` to resolve.
        return Text(verbatim: parts.joined(separator: ", "))
    }
}

/// The bubble a tapped calendar square puts up: the day's practice time over
/// the day it was, with its tail on the square. Deliberately the same shape,
/// type sizes and colours as the score chart's data-point bubble.
///
/// Drawn over the whole Home list rather than inside the calendar's row, which
/// would clip it (see `PracticeCalendarView`) — but placed against the grid
/// exactly as it would have been from in there: above the square when the grid
/// has room above it and below when it hasn't, slid sideways to stay within the
/// grid's width, the tail following either way so it keeps pointing at the
/// square.
struct PracticeCalendarBubble: View {
    let selection: PracticeCalendarSelection
    /// Where the view this is drawn in sits on screen, so the selection's
    /// global coordinates can be brought into it.
    let container: CGRect

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    /// Measured size, needed to place the bubble against the square. Zero until
    /// the first layout pass, which is why it stays hidden that long.
    @State private var size: CGSize = .zero

    /// The bubble's own drawing, over the colour that contrasts with the list
    /// behind it.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    var body: some View {
        let tailHeight: CGFloat = 7
        let inset: CGFloat = 2        // keeps the bubble off the grid's own edges
        let point = CGPoint(x: selection.square.midX, y: selection.square.midY)
        let clearance = selection.square.height / 2 + 3
        let grid = selection.grid
        let pointsUp = point.y - clearance - size.height < grid.minY
        let top = pointsUp ? point.y + clearance : point.y - clearance - size.height
        let centreX = min(max(point.x, grid.minX + size.width / 2 + inset),
                          max(grid.maxX - size.width / 2 - inset,
                              grid.minX + size.width / 2 + inset))
        let shape = SpeechBubble(tailX: point.x - (centreX - size.width / 2),
                                 tailPointsUp: pointsUp,
                                 tailHeight: tailHeight)
        let day = selection.day

        VStack(spacing: 1) {
            Text(Duration.seconds(day.seconds),
                 format: PracticeCalendarView.durationStyle(day.seconds, locale: locale))
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
        // A shade off the row it points at either way, so the bubble lifts off
        // the squares without competing with them for attention.
        .background(shape.fill(Color(white: colorScheme == .dark ? 0.16 : 1.0)))
        .overlay(shape.stroke(Color.accentColor.opacity(0.8), lineWidth: 1))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        // Hidden until measured, otherwise the first frame flashes in the
        // wrong place.
        .opacity(size == .zero ? 0 : 1)
        .position(x: centreX - container.minX, y: top + size.height / 2 - container.minY)
        // Taps belong to the list underneath, which puts the bubble away.
        .allowsHitTesting(false)
    }
}

/// Puts the calendar's bubble away on the next tap anywhere on screen — on a
/// button or on nothing at all, and whatever else that tap goes on to do.
///
/// A recognizer on the window rather than a SwiftUI gesture: the Home list is a
/// UIKit collection view and the tab and navigation bars are UIKit too, so there
/// is no one SwiftUI view every tap on that screen passes through. It only ever
/// watches — it cancels no touches, delays none, and recognizes alongside every
/// other recognizer — so a tap still does whatever it was going to do, and the
/// bubble goes away as well. It exists only while a bubble is up.
///
/// Taps inside `ignoring` are left alone. That is the calendar's own grid, which
/// answers its taps itself: a second tap on the square the bubble points at puts
/// it away, and this must not get there first and turn that into a fresh one.
struct DismissOnAnyTap: UIViewRepresentable {
    /// In global coordinates — the ones the calendar reports its squares in.
    var ignoring: CGRect
    var action: () -> Void

    func makeUIView(context: Context) -> WindowTapWatcher { WindowTapWatcher() }

    func updateUIView(_ watcher: WindowTapWatcher, context: Context) {
        watcher.ignoring = ignoring
        watcher.action = action
    }
}

/// The view behind `DismissOnAnyTap`: invisible, and there only to have a
/// window to hang the recognizer on — which it does as it joins one, and takes
/// back again as it leaves.
final class WindowTapWatcher: UIView {
    var ignoring: CGRect = .zero
    var action: () -> Void = {}

    private var tap: UITapGestureRecognizer?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let tap {
            // Off the window it was on, which is not necessarily `window` — this
            // is also the call that says the view has left one altogether.
            tap.view?.removeGestureRecognizer(tap)
            self.tap = nil
        }
        guard let window else { return }
        let watcher = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        watcher.cancelsTouchesInView = false
        watcher.delaysTouchesBegan = false
        watcher.delaysTouchesEnded = false
        watcher.delegate = self
        window.addGestureRecognizer(watcher)
        tap = watcher
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let window, !ignoring.contains(recognizer.location(in: window)) else { return }
        action()
    }
}

extension WindowTapWatcher: UIGestureRecognizerDelegate {
    /// Watching only: nothing else on screen may be made to wait on this, or to
    /// lose to it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
