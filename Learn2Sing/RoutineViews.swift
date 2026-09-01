//
//  RoutineViews.swift
//  Learn2Sing
//

import SwiftUI

/// One exercise row of the routine and exercise-queue screens: the exercise's
/// name, with the same MIDI pattern thumbnail the Exercises tab draws on the
/// trailing edge of its rows — on the edit-routine screen sitting just inside
/// the drag handle its always-on edit mode shows. An exercise with no notes gets
/// no thumbnail, exactly as on that tab.
private struct RoutineExerciseRow: View {
    @EnvironmentObject private var store: ExerciseStore
    let exerciseID: UUID

    private var pattern: [MIDINote] { store.notes(for: exerciseID) }

    var body: some View {
        HStack {
            Text(store.exercises.first { $0.id == exerciseID }?.localizedName ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
            if !pattern.isEmpty {
                MIDIPatternThumbnail(notes: pattern)
            }
        }
    }
}

/// The inline-editable routine name at the top of the edit-routine screen.
/// Commits (via the store) when the user submits, focus moves away, or the
/// screen goes away — see RoutineDetailsField for why leaving counts. An empty
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
            .onDisappear(perform: commit)
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

/// The inline-editable routine description, sitting under the name field on the
/// edit-routine screen. Commits (via the store) when focus moves away or the
/// screen goes away — leaving while still editing is the norm for a routine with
/// no exercises, where there's nothing else on screen to tap to end editing, and
/// popping the screen doesn't report the lost focus. Unlike the name, an empty
/// description is allowed.
private struct RoutineDetailsField: View {
    @EnvironmentObject private var store: ExerciseStore
    let routineID: UUID
    @State private var details: String
    @FocusState private var isFocused: Bool

    init(routineID: UUID, details: String) {
        self.routineID = routineID
        _details = State(initialValue: details)
    }

    var body: some View {
        TextField("Shown before the routine starts", text: $details, axis: .vertical)
            .lineLimit(3...8)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        store.setRoutineDetails(routineID, to: details)
    }
}

/// Edit screen for one routine, reached by swiping right on it in the Home tab.
/// Deliberately the same layout as the Exercises tab's edit-categories screen —
/// draggable rows, a trash toggle that swaps the drag handles for delete buttons,
/// and a + button — minus the per-row counts, with the rows being the routine's
/// exercises instead. Sectioned like the exercise settings screen: the name and
/// description sit in their own labelled sections above the "Exercises" one.
struct RoutineEditView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

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
            RoutineExerciseRow(exerciseID: exerciseID)
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
                Section("Name") {
                    RoutineNameField(routineID: routineID, name: routine.name)
                        .settingHelp(L("What this routine is called on the Home tab."))
                }
                Section("Description") {
                    RoutineDetailsField(routineID: routineID, details: routine.details)
                        .settingHelp(L("Your note on this routine, shown on the screen before it starts."))
                }
                Section("Exercises") {
                    ForEach(routine.exerciseIDs, id: \.self) { exerciseID in
                        exerciseRow(exerciseID)
                            .settingHelp(L("The exercises this routine plays, in order. Drag by the handle on the right to rearrange them."))
                    }
                    .onMove { source, destination in
                        store.moveRoutineExercises(routineID, from: source, to: destination)
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(L("Edit Routine"))
        .navigationBarTitleDisplayMode(.inline)
        // The description field's return key inserts a newline rather than
        // closing the keyboard, so swiping down over it is what puts it away —
        // the same everywhere else in the app.
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleDeleteMode()
                } label: {
                    Image(systemName: isDeletingExercises ? "trash.fill" : "trash")
                }
                .explain(L("Swaps the drag handles for delete buttons, to take exercises off this list. They stay in your library."))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAddExercises()
                } label: {
                    Image(systemName: "plus")
                }
                .explain(L("Opens your library, where you tick the exercises this list is made of."))
            }
        }
    }
}

