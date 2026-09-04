//
//  HomeView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

/// The Home tab's built-in categories and the user's display order for them.
/// The order lives in UserDefaults (so it survives app restarts) and rides along
/// in the profile JSON ProfileSync uploads (so it survives reinstalls too).
enum HomeCategories {
    static let recent = "Recent"
    static let routines = "Routines"
    static let favourites = "Favourites"
    static let recommended = "Recommended"
    static let calendar = "Time Spent Singing"
    static let newForYou = "New for You"

    /// Every built-in category, in the order a user who never rearranged them sees.
    /// New categories go on the end: `parse` appends the ones a stored order
    /// predates, so anywhere else would put them somewhere different for a user
    /// who has rearranged their categories than for one who hasn't.
    static let all = [recent, routines, favourites, recommended, calendar, newForYou]

    /// Categories that have been renamed since a stored order or hidden set was
    /// written, old name to new. The English name *is* the identity here — it is
    /// what UserDefaults and the profile JSON carry — so a rename has to be
    /// translated on the way in, or a user who had rearranged or hidden the
    /// category would find it back at the end of the tab and visible again.
    static let renamed = ["Calendar": calendar]

    /// Identifies the single row the "Time Spent Singing" category is made of.
    /// It isn't an exercise, but the list is built around rows that are, so the
    /// calendar rides in a placeholder carrying this fixed id.
    static let calendarRowID = UUID(uuidString: "CA1E4DA9-0000-4000-8000-000000000001")
        ?? UUID()

    /// Identifies the single row "Recommended" is made of while it shows its
    /// card instead of listing exercises — a placeholder in the same way, and
    /// how a tap on the card is told from a tap on an exercise.
    static let recommendationRowID = UUID(uuidString: "2EC0DDED-0000-4000-8000-000000000002")
        ?? UUID()

    /// Identifies the row "New for You" holds while its exercises are still
    /// being fetched — the spinner — and the one it holds when they didn't
    /// arrive at all: the reload button, whose tap is told from an exercise's
    /// by this id.
    static let newForYouLoadingRowID = UUID(uuidString: "10AD1ED0-0000-4000-8000-000000000003")
        ?? UUID()
    static let newForYouRetryRowID = UUID(uuidString: "5E713D00-0000-4000-8000-000000000004")
        ?? UUID()

    static let orderKey = "homeCategoryOrder"
    /// The categories hidden from the tab, stored newline-joined like the order and
    /// likewise carried in the profile JSON (see `UserSettings`).
    static let hiddenKey = "homeHiddenCategories"

    /// A stored order as a category list: unknown names are dropped and any
    /// category the stored order predates is appended, so a list saved by an
    /// older version still shows every category.
    static func parse(_ raw: String) -> [String] {
        let stored = raw.split(separator: "\n")
            .map { renamed[String($0)] ?? String($0) }
            .filter(all.contains)
        return stored + all.filter { !stored.contains($0) }
    }

    static func raw(_ order: [String]) -> String {
        order.joined(separator: "\n")
    }

    /// The user's order as stored — read when building the profile JSON, written
    /// when restoring one.
    static var stored: [String] {
        get { parse(UserDefaults.standard.string(forKey: orderKey) ?? "") }
        set { UserDefaults.standard.set(raw(newValue), forKey: orderKey) }
    }

    /// The user's hidden categories as stored, read and written the same way and at
    /// the same points as `stored`. Sorted on the way out so the stored string only
    /// changes when the set does.
    static var hidden: Set<String> {
        get { parseHidden(UserDefaults.standard.string(forKey: hiddenKey) ?? "") }
        set { UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: hiddenKey) }
    }

    /// A stored hidden set as names, renames applied like `parse` does — the two
    /// screens that read the raw string out of `@AppStorage` themselves go
    /// through here, so a category hidden under an old name stays hidden.
    static func parseHidden(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map { renamed[String($0)] ?? String($0) })
    }
}

/// The Home tab's "Recommended" category as a single card: a big play button
/// beside the name of the category most of the suggested exercises come from,
/// with the singer's own level under it. Shown instead of listing them unless
/// Settings ▸ Exercises ▸ Recommendations asks for the list; tapping it opens
/// the whole suggestion as one queue.
///
/// Drawn to the practice calendar's shape, so the tab's two cards are exactly
/// the same size — and since that shape, not the contents, is what sets the
/// height, the play button and the type are scaled off it.
struct RecommendationCard: View {
    /// The category to name. Stored in English for the app's own categories and
    /// translated on the way to the screen, like everywhere else they're shown.
    let category: String
    /// How hard an exercise the singer can handle, 0-100 — see SkillLevelStore.
    /// The suggestions behind this card are pitched at it, so it is drawn on the
    /// card that opens them, as the same five stars an exercise's difficulty
    /// gets on its intro screen: the two are the same scale.
    let skill: Double

