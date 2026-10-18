//
//  PracticeHistoryView.swift
//  Learn2Sing
//
//  The screen a double tap on the Home tab's "Time Spent Singing" card opens:
//  how long was sung on each day as a line chart, over the same calendar the
//  card draws, for a range of days set from the toolbar — the past year until
//  another one is picked.
//

import SwiftUI
import UIKit

/// The ranges the Time Spent Singing screen sets in one tap. Each one ends
/// today, and none starts before the first day anything was sung: there is
/// nothing to show before it, and the screen's "From" date can't go there
/// either.
enum PracticeRange: CaseIterable, Identifiable {
    case week, month, year, allTime

    var id: Self { self }

    var title: String {
        switch self {
        case .week:    L("Past Week")
        case .month:   L("Past Month")
        case .year:    L("Past Year")
        case .allTime: L("All Time")
        }
    }

    /// How many days the range covers, today included, or nil for every day
    /// there is. A month is the Home tab calendar's 30 days.
    private var dayCount: Int? {
        switch self {
        case .week:    7
        case .month:   PracticeCalendarView.dayCount
        case .year:    365
        case .allTime: nil
        }
    }

    /// The days the range covers: ending on `today`, and starting on `earliest`
    /// at the earliest.
    func days(endingOn today: Date, earliest: Date) -> ClosedRange<Date> {
        guard let dayCount,
              let start = Calendar.current.date(byAdding: .day, value: -(dayCount - 1), to: today)
        else { return earliest...today }
        return max(start, earliest)...today
    }
}

/// What the Time Spent Singing screen's range is set to: one of the quick
/// ranges, which stays that range as the days move on, or two dates of the
/// user's own.
enum PracticeRangeSelection: Equatable {
    case preset(PracticeRange)
    case custom(ClosedRange<Date>)

    /// The days to draw, kept between `earliest` and `today` however long ago
    /// they were picked.
    func days(endingOn today: Date, earliest: Date) -> ClosedRange<Date> {
        switch self {
        case .preset(let range):
            return range.days(endingOn: today, earliest: earliest)
        case .custom(let days):
            let first = min(max(days.lowerBound, earliest), today)
            return first...min(max(days.upperBound, first), today)
        }
    }
}

/// How long was sung on each of `days`, drawn as the exercise intro screen
/// draws an exercise's scores: the same chart, with the day's practice time in
/// place of the score, and no window picker above it, since the screen it is on
/// sets the range for its calendar too.
struct PracticeTimeChart: View {
    /// Oldest first, one per day, the days nothing was sung on included.
    let days: [PracticeDay]

    /// The tapped day (see `HistoryLineChart.selectedDate`), held by the screen,
    /// which puts it away when the range changes.
    @Binding var selectedDate: Date?

    @Environment(\.colorScheme) private var colorScheme

    /// The app's chosen language, which the axis and the bubble write their
    /// times in.
    @Environment(\.locale) private var locale

    /// The empty range's message, in the chart's own ink.
    private var ink: Color { colorScheme == .dark ? .white : .black }

    /// What the y axis can count in, in seconds: the closest of these that fits
    /// the longest day into four steps. Each is a round number of minutes or of
    /// hours, so every label on the axis comes out in one unit.
    private static let steps = [60, 120, 300, 600, 900, 1_200, 1_800,
                                3_600, 7_200, 10_800, 14_400, 21_600]

