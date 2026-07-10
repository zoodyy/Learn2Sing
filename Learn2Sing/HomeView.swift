//
//  HomeView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

/// The Home tab: built-in categories over the user's library — "Recent" (the
/// last five exercises that played through to the end) and "Routines" (the
/// user's own ordered exercise lists, created via the + button; swipe right on
/// one to edit it). The categories look and behave like the Exercises tab's
/// (tap to collapse, long-press to rearrange) but never show exercise counts,
/// and the reorder screen has no add, delete, or rename — the categories are
/// fixed.
struct HomeView: View {
    @EnvironmentObject private var store: ExerciseStore
    @State private var navigationPath = NavigationPath()

    private static let recentCategory = "Recent"
    private static let routinesCategory = "Routines"

    /// The built-in categories in the user's display order.
    @State private var categories: [String] = [HomeView.recentCategory,
                                               HomeView.routinesCategory]

    /// Drives the "name your new routine" alert opened from the + button.
    @State private var isNamingNewRoutine = false
    @State private var newRoutineName = ""

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
                               swipeActionTitle: "Edit", swipeActionImage: "pencil")
    }

    private func rows(in category: String) -> [ExerciseListRow] {
        switch category {
        case Self.recentCategory:
            recentExercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
        case Self.routinesCategory:
            store.routines.map(routineRow)
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
                                       showsCount: false)
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
            navigationPath = NavigationPath()
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

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
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
                        onToggleCollapse: { category in
                            if collapsedCategories.contains(category) {
                                collapsedCategories.remove(category)
                            } else {
                                collapsedCategories.insert(category)
                            }
                        },
                        onHeaderLongPress: { enterReorderMode() }
                    )
                    // Span the full screen like a List so content scrolls under the
                    // navigation and tab bars.
                    .ignoresSafeArea()
                }
            }
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
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            newRoutineName = ""
                            isNamingNewRoutine = true
                        } label: {
                            Image(systemName: "plus")
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
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .play(let id):
                    if let ex = store.exercises.first(where: { $0.id == id }) {
                        ExerciseIntroView(exercise: ex) {
                            navigationPath.append(ExerciseRoute.playback(id))
                        }
                    }
                case .playback(let id):
                    if let ex = store.exercises.first(where: { $0.id == id }) {
                        PlaybackView(exercise: ex)
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
                case .user:
                    // Never appended from this tab; usernames only show in Community.
                    EmptyView()
                }
            }
        }
    }
}
