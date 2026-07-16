//
//  RoutineViews.swift
//  Learn2Sing
//

import SwiftUI

/// The inline-editable routine name at the top of the edit-routine screen.
/// Commits (via the store) when the user submits or focus moves away; an empty
/// name is refused and the text reverts.
private struct RoutineNameField: View {
    @EnvironmentObject private var store: ExerciseStore
    let routineID: UUID
    @State private var name: String
    @FocusState private var isFocused: Bool

    init(routineID: UUID, name: String) {
        self.routineID = routineID
        _name = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $name)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Revert instead of committing an empty name.
            name = store.routines.first(where: { $0.id == routineID })?.name ?? name
        } else {
            store.renameRoutine(routineID, to: trimmed)
            name = trimmed
        }
    }
}

/// Edit screen for one routine, reached by swiping right on it in the Home tab.
/// Deliberately the same layout as the Exercises tab's edit-categories screen —
/// draggable rows, a trash toggle that swaps the drag handles for delete buttons,
/// and a + button — minus the per-row counts, with the routine's name editable in
/// a field at the top and the rows being the routine's exercises instead.
struct RoutineEditView: View {
    @EnvironmentObject private var store: ExerciseStore
    let routineID: UUID
    /// Called by the + button; the Home stack pushes the exercise picker.
    let onAddExercises: () -> Void

    /// Always active so the exercise rows show drag handles, exactly like the
    /// edit-categories screen; turned off while deleting (see below).
    @State private var editMode: EditMode = .active

    /// True while the drag handles are swapped for per-row delete buttons.
    /// Toggled by the trash toolbar button.
    @State private var isDeletingExercises = false

    private var routine: Routine? {
        store.routines.first { $0.id == routineID }
    }

    private func exerciseRow(_ exerciseID: UUID) -> some View {
        HStack {
            Text(store.exercises.first { $0.id == exerciseID }?.name ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if isDeletingExercises {
                Button {
                    withAnimation { store.removeExercise(exerciseID, fromRoutine: routineID) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Swap the rows' drag handles for delete buttons and back. Edit mode is what
    /// makes the List show drag handles, so it's turned off while deleting.
    private func toggleDeleteMode() {
        withAnimation {
            isDeletingExercises.toggle()
            editMode = isDeletingExercises ? .inactive : .active
        }
    }

    var body: some View {
        List {
            if let routine {
                Section {
                    RoutineNameField(routineID: routineID, name: routine.name)
                }
                Section {
                    ForEach(routine.exerciseIDs, id: \.self) { exerciseID in
                        exerciseRow(exerciseID)
                    }
                    .onMove { source, destination in
                        store.moveRoutineExercises(routineID, from: source, to: destination)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Edit Routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleDeleteMode()
                } label: {
                    Image(systemName: isDeletingExercises ? "trash.fill" : "trash")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAddExercises()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

/// Edit screen for the favourites list, reached from the + button in the Home
/// tab's "Favourites" header. The same layout as the edit-routine screen —
/// draggable rows, a trash toggle that swaps the drag handles for delete
/// buttons, and a + button pushing the exercise picker — minus the name field,
/// since the built-in category can't be renamed.
struct FavouritesEditView: View {
    @EnvironmentObject private var store: ExerciseStore
    /// Called by the + button; the Home stack pushes the exercise picker.
    let onAddExercises: () -> Void

    /// Always active so the exercise rows show drag handles, exactly like the
    /// edit-routine screen; turned off while deleting (see below).
    @State private var editMode: EditMode = .active

    /// True while the drag handles are swapped for per-row delete buttons.
    /// Toggled by the trash toolbar button.
    @State private var isDeletingExercises = false

    private func exerciseRow(_ exerciseID: UUID) -> some View {
        HStack {
            Text(store.exercises.first { $0.id == exerciseID }?.name ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if isDeletingExercises {
                Button {
                    withAnimation { store.removeFavourite(exerciseID) }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Swap the rows' drag handles for delete buttons and back. Edit mode is what
    /// makes the List show drag handles, so it's turned off while deleting.
    private func toggleDeleteMode() {
        withAnimation {
            isDeletingExercises.toggle()
            editMode = isDeletingExercises ? .inactive : .active
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(store.favourites, id: \.self) { exerciseID in
                    exerciseRow(exerciseID)
                }
                .onMove { source, destination in
                    store.moveFavourites(from: source, to: destination)
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Edit Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleDeleteMode()
                } label: {
                    Image(systemName: isDeletingExercises ? "trash.fill" : "trash")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAddExercises()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

/// Multi-select exercise picker, reached from an edit screen's + button. The
/// same categorized list as the Exercises tab (tap a header to collapse), but
/// rows can't be started, edited, or dragged — tapping one toggles its
/// membership in the target list, shown by a leading check circle. Changes
/// apply immediately, so leaving the screen "adds" the selection. Shared by
/// the edit-routine and edit-favourites screens.
private struct ExerciseMultiPickerList: View {
    @EnvironmentObject private var store: ExerciseStore
    let selectedIDs: Set<UUID>
    let onToggle: (UUID) -> Void

    /// Categories the user has collapsed. Their exercises are hidden and the
    /// header shows the exercise count in parentheses instead.
    @State private var collapsedCategories: Set<String> = []

    /// Exercises with no category, or whose category was deleted, shown in an
    /// unlabelled section like on the Exercises tab.
    private var uncategorized: [Exercise] {
        store.exercises.filter { $0.category.isEmpty || !store.categories.contains($0.category) }
    }

    private var listSections: [ExerciseListSection] {
        let selected = selectedIDs
        func rows(_ exercises: [Exercise]) -> [ExerciseListRow] {
            exercises.map {
                ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id),
                                isSelected: selected.contains($0.id))
            }
        }
        var result: [ExerciseListSection] = []
        for category in store.categories {
            let items = store.exercises.filter { $0.category == category }
            let isCollapsed = collapsedCategories.contains(category)
            result.append(ExerciseListSection(category: category,
                                              isCollapsed: isCollapsed,
                                              totalCount: items.count,
                                              items: isCollapsed ? [] : rows(items)))
        }
        let uncategorized = self.uncategorized
        if !uncategorized.isEmpty {
            result.append(ExerciseListSection(category: "",
                                              isCollapsed: false,
                                              totalCount: uncategorized.count,
                                              items: rows(uncategorized)))
        }
        return result
    }

    var body: some View {
        ExerciseCollectionList(
            sections: listSections,
            onSelect: onToggle,
            onToggleCollapse: { category in
                if collapsedCategories.contains(category) {
                    collapsedCategories.remove(category)
                } else {
                    collapsedCategories.insert(category)
                }
            }
        )
        // Span the full screen like a List so content scrolls under the
        // navigation and tab bars.
        .ignoresSafeArea()
        .navigationTitle("Add Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
    }
}

/// The exercise picker for a routine, reached from the edit-routine screen's
/// + button.
struct RoutineExercisePickerView: View {
    @EnvironmentObject private var store: ExerciseStore
    let routineID: UUID

    var body: some View {
        ExerciseMultiPickerList(
            selectedIDs: Set(store.routines.first(where: { $0.id == routineID })?.exerciseIDs ?? []),
            onToggle: { store.toggleExercise($0, in: routineID) }
        )
    }
}

/// The exercise picker for the favourites list, reached from the
/// edit-favourites screen's + button.
struct FavouritesExercisePickerView: View {
    @EnvironmentObject private var store: ExerciseStore

    var body: some View {
        ExerciseMultiPickerList(
            selectedIDs: Set(store.favourites),
            onToggle: { store.toggleFavourite($0) }
        )
    }
}