    var body: some View {
        GeometryReader { geo in
            // No spacing between the two: the name is centred in everything the
            // play button leaves, so what it is centred in has to reach all the
            // way from the button's edge to the card's. Its own padding is what
            // keeps it off both, and being symmetric it leaves the centre alone.
            HStack(spacing: 0) {
                Image(systemName: "play.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(height: geo.size.height * 0.72)
                    .foregroundStyle(Color.accentColor)
                    // The card is read as one thing, and the play button says
                    // nothing the "opens" trait doesn't already.
                    .accessibilityHidden(true)

                VStack(spacing: geo.size.height * 0.05) {
                    Text(ExerciseCategoryName.localized(category))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        // A long category name shrinks rather than pushing the
                        // card taller, which would break it away from the
                        // calendar's size.
                        .minimumScaleFactor(0.5)

                    // Sized off the card like everything else on it, so the row
                    // of stars stays a row however wide the list is.
                    DifficultyStars(fraction: skill / 100)
                        .font(.system(size: geo.size.height * 0.15))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Your level:")
                        .accessibilityValue(Text(skill / 100,
                                                 format: .percent.precision(.fractionLength(0))))
                }
                .padding(.horizontal, geo.size.height * 0.18)
                .frame(maxWidth: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(PracticeCalendarView.cardAspectRatio, contentMode: .fit)
        .accessibilityElement(children: .combine)
    }
}

/// The Home tab's edit-categories screen: the built-in categories as draggable
/// rows, each with an eye button that hides it from the tab. There is nothing to
/// add, delete or rename here — the categories are fixed. Opened by long-pressing
/// a category header.
///
/// Pushed onto the tab's navigation stack rather than swapped in behind the same
/// title, so it is left the way every other screen is: the back button, or the
/// system's swipe in from the leading edge, which slides the screen off the list
/// it belongs to. Either way the edits stay — the order and the hidden set are
/// written to UserDefaults as they are changed. Both are read straight from
/// storage here, so the tab underneath follows along without anything passed down.
private struct HomeCategoryEditView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @AppStorage(HomeCategories.orderKey) private var categoryOrderRaw = ""
    @AppStorage(HomeCategories.hiddenKey) private var hiddenCategoriesRaw = ""

    /// Always active so the rows show drag handles.
    @State private var editMode: EditMode = .active

    private var categories: [String] { HomeCategories.parse(categoryOrderRaw) }

    private var hiddenCategories: Set<String> {
        HomeCategories.parseHidden(hiddenCategoriesRaw)
    }

    /// Hiding is blocked for the last visible category, so the list can never be
    /// emptied out completely.
    private func canToggleHidden(_ category: String) -> Bool {
        hiddenCategories.contains(category)
            || categories.filter { !hiddenCategories.contains($0) }.count > 1
    }

    private func toggleHidden(_ category: String) {
        guard canToggleHidden(category) else { return }
        var hidden = hiddenCategories
        if hidden.contains(category) {
            hidden.remove(category)
        } else {
            hidden.insert(category)
        }
        hiddenCategoriesRaw = hidden.sorted().joined(separator: "\n")
    }

    private func row(_ category: String) -> some View {
        let isHidden = hiddenCategories.contains(category)
        return HStack {
            Text(ExerciseCategoryName.localized(category))
                .foregroundStyle(isHidden ? .secondary : .primary)
            Spacer()
            Button {
                withAnimation { toggleHidden(category) }
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .disabled(!canToggleHidden(category))
            .accessibilityLabel(isHidden
                                ? L("Show %@", ExerciseCategoryName.localized(category))
                                : L("Hide %@", ExerciseCategoryName.localized(category)))
        }
        // One explanation for the whole row rather than one per control: two
        // press-and-hold targets inside each other would both answer the hold.
        .settingHelp(L("Drag by the handle on the right to set the order these categories come in on the Home tab. The eye takes one off the tab, or puts it back; the last one left cannot be hidden."))
    }

    var body: some View {
        List {
            ForEach(categories, id: \.self) { category in
                row(category)
            }
            .onMove { source, destination in
                var reordered = categories
                reordered.move(fromOffsets: source, toOffset: destination)
                categoryOrderRaw = HomeCategories.raw(reordered)
                // The new order belongs in the profile document too.
                ProfileSync.shared.scheduleUpload()
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(L("Edit Categories"))
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
    }
}

/// The Home tab: built-in categories over the user's library — "Recent" (the
/// last five exercises that played through to the end), "Routines" (the
/// user's own ordered exercise lists, created via the + button; swipe right on
/// one to edit it, swipe left to delete it after a confirmation),
/// "Favourites" (a single ordered exercise list, its + button opening the
/// edit-favourites screen), "Recommended" (whitelisted exercises drawn on how
/// long ago each was last sung and how close it is to the singer's level, as
/// many as Settings ▸ Exercises asks for — as one card that plays them all in a
/// row, or as a list of them if that same screen says so),
/// "Time Spent Singing" (the last 30 days of practice as coloured squares — see
/// PracticeCalendarView), and "New for You" (five exercises off the community's
/// hot list, the ones pitched at the singer's own level — see NewForYouFeed).
/// Routines and favourites are rearranged in place by long-pressing a row and
/// dragging it, each within its own category — the computed categories can't
/// be, and neither can the calendar. The categories look and behave like the
/// Exercises tab's (tap to collapse, long-press to rearrange) but never show
/// exercise counts, and the reorder screen has no add, delete, or rename — the
/// categories are fixed, though each one's eye button hides it from this tab
/// (never the last visible one).
struct HomeView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @EnvironmentObject private var toasts: ToastCenter
    /// The singer's level and how hard each exercise is, which "Recommended" is
    /// built out of and its card shows. Its own object rather than CommunitySync's
    /// counts, where a heart tapped in the Community tab would rebuild this whole
    /// list for nothing — see SkillLevelStore.
    @ObservedObject private var skill = SkillLevelStore.shared
    /// The community exercises "New for You" picks from. Its own object rather
    /// than the Community tab's list: this one asks a fixed question — the top of
    /// the "Hot" order — and is not the tab's to reorder or page. See
    /// NewForYouFeed.
    @ObservedObject private var newForYou = NewForYouFeed.shared
    // Typed (not NavigationPath) so pops can be inspected for the saved toasts.
    @State private var navigationPath: [ExerciseRoute] = []

    /// The built-in categories in the user's display order, persisted as a
    /// newline-joined list so a rearrangement outlives the app launch it was made in.
    @AppStorage(HomeCategories.orderKey) private var categoryOrderRaw = ""

    private var categories: [String] { HomeCategories.parse(categoryOrderRaw) }

    /// How long a day the singer means to practise for, from Settings ▸ Exercises:
    /// how much "Recommended" suggests, and what a day of the calendar's squares
    /// is measured against.
    @AppStorage(RecommendedExercises.minutesKey)
    private var practiceMinutes = RecommendedExercises.defaultMinutes

    /// Whether "Recommended" lists those exercises or shows the single card that
    /// opens them all as one queue, likewise from Settings ▸ Exercises. Either
    /// way the same exercises are suggested — this only decides how.
    @AppStorage(RecommendedExercises.asListKey)
    private var recommendationsAsList = RecommendedExercises.defaultAsList

    /// Drives the "name your new routine" alert opened from the + button.
    @State private var isNamingNewRoutine = false
    @State private var newRoutineName = ""

    /// The routine a left swipe asked to delete, while its "really delete?"
    /// confirmation is up. A copy, not a lookup, so the alert still shows the
    /// name if the routine changes underneath it.
    @State private var routinePendingDelete: Routine?
    @State private var isConfirmingRoutineDelete = false

    /// The exercise order each routine's intro screen is currently showing,
    /// keyed by routine id. Reordering or shuffling there only touches this —
    /// the routine's own order stays as saved — and opening a routine resets
    /// its entry, so a change lasts for one play-through.
    @State private var routinePlayOrders: [UUID: [UUID]] = [:]

    /// The routine each queue above was built out of, as it stood at the time —
    /// so that the routine as it stands now can be told apart from it. The edit
    /// screen is a toolbar button away from the intro screen, and coming back
    /// from having added or removed exercises there has to reach the queue:
    /// see `syncRoutineQueue`.
    @State private var routineQueueSources: [UUID: [UUID]] = [:]

    /// The same thing for the recommendation card's screen, which is one queue
    /// rather than one per routine: the exercises it is showing, in the order it
    /// is showing them. Set as the card is tapped, so a shuffle or a drag there
    /// likewise lasts for a single play-through.
    @State private var recommendationOrder: [UUID] = []

    /// The exercises of the category the user last started playing from, in the
    /// order that category showed them — what the score screen's "Next" button
    /// walks along. Captured on the tap rather than recomputed later, since
    /// finishing an exercise reshuffles "Recent" and "Recommended" underneath.
    /// Never spans categories: the last exercise of one gets no Next button.
    @State private var playQueue: [UUID] = []

    /// The calendar square the bubble is currently pointing at, if any. It
    /// lives here rather than in the calendar itself because the bubble is
    /// drawn over the whole list — the row it belongs to would clip it (see
    /// PracticeCalendarView).
    @State private var calendarSelection: PracticeCalendarSelection?

    /// Categories the user has collapsed. Their exercises are hidden; unlike the
    /// Exercises tab, no count appears in the header.
    @State private var collapsedCategories: Set<String> = []

    /// True while a favourite or routine is actually held in a drag, which the
    /// title says.
    @State private var isDraggingRow = false

    /// Categories the user has hidden via the eye button on the edit-categories
    /// screen. They vanish from the Home list entirely (not just their exercises)
    /// but stay on the edit screen so they can be brought back. Persisted as a
    /// newline-joined list, since a hidden category should stay hidden across launches.
    @AppStorage(HomeCategories.hiddenKey) private var hiddenCategoriesRaw = ""

    private var hiddenCategories: Set<String> {
        HomeCategories.parseHidden(hiddenCategoriesRaw)
    }

    /// The categories still shown on the Home list, in the user's order.
    private var visibleCategories: [String] {
        categories.filter { !hiddenCategories.contains($0) }
    }

    /// The five exercises that most recently played through to the end, newest first.
    private var recentExercises: [Exercise] {
        Array(store.recentlyPlayed
            .compactMap { id in store.exercises.first { $0.id == id } }
            .prefix(5))
    }

    /// A routine shown as a list row. The row type is built around exercises, so
    /// the routine rides in a placeholder exercise carrying its id and name; the
    /// id is how taps and swipes are recognized as targeting a routine.
    private func routineRow(_ routine: Routine) -> ExerciseListRow {
        var placeholder = Exercise(name: routine.name)
        placeholder.id = routine.id
        return ExerciseListRow(exercise: placeholder, pattern: [],
                               swipeActionTitle: L("Edit"), swipeActionImage: "pencil",
                               showsDelete: true)
    }

    /// The favourite exercises that still exist in the library, in the user's order.
    private var favouriteExercises: [Exercise] {
        store.favourites.compactMap { id in store.exercises.first { $0.id == id } }
    }

    /// The exercises to suggest, easiest first: enough of them to fill the daily
    /// practice time, drawn from the whitelist on how long ago each was last sung
    /// and how close it is to the singer's level — see `recommendedExercises`.
    private var recommendedExercises: [Exercise] {
        store.recommendedExercises(minutes: practiceMinutes,
                                   skill: skill.level, hardness: skill.hardness)
    }

    /// The category most of the suggested exercises belong to — what the
    /// recommendation card names — or nil when there is nothing to suggest.
    /// A tie goes to whichever category comes first in the Exercises tab's own
    /// order, so the card doesn't flip between two equally represented ones.
    private var recommendedCategory: String? {
        var counts: [String: Int] = [:]
        for exercise in recommendedExercises { counts[exercise.category, default: 0] += 1 }
        let order = store.categories
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            // Ordered by hand rather than left to whichever key the dictionary
            // happened to hand over first, which is nothing to rely on: on an
            // equal count the earlier category is the greater one, so that is
            // the one `max` keeps.
            return (order.firstIndex(of: lhs.key) ?? .max) > (order.firstIndex(of: rhs.key) ?? .max)
        }?.key
    }

    /// The community exercises "New for You" lists: the hottest ones pitched at
    /// this singer's level, out of the two pages of the hot list NewForYouFeed
    /// fetched. Empty until that fetch lands, which leaves the category as empty
    /// as an unfilled "Favourites".
    private var newForYouExercises: [Exercise] {
        newForYou.exercises(atLevel: skill.level)
    }

    /// What the category shows: its exercises, or — while it has none — what is
    /// keeping it from having any. Alone among the Home categories its rows come
    /// off the server, so an empty one here isn't the plain "nothing to show"
    /// an unfilled "Favourites" is: it is a fetch still running, or one that
    /// never arrived. Both say so in a row of their own, the second offering the
    /// reload button that asks again.
    ///
    /// The spinner covers the moment before the first fetch starts as well as
    /// the fetch itself, so opening the tab doesn't flash an empty category on
    /// the way to a full one. A fetch that succeeded and turned up nothing is
    /// the only genuinely empty case, and it draws nothing at all.
    private var newForYouRows: [ExerciseListRow] {
        let exercises = newForYouExercises
        if !exercises.isEmpty {
            return exercises.map {
                // Labelled with the uploader the way the Community tab labels
                // them, but inert: a profile is a Community screen, and this
                // category is five rows rather than a way into that tab. And no
                // settings swipe — these exercises aren't in the library, so
                // there are none to open until one is downloaded.
                ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id),
                                uploaderName: $0.uploaderName, showsSettings: false)
            }
        }
        // A fetch on the wire is what the category is doing now, so it outranks
        // the failure an earlier one left behind: the spinner goes back up the
        // moment another attempt starts, rather than the reload button standing
        // there through an attempt already under way.
        if newForYou.isFetching || !newForYou.hasLoaded && !newForYou.didFail {
            return [placeholderRow(HomeCategories.newForYouLoadingRowID, content: .loading)]
        }
        if newForYou.didFail {
            let help = L("These exercises come from the community and didn’t load. Tap to try again.")
            return [placeholderRow(HomeCategories.newForYouRetryRowID, content: .retry(help: help))]
        }
        return []
    }

    /// A row that isn't an exercise: the list is built around rows that are, so
    /// the calendar, the recommendation card and "New for You"'s spinner and
    /// reload button each ride in a nameless placeholder carrying the fixed id
    /// that row is known by, drawn as `content`.
    private func placeholderRow(_ id: UUID, content: ExerciseListRowContent) -> ExerciseListRow {
        var placeholder = Exercise(name: "")
        placeholder.id = id
        return ExerciseListRow(exercise: placeholder, pattern: [], content: content)
    }

    /// The one row "Recommended" holds while it shows its card: the card itself,
    /// drawn across the whole row like the calendar's. nil when there is nothing
    /// to suggest, which leaves the category as empty as the list would.
    private var recommendationCardRow: ExerciseListRow? {
        guard let category = recommendedCategory else { return nil }
        return placeholderRow(HomeCategories.recommendationRowID,
                              content: .recommendation(category: category, skill: skill.level))
    }

    private func rows(in category: String) -> [ExerciseListRow] {
        switch category {
        case HomeCategories.recent:
            recentExercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
        case HomeCategories.routines:
            store.routines.map(routineRow)
        case HomeCategories.favourites:
            favouriteExercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
        case HomeCategories.recommended:
            recommendationsAsList
                ? recommendedExercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
                : recommendationCardRow.map { [$0] } ?? []
        case HomeCategories.calendar:
            [calendarRow]
        case HomeCategories.newForYou:
            newForYouRows
        default:
            []
        }
    }

    /// The one row "Time Spent Singing" holds: the practice calendar itself, drawn across
    /// the whole row. Its days are read fresh here rather than by the view, so
    /// a finished run — which republishes the store, and so rebuilds this
    /// screen — reaches the list as a changed row and redraws the squares.
    private var calendarRow: ExerciseListRow {
        placeholderRow(
            HomeCategories.calendarRowID,
            content: .practiceCalendar(PracticeLog.recentDays(PracticeCalendarView.dayCount),
                                       goalMinutes: practiceMinutes)
        )
    }

    /// The categories the user arranges by hand — the ones that are lists they
    /// built themselves. "Recent" and "Recommended" are computed orders, so their
    /// rows can't be dragged at all.
    private func isReorderable(_ category: String) -> Bool {
        category == HomeCategories.routines || category == HomeCategories.favourites
    }

    /// What holding a category's + button explains. The two categories that have
    /// one add different things: a routine is made here, while the favourites are
    /// picked on a screen of their own.
    private func addHelp(for category: String) -> String? {
        switch category {
        case HomeCategories.routines:
            L("Makes a new routine: your own list of exercises, sung one after the other.")
        case HomeCategories.favourites:
            L("Opens the list of your favourites, where you pick which exercises are in it and what order they come in.")
        default:
            nil
        }
    }

    private var listSections: [ExerciseListSection] {
        visibleCategories.map { category in
            let items = rows(in: category)
            let isCollapsed = collapsedCategories.contains(category)
            return ExerciseListSection(category: category,
                                       isCollapsed: isCollapsed,
                                       totalCount: items.count,
                                       items: isCollapsed ? [] : items,
                                       showsCount: false,
                                       showsAdd: category == HomeCategories.routines
                                           || category == HomeCategories.favourites,
                                       addHelp: addHelp(for: category),
                                       allowsReorder: isReorderable(category))
        }
    }

    /// A routine's exercises that still exist in the library, in the order this
    /// play-through uses — what actually plays. The routine-play routes index
    /// into this list.
    private func routineExercises(_ routineID: UUID) -> [Exercise] {
        routineOrder(routineID).compactMap { id in store.exercises.first { $0.id == id } }
    }

    /// The exercise order the routine's intro screen is showing, falling back to
    /// the routine's stored order before that screen has been opened.
    private func routineOrder(_ routineID: UUID) -> [UUID] {
        routinePlayOrders[routineID]
            ?? store.routines.first(where: { $0.id == routineID })?.exerciseIDs
            ?? []
    }

    /// A routine's exercises as it has them stored, minus any that have since
    /// been deleted from the library — the queue its intro screen starts from.
    private func routinePlayableIDs(_ routineID: UUID) -> [UUID] {
        store.routines.first { $0.id == routineID }?.exerciseIDs.filter { exerciseID in
            store.exercises.contains { $0.id == exerciseID }
        } ?? []
    }

    /// Fold the routine as it now stands back into the queue its intro screen is
    /// showing. Called whenever the routine changes underneath that screen, which
    /// is what happens when the user goes into the edit screen the toolbar button
    /// opens, adds or removes exercises there, and comes back.
    ///
    /// A queue nobody has touched simply becomes the routine again, so an edit
    /// screen reorder shows up too. Once the queue has been dragged, shuffled or
    /// swiped it is the user's own arrangement of this play-through and is kept:
    /// the edit only adds its new exercises (on the end, since the queue no longer
    /// follows the routine's order) and drops the ones it removed.
    private func syncRoutineQueue(_ routineID: UUID) {
        let playable = routinePlayableIDs(routineID)
        guard let source = routineQueueSources[routineID], playable != source else { return }
        routineQueueSources[routineID] = playable

        let queue = routineOrder(routineID)
        if queue == source {
            routinePlayOrders[routineID] = playable
        } else {
            var merged = queue.filter { playable.contains($0) }
            merged.append(contentsOf: playable.filter { !merged.contains($0) })
            routinePlayOrders[routineID] = merged
        }
    }

    /// Tap on a routine: open its intro screen, where the description is shown
    /// and the order for this play-through can be changed before starting. An
    /// empty routine opens its editor instead, since there's nothing to play yet.
    private func openRoutine(_ id: UUID) {
        let playable = routinePlayableIDs(id)
        if playable.isEmpty {
            navigationPath.append(ExerciseRoute.routine(id))
        } else {
            // A fresh play-through always starts from the routine's own order:
            // whatever the last one was dragged or shuffled into is discarded.
            routinePlayOrders[id] = playable
            routineQueueSources[id] = playable
            navigationPath.append(ExerciseRoute.routineIntro(id))
        }
    }

    /// The score screen's button while a routine is playing: swap the finished
    /// exercise's intro/playback pair for the next one's intro, or pop back
    /// home after the last exercise.
    private func advanceRoutine(_ id: UUID, after index: Int) {
        if index + 1 < routineExercises(id).count {
            navigationPath.removeLast(2)
            navigationPath.append(ExerciseRoute.routinePlay(id, index + 1))
        } else {
            navigationPath = []
        }
    }

    /// The skip button on a routine's exercise intro screen: go on to the next
    /// exercise's intro without playing this one. The intro screen is *replaced*
    /// rather than pushed on top of, so however many are skipped in a row, going
    /// back lands on the routine's own screen — the same place backing out of the
    /// first one goes.
    private func skipRoutine(_ id: UUID, at index: Int) {
        navigationPath.removeLast()
        navigationPath.append(ExerciseRoute.routinePlay(id, index + 1))
    }

    /// The recommended exercises that still exist in the library, in the order
    /// this play-through uses — the recommendation routes index into this list,
    /// exactly as the routine ones index into a routine's.
    private var recommendationExercises: [Exercise] {
        recommendationOrder.compactMap { id in store.exercises.first { $0.id == id } }
    }

    /// Tap on the recommendation card: open the suggestion as one queue, where
    /// its order can be changed before it starts. Always from the suggestion as
    /// it stands, so whatever the last play-through was dragged or shuffled into
    /// is discarded.
    private func openRecommendations() {
        recommendationOrder = recommendedExercises.map(\.id)
        navigationPath.append(ExerciseRoute.recommendationIntro)
    }

    /// `advanceRoutine` for that queue, which needs no routine to say which one.
    private func advanceRecommendations(after index: Int) {
        if index + 1 < recommendationExercises.count {
            navigationPath.removeLast(2)
            navigationPath.append(ExerciseRoute.recommendationPlay(index + 1))
        } else {
            navigationPath = []
        }
    }

    /// `skipRoutine` for that queue.
    private func skipRecommendations(at index: Int) {
        navigationPath.removeLast()
        navigationPath.append(ExerciseRoute.recommendationPlay(index + 1))
    }

    /// Route a row tap or swipe: routine rows play (tap) or edit (swipe) the
    /// routine, exercise rows go to the given exercise route.
    private func open(_ id: UUID, asExercise route: ExerciseRoute) {
        if store.routines.contains(where: { $0.id == id }) {
            switch route {
            case .play: openRoutine(id)
            default: navigationPath.append(ExerciseRoute.routine(id))
            }
        } else {
            navigationPath.append(route)
        }
    }

    /// The exercise listed below `id` in the category it was started from, skipping
    /// any that have been deleted since. nil once the end of that category is
    /// reached — the Next button is left out there.
    private func nextExercise(after id: UUID) -> UUID? {
        guard let index = playQueue.firstIndex(of: id) else { return nil }
        return playQueue[(index + 1)...].first { next in
            store.exercises.contains { $0.id == next }
        }
    }

    /// The same walk down "New for You", which needs its own: those exercises are
    /// resolved through CommunitySync rather than out of the library, so the
    /// library is no test of whether one is still there to play.
    private func nextCommunityExercise(after id: UUID) -> UUID? {
        guard let index = playQueue.firstIndex(of: id) else { return nil }
        return playQueue[(index + 1)...].first { CommunitySync.shared.exercise(for: $0) != nil }
    }

    /// The score screen's Next button: swap the finished exercise's intro/playback
    /// pair for the next exercise's intro screen.
    private func advance(to id: UUID) {
        navigationPath.removeLast(2)
        navigationPath.append(ExerciseRoute.play(id))
    }

    /// `advance(to:)` for those exercises: the same swap of the finished
    /// exercise's intro/playback pair for the next one's intro, on the pair of
    /// routes that resolve through the community rather than the library.
    private func advanceCommunity(to id: UUID) {
        navigationPath.removeLast(2)
        navigationPath.append(ExerciseRoute.communityPlay(id))
    }

    /// Copies a community exercise into the user's library and counts the
    /// download towards its total (only the first time this user downloads it) —
    /// the Download button on a "New for You" exercise's intro and score screens,
    /// exactly as in the Community tab.
    private func downloadCommunity(_ exercise: Exercise) {
        _ = store.downloadCopy(of: exercise)
        CommunitySync.shared.registerDownload(for: exercise.id)
    }

    private var listContent: some View {
        ExerciseCollectionList(
            sections: listSections,
            onSelect: { id, category in
                guard id != HomeCategories.recommendationRowID else {
                    openRecommendations()
                    return
                }
                // The reload button "New for You" puts up when its fetch didn't
                // come back. Handled before the queue is captured below: it
                // isn't an exercise, and there is nothing to play from a
                // category that has none.
                guard id != HomeCategories.newForYouRetryRowID else {
                    Task { await newForYou.refresh() }
                    return
                }
                // Remember the tapped row's category, in the order it showed
                // its exercises, so "Next" can walk it (and stop at its end).
                playQueue = rows(in: category).map(\.id)
                guard category != HomeCategories.newForYou else {
                    // Not in the library, so not `play`: the community pair of
                    // routes, which resolve their exercise through CommunitySync
                    // and carry the heart and the download button.
                    navigationPath.append(ExerciseRoute.communityPlay(id))
                    return
                }
                open(id, asExercise: .play(id))
            },
            onSettings: { open($0, asExercise: .settings($0)) },
            onDelete: { id in
                guard let routine = store.routines.first(where: { $0.id == id }) else { return }
                routinePendingDelete = routine
                isConfirmingRoutineDelete = true
            },
            onToggleCollapse: { category in
                if collapsedCategories.contains(category) {
                    collapsedCategories.remove(category)
                } else {
                    collapsedCategories.insert(category)
                }
            },
            onHeaderLongPress: { navigationPath.append(ExerciseRoute.editCategories) },
            onAdd: { category in
                if category == HomeCategories.favourites {
                    navigationPath.append(ExerciseRoute.favourites)
                } else {
                    newRoutineName = ""
                    isNamingNewRoutine = true
                }
            },
            onCalendarSelect: { selection in
                withAnimation(.snappy(duration: 0.2)) {
                    // Tapping the square the bubble already points at puts it
                    // away — the grid leaves no empty space to tap instead, the
                    // way the score chart's plot does.
                    calendarSelection = (selection?.day == calendarSelection?.day)
                        ? nil : selection
                }
            },
            // Long-press drag rearranges the favourites and the routines,
            // exactly like the Exercises tab — except each list is its own
            // (`movesStayInSection`), so nothing can be dragged from one
            // category into another.
            onMove: { id, category, before in
                switch category {
                case HomeCategories.favourites: store.moveFavourite(id, before: before)
                case HomeCategories.routines: store.moveRoutine(id, before: before)
                default: break
                }
            },
            onDragChange: { isDraggingRow = $0 },
            movesStayInSection: true
        )
        // Span the full screen like a List so content scrolls under the
        // navigation and tab bars.
        .ignoresSafeArea()
        // The bubble a tapped square puts up. Over the list rather than inside
        // the calendar's row, where it would be cut off against the card: a
        // bubble pointing at a square in the middle row has to reach past the
        // card and onto the list's own background. It arrives in global
        // coordinates, which is what both sides can speak (see
        // PracticeCalendarBubble).
        .overlay {
            GeometryReader { geo in
                if let calendarSelection {
                    PracticeCalendarBubble(selection: calendarSelection,
                                           container: geo.frame(in: .global))
                    // The next tap anywhere on the screen puts it away —
                    // whether or not that tap does anything else itself. Taps
                    // on the grid are the exception: the calendar answers those.
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
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listContent
            .navigationTitle(L("Home"))
            .navigationBarTitleDisplayMode(.inline)
            .stableTopEdgeFade()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ReorderableListTitle(title: L("Home"), isDragging: isDraggingRow)
                }
            }
            .alert("New Routine", isPresented: $isNamingNewRoutine) {
                TextField("Name", text: $newRoutineName)
                Button("Create") {
                    store.addRoutine(named: newRoutineName.trimmingCharacters(in: .whitespaces))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for the new routine.")
            }
            .alert("Delete Routine?", isPresented: $isConfirmingRoutineDelete,
                   presenting: routinePendingDelete) { routine in
                Button("Delete", role: .destructive) {
                    store.deleteRoutine(routine.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { routine in
                Text(L("\"%@\" will be deleted. Its exercises stay in your library. This cannot be undone.", routine.name))
            }
            // "New for You" is fetched the first time this tab appears and after
            // a fetch that failed; a visit to one already showing it leaves the
            // list alone rather than reshuffling it under the user.
            .task { await newForYou.refreshIfNeeded() }
            .onChange(of: navigationPath) { old, new in
                toasts.routesPopped(from: old, to: new)
                // The bubble belongs to this screen, so it doesn't follow the
                // user onto the next one and shouldn't be waiting on the way back.
                calendarSelection = nil
            }
            // A delete is the only thing that can shorten the library, and the
            // only thing that can leave a route on the path pointing at something
            // that's gone.
            .onChange(of: store.exercises.count) { _, _ in
                dropStaleRoutes()
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
                destination(for: route)
            }
        }
    }

    /// Deleting an exercise from its settings screen pops that screen but leaves
    /// the routes it was opened from on the path — an exercise intro screen that
    /// can no longer find its exercise, or a routine-play route whose index is now
    /// past the end of the play-through. Those render as a blank screen, so drop
    /// them and land the user on the nearest one that still resolves.
    private func dropStaleRoutes() {
        while let route = navigationPath.last {
            switch route {
            case .play(let id), .playback(let id), .settings(let id), .edit(let id):
                guard !store.exercises.contains(where: { $0.id == id }) else { return }
            case .routinePlay(let id, let index), .routinePlayback(let id, let index):
                guard index >= routineExercises(id).count else { return }
            case .recommendationPlay(let index), .recommendationPlayback(let index):
                guard index >= recommendationExercises.count else { return }
            // A routine with nothing left to play has no intro screen: Start
            // Routine would push a routine-play route that resolves to nothing.
            // The recommendation card's screen goes the same way.
            case .routineIntro(let id):
                guard routineExercises(id).isEmpty else { return }
            case .recommendationIntro:
                guard recommendationExercises.isEmpty else { return }
            default:
                return
            }
            navigationPath.removeLast()
        }
    }

    @ViewBuilder
    private func destination(for route: ExerciseRoute) -> some View {
        switch route {
        case .play(let id):
            if let ex = store.exercises.first(where: { $0.id == id }) {
                ExerciseIntroView(
                    exercise: ex,
                    onSettings: { navigationPath.append(ExerciseRoute.settings(id)) }
                ) {
                    navigationPath.append(ExerciseRoute.playback(id))
                }
            }
        case .playback(let id):
            if let ex = store.exercises.first(where: { $0.id == id }) {
                // Pop the intro screen along with playback so Exit lands back
                // on the list the exercise was tapped from.
                PlaybackView(exercise: ex,
                             onScoreExit: { navigationPath.removeLast(2) },
                             onScoreNext: nextExercise(after: id).map { next in
                                 { advance(to: next) }
                             })
            }
        case .settings(let id):
            if store.exercises.contains(where: { $0.id == id }) {
                ExerciseSettingsView(exercise: store.binding(for: id))
            }
        case .edit(let id):
            if let ex = store.exercises.first(where: { $0.id == id }) {
                EditingView(exercise: ex)
            }
        case .routine(let id):
            if store.routines.contains(where: { $0.id == id }) {
                RoutineEditView(routineID: id) {
                    navigationPath.append(ExerciseRoute.routinePicker(id))
                }
            }
        case .routineIntro(let id):
            if let routine = store.routines.first(where: { $0.id == id }) {
                RoutineIntroView(
                    routine: routine,
                    order: Binding(get: { routineOrder(id) },
                                   set: { routinePlayOrders[id] = $0 }),
                    onSettings: { navigationPath.append(ExerciseRoute.routine(id)) },
                    onSelect: { exerciseID in
                        guard let index = routineExercises(id)
                            .firstIndex(where: { $0.id == exerciseID }) else { return }
                        navigationPath.append(ExerciseRoute.routinePlay(id, index))
                    },
                    onStart: { navigationPath.append(ExerciseRoute.routinePlay(id, 0)) }
                )
                // The edit screen this screen's toolbar opens is pushed on top
                // of it, leaving it here in the stack to be caught up with what
                // was done there — added and removed exercises reach the queue
                // as the edit is made, so backing out lands on a queue that is
                // already right.
                .onChange(of: routinePlayableIDs(id)) { syncRoutineQueue(id) }
            }
        case .routinePlay(let id, let index):
            let exercises = routineExercises(id)
            if index < exercises.count {
                // Captured by id, not by position: the settings screen can delete
                // the exercise, which re-indexes the rest of the play-through.
                let exerciseID = exercises[index].id
                ExerciseIntroView(
                    exercise: exercises[index],
                    onSettings: { navigationPath.append(ExerciseRoute.settings(exerciseID)) },
                    onSkip: index + 1 < exercises.count
                        ? { skipRoutine(id, at: index) } : nil
                ) {
                    navigationPath.append(ExerciseRoute.routinePlayback(id, index))
                }
            }
        case .routinePlayback(let id, let index):
            let exercises = routineExercises(id)
            if index < exercises.count {
                PlaybackView(exercise: exercises[index],
                             scoreExitTitle: index + 1 < exercises.count ? L("Next") : L("Exit"),
                             onScoreExit: { advanceRoutine(id, after: index) })
            }
        case .recommendationIntro:
            // The routine intro screen with nothing above the queue: the
            // suggestion has no name or description of its own to show.
            ExerciseQueueIntroView(
                order: $recommendationOrder,
                title: ExerciseCategoryName.localized(HomeCategories.recommended),
                startTitle: L("Play Recommended Exercises"),
                onSelect: { exerciseID in
                    guard let index = recommendationExercises
                        .firstIndex(where: { $0.id == exerciseID }) else { return }
                    navigationPath.append(ExerciseRoute.recommendationPlay(index))
                },
                onStart: { navigationPath.append(ExerciseRoute.recommendationPlay(0)) }
            )
            // Where a routine has its edit screen, the suggestion has the
            // settings it was put together under — same place, same symbol.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        navigationPath.append(ExerciseRoute.exercisesSettings)
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .explain(L("Opens the settings these suggestions are made under: how long you practise a day, and which exercises may be picked."))
                }
            }
        case .exercisesSettings:
            ExercisesSettingsView {
                navigationPath.append(ExerciseRoute.recommendationWhitelist)
            }
        case .recommendationWhitelist:
            RecommendationWhitelistView()
        case .recommendationPlay(let index):
            let exercises = recommendationExercises
            if index < exercises.count {
                // Captured by id for the same reason the routine's is: the
                // settings screen can delete the exercise, re-indexing the rest.
                let exerciseID = exercises[index].id
                ExerciseIntroView(
                    exercise: exercises[index],
                    onSettings: { navigationPath.append(ExerciseRoute.settings(exerciseID)) },
                    onSkip: index + 1 < exercises.count
                        ? { skipRecommendations(at: index) } : nil
                ) {
                    navigationPath.append(ExerciseRoute.recommendationPlayback(index))
                }
            }
        case .recommendationPlayback(let index):
            let exercises = recommendationExercises
            if index < exercises.count {
                PlaybackView(exercise: exercises[index],
                             scoreExitTitle: index + 1 < exercises.count ? L("Next") : L("Exit"),
                             onScoreExit: { advanceRecommendations(after: index) })
            }
        case .routinePicker(let id):
            if store.routines.contains(where: { $0.id == id }) {
                RoutineExercisePickerView(routineID: id)
            }
        case .communityPlay(let id):
            // The Community tab's intro screen, opened from here: the heart and
            // the download button that only a community exercise has, and the
            // public id it is listed by as the `likeID` they act on.
            if let ex = CommunitySync.shared.exercise(for: id) {
                ExerciseIntroView(exercise: ex,
                                  likeID: ex.id,
                                  uploaderName: ex.uploaderName,
                                  // The "Created by" line, exactly as in the
                                  // Community tab: these exercises come off the
                                  // same fetch, so the uploader behind one is
                                  // known here too.
                                  onSelectUploader: CommunitySync.shared.uploaderID(of: ex.id).map { uploader in
                                      { navigationPath.append(
                                          ExerciseRoute.user(id: uploader, name: ex.uploaderName)) }
                                  },
                                  onDownload: { downloadCommunity(ex) }) {
                    navigationPath.append(ExerciseRoute.communityPlayback(id))
                }
            }
        case .communityPlayback(let id):
            if let ex = CommunitySync.shared.exercise(for: id) {
                // Pop the intro screen along with playback so Exit lands back on
                // the Home list, and post the play under the public id the
                // exercise already carries rather than deriving one from it.
                PlaybackView(exercise: ex,
                             onScoreExit: { navigationPath.removeLast(2) },
                             onScoreNext: nextCommunityExercise(after: id).map { next in
                                 { advanceCommunity(to: next) }
                             },
                             onScoreDownload: { downloadCommunity(ex) },
                             communityID: ex.id)
            }
        case .favourites:
            FavouritesEditView {
                navigationPath.append(ExerciseRoute.favouritesPicker)
            }
        case .favouritesPicker:
            FavouritesExercisePickerView()
        case .editCategories:
            HomeCategoryEditView()
        case .user(let id, let name):
            // Reached from the "Created by" line on a "New for You" exercise's
            // intro screen — the same profile the Community tab pushes, and the
            // same screen either tab's back button returns from. What it lists
            // plays through the community pair of routes, since none of it is in
            // the library either.
            CommunityUserProfileView(uploaderID: id, username: name) { exerciseID, listed in
                playQueue = listed
                navigationPath.append(ExerciseRoute.communityPlay(exerciseID))
            }
        }
    }
}
