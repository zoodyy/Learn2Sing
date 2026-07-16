//
//  HomeView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

/// The Home tab: built-in categories over the user's library — "Recent" (the
/// last five exercises that played through to the end), "Routines" (the
/// user's own ordered exercise lists, created via the + button; swipe right on
/// one to edit it, swipe left to delete it after a confirmation), and
/// "Favourites" (a single ordered exercise list, its + button opening the
/// edit-favourites screen). The
/// categories look and behave like the Exercises tab's
/// (tap to collapse, long-press to rearrange) but never show exercise counts,
/// and the reorder screen has no add, delete, or rename — the categories are
/// fixed.
struct HomeView: View {
    @EnvironmentObject private var store: ExerciseStore
    @EnvironmentObject private var toasts: ToastCenter
    // Typed (not NavigationPath) so pops can be inspected for the saved toasts.
    @State private var navigationPath: [ExerciseRoute] = []

    private static let recentCategory = "Recent"
    private static let routinesCategory = "Routines"
    private static let favouritesCategory = "Favourites"

    /// The built-in categories in the user's display order.
    @State private var categories: [String] = [HomeView.recentCategory,
                                               HomeView.routinesCategory,
                                               HomeView.favouritesCategory]

    /// Drives the "name your new routine" alert opened from the + button.
    @State private var isNamingNewRoutine = false
    @State private var newRoutineName = ""

    /// The routine a left swipe asked to delete, while its "really delete?"
    /// confirmation is up. A copy, not a lookup, so the alert still shows the
    /// name if the routine changes underneath it.
    @State private var routinePendingDelete: Routine?
    @State private var isConfirmingRoutineDelete = false

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
                               swipeActionTitle: "Edit", swipeActionImage: "pencil",
                               showsDelete: true)
    }

    /// The favourite exercises that still exist in the library, in the user's order.
    private var favouriteExercises: [Exercise] {
        store.favourites.compactMap { id in store.exercises.first { $0.id == id } }
    }

    private func rows(in category: String) -> [ExerciseListRow] {
        switch category {
        case Self.recentCategory:
            recentExercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
        case Self.routinesCategory:
            store.routines.map(routineRow)
        case Self.favouritesCategory:
            favouriteExercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
        default:
            []
        }
    }

    private var listSections: [ExerciseListSection] {
        categories.map { category in
            let items = rows(in: category)
            let isCollapsed = collapsedCategories.contains(category)
            return ExerciseListSection(category: category,
                                       isCollapsed: isCollapsed,
                                       totalCount: items.count,
                                       items: isCollapsed ? [] : items,
                                       showsCount: false,
                                       showsAdd: category == Self.routinesCategory
                                           || category == Self.favouritesCategory)
        }
    }

    /// A routine's exercises that still exist in the library, in routine order —
    /// what actually plays. The routine-play routes index into this list.
    private func routineExercises(_ routineID: UUID) -> [Exercise] {
        (store.routines.first(where: { $0.id == routineID })?.exerciseIDs ?? [])
            .compactMap { id in store.exercises.first { $0.id == id } }
    }

    /// Tap on a routine: play its exercises in order, starting with the first
    /// one's intro screen. An empty routine opens its editor instead, since
    /// there's nothing to play yet.
    private func openRoutine(_ id: UUID) {
        if routineExercises(id).isEmpty {
            navigationPath.append(ExerciseRoute.routine(id))
        } else {
            navigationPath.append(ExerciseRoute.routinePlay(id, 0))
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

    @ViewBuilder
    private var listContent: some View {
        if isReordering {
            // Reorder mode like the Exercises tab's, minus the +/delete
            // toolbar buttons and the per-row exercise counts: the built-in
            // categories are plain draggable rows.
            List {
                ForEach(categories, id: \.self) { category in
                    Text(category)
                }
                .onMove { source, destination in
                    categories.move(fromOffsets: source, toOffset: destination)
                }
            }
            .environment(\.editMode, $editMode)
        } else {
            ExerciseCollectionList(
                sections: listSections,
                onSelect: { open($0, asExercise: .play($0)) },
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
                    if category == Self.favouritesCategory {
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
            .navigationTitle(isReordering ? "Edit Categories" : "Home")
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
                Text("\"\(routine.name)\" will be deleted. Its exercises stay in your library. This cannot be undone.")
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
                             onScoreExit: { navigationPath.removeLast(2) })
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
                             scoreExitTitle: index + 1 < exercises.count ? "Next" : "Exit",
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