    var body: some View {
        let longest = days.map(\.seconds).max() ?? 0
        if longest == 0 {
            Text("No practice time in this period.")
                .font(.subheadline)
                .foregroundStyle(ink.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 120)
                .explain(L("How long you sang on each day. You didn't finish an exercise on any day in this range."))
        } else {
            let step = Self.steps.first { $0 * 4 >= longest } ?? Self.steps[Self.steps.count - 1]
            let axisStyle = Duration.UnitsFormatStyle(
                allowedUnits: step % 3_600 == 0 ? [.hours] : [.minutes],
                width: .abbreviated
            ).locale(locale)
            // A single day has no span to lay out along time, so it sits in the
            // middle of an arbitrary window with nothing written under it, the
            // way the score chart draws a lone run.
            let window = days.count > 1 ? days[0].date...days[days.count - 1].date : nil
            HistoryLineChart(
                points: days.map { day in
                    HistoryChartPoint(
                        date: day.date,
                        x: window == nil ? 0 : day.date.timeIntervalSinceReferenceDate,
                        value: Double(day.seconds),
                        // Written as the calendar's bubble writes the same day.
                        valueText: Duration.seconds(day.seconds)
                            .formatted(PracticeCalendarView.durationStyle(day.seconds, locale: locale)))
                },
                xDomain: window.map {
                    $0.lowerBound.timeIntervalSinceReferenceDate
                        ... $0.upperBound.timeIntervalSinceReferenceDate
                } ?? -1...1,
                dateWindow: window,
                valueName: L("Time Spent Singing"),
                yDomain: 0...Double(step * 4),
                yTicks: (0...4).map { Double(step * $0) },
                yLabel: { Duration.seconds(Int($0)).formatted(axisStyle) },
                dateStyle: .dateTime.day().month(.abbreviated).year(),
                labelsTimesOfDay: false,
                tint: .accentColor,
                selectedDate: $selectedDate
            )
            // Left to right in every language, like the score chart.
            .environment(\.layoutDirection, .leftToRight)
            .explain(L("How long you sang on each day, oldest on the left. Tap a point to see that day's time and date."))
        }
    }
}

/// The Time Spent Singing screen: the chart of how long was sung each day, over
/// the Home tab's calendar drawn for the same days. The toolbar's calendar
/// button sets which days those are, a year up to today until it is used.
///
/// A list, so the calendar sits in exactly the card it has on the Home tab. The
/// chart sits in the card it has on the exercise intro screen.
struct PracticeHistoryView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// The daily practice goal from Settings ▸ Home Tab, which the calendar's
    /// squares are measured against, as on the Home tab.
    @AppStorage(RecommendedExercises.minutesKey)
    private var practiceMinutes = RecommendedExercises.defaultMinutes

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The days shown. Not kept: the screen opens on the past year every time.
    @State private var selection = PracticeRangeSelection.preset(.year)

    @State private var isPickingRange = false

    /// The chart's tapped day, if any.
    @State private var chartSelection: Date?

    /// The calendar square the bubble is pointing at, if any. Drawn over the
    /// whole list, as on the Home tab, since the calendar's row would clip it
    /// (see PracticeCalendarView).
    @State private var calendarSelection: PracticeCalendarSelection?

    /// The plot the exercise intro screen gives its score chart: its 416 pt
    /// (200 in landscape) less the window picker above the plot, which is 31 pt
    /// tall on iOS 26.2 with a 10 pt gap under it. Without the picker this chart
    /// is the plot alone, so the two plots come out the same size.
    private var chartHeight: CGFloat {
        verticalSizeClass == .compact ? 159 : 375
    }

    /// The card the chart is drawn on. In dark mode the score chart's own black;
    /// in light mode the calendar card's white, since the score chart's light
    /// grey is this list's background and would leave the chart no card at all.
    private var chartSurface: Color {
        colorScheme == .dark ? ScoreHistoryChart.surface(.dark)
                             : Color(.secondarySystemGroupedBackground)
    }

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let earliest = min(PracticeLog.firstDay() ?? today, today)
        let range = selection.days(endingOn: today, earliest: earliest)
        let days = PracticeLog.days(from: range.lowerBound, through: range.upperBound)

        List {
            Section {
                PracticeTimeChart(days: days, selectedDate: $chartSelection)
                    .frame(height: chartHeight)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(chartSurface, in: RoundedRectangle(cornerRadius: 14))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                PracticeCalendarView(days: days, goalMinutes: practiceMinutes) { square in
                    withAnimation(.snappy(duration: 0.2)) {
                        // Tapping the square the bubble already points at puts
                        // it away, as on the Home tab.
                        calendarSelection = (square?.day == calendarSelection?.day) ? nil : square
                    }
                }
                .explain(L("One square per day, oldest first. The more you practiced, the fuller the color, and a day that reached your daily practice time gets a check mark. Tap a square to see that day."))
            }
        }
        .listStyle(.insetGrouped)
        // The calendar's bubble, placed and put away exactly as on the Home tab
        // (see HomeView).
        .overlay {
            GeometryReader { geo in
                if let calendarSelection {
                    PracticeCalendarBubble(selection: calendarSelection,
                                           container: geo.frame(in: .global))
                    DismissOnAnyTap(ignoring: calendarSelection.grid) {
                        withAnimation(.snappy(duration: 0.2)) {
                            self.calendarSelection = nil
                        }
                    }
                    .frame(width: 0, height: 0)
                }
            }
            .allowsHitTesting(false)
        }
        // Drawn over the list rather than in it, the bubble can't travel with
        // its square, so scrolling puts it away.
        .onScrollPhaseChange { _, phase in
            if phase.isScrolling { calendarSelection = nil }
        }
        // Other days have other points and squares, so neither bubble has
        // anything left to point at.
        .onChange(of: range) {
            chartSelection = nil
            calendarSelection = nil
        }
        .navigationTitle(L("Time Spent Singing"))
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPickingRange = true
                } label: {
                    Label("Date Range", systemImage: "calendar")
                }
            }
        }
        .explainBarButton(L("Date Range"),
                          L("Sets which days the chart and the calendar show: a start and an end date of your own, or one of the quick ranges."))
        .sheet(isPresented: $isPickingRange) {
            PracticeRangeSheet(selection: $selection, today: today, earliest: earliest)
        }
    }
}

