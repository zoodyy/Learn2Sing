//
//  HomeView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

/// The Home tab: built-in categories over the user's library, starting with
/// "Recent" — the last five exercises that played through to the end. The
/// categories look and behave like the Exercises tab's (tap to collapse,
/// long-press to rearrange) but never show exercise counts, and the reorder
/// screen has no add, delete, or rename — the categories are fixed.
struct HomeView: View {
    @EnvironmentObject private var store: ExerciseStore
    @State private var navigationPath = NavigationPath()

    private static let recentCategory = "Recent"

    /// The built-in categories in the user's display order.
    @State private var categories: [String] = [HomeView.recentCategory]

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

    private func exercises(in category: String) -> [Exercise] {
        switch category {
        case Self.recentCategory: recentExercises
        default: []
        }
    }

    private var listSections: [ExerciseListSection] {
        categories.map { category in
            let items = exercises(in: category).map {
                ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id))
            }
            let isCollapsed = collapsedCategories.contains(category)
            return ExerciseListSection(category: category,
                                       isCollapsed: isCollapsed,
                                       totalCount: items.count,
                                       items: isCollapsed ? [] : items,
                                       showsCount: false)
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
                        onSelect: { navigationPath.append(ExerciseRoute.play($0)) },
                        onSettings: { navigationPath.append(ExerciseRoute.settings($0)) },
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
                }
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
                case .user:
                    // Never appended from this tab; usernames only show in Community.
                    EmptyView()
                }
            }
        }
    }
}
