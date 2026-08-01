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

    /// Every built-in category, in the order a user who never rearranged them sees.
    static let all = [recent, routines, favourites, recommended]

    static let orderKey = "homeCategoryOrder"

    /// A stored order as a category list: unknown names are dropped and any
    /// category the stored order predates is appended, so a list saved by an
    /// older version still shows every category.
    static func parse(_ raw: String) -> [String] {
        let stored = raw.split(separator: "\n").map(String.init).filter(all.contains)
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
}

/// The Home tab: built-in categories over the user's library — "Recent" (the
/// last five exercises that played through to the end), "Routines" (the
/// user's own ordered exercise lists, created via the + button; swipe right on
/// one to edit it, swipe left to delete it after a confirmation),
/// "Favourites" (a single ordered exercise list, its + button opening the
/// edit-favourites screen), and "Recommended" (the whitelisted exercises played
/// longest ago, as many as Settings ▸ Exercises asks for). The
/// categories look and behave like the Exercises tab's
/// (tap to collapse, long-press to rearrange) but never show exercise counts,
/// and the reorder screen has no add, delete, or rename — the categories are
/// fixed, though each one's eye button hides it from this tab (never the last
/// visible one).
struct HomeView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @EnvironmentObject private var toasts: ToastCenter
    // Typed (not NavigationPath) so pops can be inspected for the saved toasts.
    @State private var navigationPath: [ExerciseRoute] = []

    /// The built-in categories in the user's display order, persisted as a
    /// newline-joined list so a rearrangement outlives the app launch it was made in.
    @AppStorage(HomeCategories.orderKey) private var categoryOrderRaw = ""

    private var categories: [String] {
        get { HomeCategories.parse(categoryOrderRaw) }
        nonmutating set { categoryOrderRaw = HomeCategories.raw(newValue) }
    }

    /// How many exercises "Recommended" shows, from Settings ▸ Exercises.
    @AppStorage(RecommendedExercises.amountKey)
    private var recommendedAmount = RecommendedExercises.defaultAmount

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

    /// The exercises of the category the user last started playing from, in the
    /// order that category showed them — what the score screen's "Next" button
    /// walks along. Captured on the tap rather than recomputed later, since
    /// finishing an exercise reshuffles "Recent" and "Recommended" underneath.
    /// Never spans categories: the last exercise of one gets no Next button.
    @State private var playQueue: [UUID] = []

    /// Categories the user has collapsed. Their exercises are hidden; unlike the
    /// Exercises tab, no count appears in the header.
    @State private var collapsedCategories: Set<String> = []

    /// True while the user is rearranging category order. Entered by long-pressing
    /// a category header, exited via the top-leading ✗ button.
    @State private var isReordering = false

    /// Drives the List into edit mode so `.onMove` shows drag handles.
    @State private var editMode: EditMode = .inactive

    /// The collapse state captured when entering reorder mode. Restored on exit so
    /// categories that were expanded before the mode switch become expanded again.
    @State private var collapsedBeforeReorder: Set<String> = []

    /// Categories the user has hidden via the eye button on the edit-categories
    /// screen. They vanish from the Home list entirely (not just their exercises)
    /// but stay on the edit screen so they can be brought back. Persisted as a
    /// newline-joined list, since a hidden category should stay hidden across launches.
    @AppStorage("homeHiddenCategories") private var hiddenCategoriesRaw = ""

    private var hiddenCategories: Set<String> {
        get { Set(hiddenCategoriesRaw.split(separator: "\n").map(String.init)) }
        nonmutating set { hiddenCategoriesRaw = newValue.sorted().joined(separator: "\n") }
    }

    /// The categories still shown on the Home list, in the user's order.
    private var visibleCategories: [String] {
        categories.filter { !hiddenCategories.contains($0) }
    }

    /// Hiding is blocked for the last visible category, so the list can never be
    /// emptied out completely.
    private func canToggleHidden(_ category: String) -> Bool {
        hiddenCategories.contains(category) || visibleCategories.count > 1
    }

    private func toggleHidden(_ category: String) {
        guard canToggleHidden(category) else { return }
        var hidden = hiddenCategories
        if hidden.contains(category) {
            hidden.remove(category)
        } else {
            hidden.insert(category)
        }
        hiddenCategories = hidden
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

    /// The exercises to suggest: the whitelisted ones played longest ago
    /// (never-played first), as many as the amount setting asks for.
    private var recommendedExercises: [Exercise] {
        store.recommendedExercises(count: recommendedAmount)
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
            recommendedExercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
        default:
            []
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
                                           || category == HomeCategories.favourites)
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

    /// Tap on a routine: open its intro screen, where the description is shown
    /// and the order for this play-through can be changed before starting. An
    /// empty routine opens its editor instead, since there's nothing to play yet.
    private func openRoutine(_ id: UUID) {
        guard let routine = store.routines.first(where: { $0.id == id }) else { return }
        let playable = routine.exerciseIDs.filter { exerciseID in
            store.exercises.contains { $0.id == exerciseID }
        }
        if playable.isEmpty {
            navigationPath.append(ExerciseRoute.routine(id))
        } else {
            // A fresh play-through always starts from the routine's own order:
            // whatever the last one was dragged or shuffled into is discarded.
            routinePlayOrders[id] = playable
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

    /// The score screen's Next button: swap the finished exercise's intro/playback
    /// pair for the next exercise's intro screen.
    private func advance(to id: UUID) {
        navigationPath.removeLast(2)
        navigationPath.append(ExerciseRoute.play(id))
    }

    private func enterReorderMode() {
        guard !isReordering else { return }
        collapsedBeforeReorder = collapsedCategories
        withAnimation {
            collapsedCategories = Set(categories)
            isReordering = true
            editMode = .active
        }
    }

    private func exitReorderMode() {
        withAnimation {
            collapsedCategories = collapsedBeforeReorder
            isReordering = false
            editMode = .inactive
        }
    }

    /// A drag-reorderable row for a category on the edit-categories screen: the
    /// name, and trailing (just left of the List's drag handle) an eye button that
    /// hides the category from the Home list. The button is disabled on the last
    /// visible category so at least one always remains.
    private func reorderRow(_ category: String) -> some View {
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
    }

    @ViewBuilder
    private var listContent: some View {
        if isReordering {
            // Reorder mode like the Exercises tab's, minus the +/delete
            // toolbar buttons and the per-row exercise counts: the built-in
            // categories are plain draggable rows.
            List {
                ForEach(categories, id: \.self) { category in
                    reorderRow(category)
                }
                .onMove { source, destination in
                    var reordered = categories
                    reordered.move(fromOffsets: source, toOffset: destination)
                    categories = reordered
                    // The new order belongs in the profile document too.
                    ProfileSync.shared.scheduleUpload()
                }
            }
            .environment(\.editMode, $editMode)
        } else {
            ExerciseCollectionList(
                sections: listSections,
                onSelect: { id, category in
                    // Remember the tapped row's category, in the order it showed
                    // its exercises, so "Next" can walk it (and stop at its end).
                    playQueue = rows(in: category).map(\.id)
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
                onHeaderLongPress: { enterReorderMode() },
                onAdd: { category in
                    if category == HomeCategories.favourites {
                        navigationPath.append(ExerciseRoute.favourites)
                    } else {
                        newRoutineName = ""
                        isNamingNewRoutine = true
                    }
                }
            )
            // Span the full screen like a List so content scrolls under the
            // navigation and tab bars.
            .ignoresSafeArea()
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listContent
            .navigationTitle(isReordering ? L("Edit Categories") : L("Home"))
            .navigationBarTitleDisplayMode(.inline)
            .stableTopEdgeFade()
            .toolbar {
                if isReordering {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            exitReorderMode()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
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
            .onChange(of: navigationPath) { old, new in
                toasts.routesPopped(from: old, to: new)
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
                destination(for: route)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: ExerciseRoute) -> some View {
        switch route {
        case .play(let id):
            if let ex = store.exercises.first(where: { $0.id == id }) {
                ExerciseIntroView(exercise: ex) {
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
                    onStart: { navigationPath.append(ExerciseRoute.routinePlay(id, 0)) }
                )
            }
        case .routinePlay(let id, let index):
            let exercises = routineExercises(id)
            if index < exercises.count {
                ExerciseIntroView(exercise: exercises[index]) {
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
        case .routinePicker(let id):
            if store.routines.contains(where: { $0.id == id }) {
                RoutineExercisePickerView(routineID: id)
            }
        case .favourites:
            FavouritesEditView {
                navigationPath.append(ExerciseRoute.favouritesPicker)
            }
        case .favouritesPicker:
            FavouritesExercisePickerView()
        case .user:
            // Never appended from this tab; usernames only show in Community.
            EmptyView()
        }
    }
}