/// Where the Time Spent Singing screen's range is set: the quick ranges as a
/// row of buttons, and the "From" and "To" dates under them, which show the
/// range a quick one set and can still be changed from there. Changes reach the
/// screen underneath as they are made.
private struct PracticeRangeSheet: View {
    @Binding var selection: PracticeRangeSelection
    let today: Date
    /// The first day anything was sung on, which "From" can't go before.
    let earliest: Date

    @ObservedObject private var appLanguage = LanguageManager.shared
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @Environment(\.dismiss) private var dismiss

    private var range: ClosedRange<Date> {
        selection.days(endingOn: today, earliest: earliest)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                              spacing: 10) {
                        ForEach(PracticeRange.allCases) { preset in
                            presetButton(preset)
                        }
                    }
                }
                Section {
                    DatePicker("From", selection: from, in: earliest...range.upperBound,
                               displayedComponents: .date)
                        .settingHelp(L("The first day the chart and the calendar show. It can't be earlier than the first day you sang."))
                    DatePicker("To", selection: to, in: range.lowerBound...today,
                               displayedComponents: .date)
                        .settingHelp(L("The last day the chart and the calendar show. It can't be later than today."))
                }
            }
            .navigationTitle(L("Date Range"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .toolbarHitArea()
                    }
                    .fontWeight(.semibold)
                    .explain(L("Closes this. The chart and the calendar already show the days you set."))
                }
            }
        }
        .presentationDetents([.medium, .large])
        // A presentation takes neither the language nor the appearance from the
        // screen it is presented over (see IntroTutorialView).
        .environment(\.locale, appLanguage.language.locale)
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
    }

    /// A quick range's button, filled in while it is the range shown. A date
    /// changed by hand afterwards leaves none of them filled in.
    private func presetButton(_ preset: PracticeRange) -> some View {
        let isChosen = selection == .preset(preset)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = .preset(preset) }
        } label: {
            Text(verbatim: preset.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .foregroundStyle(isChosen ? Color.white : Color.primary)
                .background(isChosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .explain(L("Sets both dates at once. Each range ends today, and “All Time” starts on the first day you sang."))
    }

    /// "From", as a date picked there: the range becomes the user's own, ending
    /// where it ended before.
    private var from: Binding<Date> {
        Binding(get: { range.lowerBound }, set: { date in
            let day = Calendar.current.startOfDay(for: date)
            guard day != range.lowerBound else { return }
            selection = .custom(day...max(day, range.upperBound))
        })
    }

    /// "To", the same way round.
    private var to: Binding<Date> {
        Binding(get: { range.upperBound }, set: { date in
            let day = Calendar.current.startOfDay(for: date)
            guard day != range.upperBound else { return }
            selection = .custom(min(day, range.lowerBound)...day)
        })
    }
}