/// The screen shown before a queue of exercises plays: an "Exercise Queue"
/// section listing what will play, and a start button along the bottom.
/// Optionally headed by a name and description — a routine's, which is the
/// screen this started as. The Home tab's recommendation card opens the very
/// same screen with nothing above the queue, since a suggestion has neither to
/// show.
///
/// The rows work like the Home tab's own: tap one to play, long-press to drag
/// it somewhere else, swipe it left to drop it. (Not the edit-routine screen's
/// always-on edit mode, which these rows started out sharing — a List in edit
/// mode keeps the whole row for its own drag, leaving no swipe and no tap. The
/// header's shuffle button reorders without any dragging at all.)
///
/// Reordering — by dragging or shuffling — and dropping an exercise change
/// `order` only, which the Home tab keeps for this play-through and resets the
/// next time the screen is opened; nothing stored is touched, so a swiped-away
/// exercise stays in the routine it belongs to.
///
/// Tapping a row starts the queue from that exercise rather than from the top:
/// `onSelect` opens its intro screen the same way the start button opens the
/// first one's, so the run carries on down the queue from there.
struct ExerciseQueueIntroView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    /// The name and description drawn above the queue, or nil for a queue that
    /// has neither.
    var heading: (name: String, details: String)? = nil
    /// The exercises to play, in this play-through's order.
    @Binding var order: [UUID]
    /// What the navigation bar reads.
    let title: String
    /// What the button along the bottom reads. Already translated, since it is
    /// a value rather than a literal SwiftUI resolves itself.
    var startTitle = L("Start Routine")
    /// Tap on a queued exercise: start the play-through from that one. nil makes
    /// the rows display-only.
    var onSelect: ((UUID) -> Void)? = nil
    let onStart: () -> Void

    /// The name and description, styled exactly like the exercise intro
    /// screen's. Sits on the list's own background rather than in a cell, so it
    /// reads as a heading and not as another row.
    private func headerRow(_ heading: (name: String, details: String)) -> some View {
        let details = heading.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 16) {
            Text(heading.name)
                .font(.largeTitle.weight(.bold))

            Text(details.isEmpty ? L("No description.") : details)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Matches the exercise intro screen's .padding() around its heading, so
        // the two titles start at the same height and the same inset.
        .listRowInsets(EdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .settingHelp(L("The name and description of this routine, as written on its edit screen."))
    }

    /// One queued exercise: the routine row, made tappable (start here) and
    /// swipeable (drop from this play-through).
    private func queueRow(_ exerciseID: UUID) -> some View {
        RoutineExerciseRow(exerciseID: exerciseID)
            // The row only draws where it has content, so the empty space beside
            // a short name would otherwise not take the tap.
            .contentShape(Rectangle())
            // A tap gesture rather than a Button: a Button fires on touch-up
            // anywhere inside its own bounds, and the row is the full width of
            // the screen, so the swipe below would end inside it and open the
            // exercise instead of offering to remove it.
            .onTapGesture { onSelect?(exerciseID) }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    withAnimation { order.removeAll { $0 == exerciseID } }
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            }
            .settingHelp(L("Tap to start here instead of at the top. Drag to reorder, or swipe left to leave it out. This is for this run only, and the list itself is left as it is."))
    }

    private var exercisesHeader: some View {
        HStack {
            Text("Exercise Queue")
            Spacer()
            Button {
                withAnimation { order.shuffle() }
            } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Shuffle exercises")
            .explain(L("Puts the exercises below in a random order for this run only."))
        }
        .textCase(nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if let heading {
                    Section {
                        headerRow(heading)
                    }
                }
                Section {
                    ForEach(order, id: \.self) { exerciseID in
                        queueRow(exerciseID)
                    }
                    .onMove { source, destination in
                        order.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    exercisesHeader
                }
            }
            // Drops the list's own top inset so the heading sits as high as the
            // exercise intro screen's, which is a plain ScrollView.
            .contentMargins(.top, 0, for: .scrollContent)

            Button(action: onStart) {
                Text(startTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            // A queue every exercise has been swiped out of has nothing to
            // start: the button would push a play route resolving to a blank
            // screen.
            .disabled(order.isEmpty)
            .opacity(order.isEmpty ? 0.4 : 1)
            .explain(L("Sings the exercises above one after the other, from the top."))
            .padding(.horizontal)
            .padding(.bottom)
        }
        // So the strip the button sits on matches the list above it.
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shown when a routine that has exercises is tapped in the Home tab, before the
/// first exercise's own intro screen. The routine's counterpart to
/// ExerciseIntroView: the queue screen above, headed by the routine's name and
/// description and with the routine's edit screen a toolbar button away.
struct RoutineIntroView: View {
    let routine: Routine
    /// The exercises to play, in this play-through's order.
    @Binding var order: [UUID]
    /// Opens this routine's edit screen from the toolbar — the routine's
    /// counterpart to the settings button on the exercise intro screen, in the
    /// same place and with the same symbol.
    let onSettings: () -> Void
    /// Tap on a queued exercise: start the routine from that one.
    var onSelect: ((UUID) -> Void)? = nil
    let onStart: () -> Void

    var body: some View {
        ExerciseQueueIntroView(heading: (routine.name, routine.details),
                               order: $order,
                               title: routine.name,
                               onSelect: onSelect,
                               onStart: onStart)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSettings) {
                        Label("Edit Routine", systemImage: "slider.horizontal.3")
                    }
                    .explain(L("Opens this routine's own screen, where its name, description and exercises are kept."))
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
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

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
            Text(store.exercises.first { $0.id == exerciseID }?.localizedName ?? "")
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
        .settingHelp(L("Your favourite exercises, in the order the Home tab shows them. Drag by the handle on the right to rearrange them."))
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
        .navigationTitle(L("Edit Favourites"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleDeleteMode()
                } label: {
                    Image(systemName: isDeletingExercises ? "trash.fill" : "trash")
                }
                .explain(L("Swaps the drag handles for delete buttons, to take exercises off this list. They stay in your library."))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    onAddExercises()
                } label: {
                    Image(systemName: "plus")
                }
                .explain(L("Opens your library, where you tick the exercises this list is made of."))
            }
        }
    }
}

/// Multi-select exercise picker, reached from an edit screen's + button. The
/// same categorized list as the Exercises tab (tap a header to collapse), but
/// rows can't be started, edited, or dragged — tapping one toggles its
/// membership in the target list, shown by a leading check circle. Changes
/// apply immediately, so leaving the screen "adds" the selection. Shared by
/// the edit-routine and edit-favourites screens and the recommendation
/// whitelist, which titles it differently because it deselects as much as it
/// adds — and by the sung delay test, which picks a single exercise.
struct ExerciseMultiPickerList: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    /// The ticked rows. nil draws no check circles at all, for a list where a tap
    /// is a one-off choice rather than a change to a set (the sung delay test).
    var selectedIDs: Set<UUID>? = nil
    let onToggle: (UUID) -> Void
    var title = L("Add Exercises")

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
                                isSelected: selected?.contains($0.id))
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
            onSelect: { id, _ in onToggle(id) },
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
        .navigationTitle(title)
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

/// The exercises the Home tab's "Recommended" category may draw from, reached
/// from Settings ▸ Exercises. Every exercise in the library is listed; the
/// ticked ones start out as those that shipped with the app.
struct RecommendationWhitelistView: View {
    @EnvironmentObject private var store: ExerciseStore

    var body: some View {
        ExerciseMultiPickerList(
            selectedIDs: store.recommendationWhitelist,
            onToggle: { store.toggleWhitelisted($0) },
            title: L("Whitelisted Exercises")
        )
    }
}
