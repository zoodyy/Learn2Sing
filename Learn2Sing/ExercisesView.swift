import SwiftUI

/// Whether an exercise stays in the user's own library or also appears on the
/// Community tab.
enum ExerciseVisibility: String, Codable, CaseIterable {
    case `private`, `public`

    var label: String { L(rawValue.capitalized) }
}

struct Exercise: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var details: String = ""          // shown on the intro screen before playback
    var category: String = ""         // group it belongs to in the list ("" = none)
    var pitchShift: Int = 0           // transpose all notes by this many semitones
    var bpm: Double = 120             // playback tempo in beats per minute
    var repeatCount: Int = 1          // how many times the pattern is played back
    var transposePerRepeat: Int = 0   // semitones to shift up each repetition (negative = down)
    var switchDirectionAfter: Int = 0 // flip the transpose direction after this many repetitions (0 = never)
    var speedPerRepeat: Int = 0       // BPM added to each repetition's tempo (negative = slower)
    var beatsBetweenReps: Double = 0  // silent beats inserted between repetitions
    var visibility: ExerciseVisibility = .private // public exercises show on the Community tab
    var uploaderName: String = ""     // profile username stamped when made public
    // Set when the exercise was copied into the library from the Community tab,
    // to the uploader it came from (which may itself be "" — uploaders without a
    // profile username). nil means the user created it themselves.
    var downloadedFrom: String? = nil

    init(name: String) { self.name = name }

    private enum CodingKeys: String, CodingKey {
        case id, name, details, category, pitchShift, bpm, speed, repeatCount, transposePerRepeat, switchDirectionAfter, speedPerRepeat, beatsBetweenReps, visibility, uploaderName, downloadedFrom
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        pitchShift = try c.decodeIfPresent(Int.self, forKey: .pitchShift) ?? 0
        if let bpm = try c.decodeIfPresent(Double.self, forKey: .bpm) {
            self.bpm = bpm
        } else if let speed = try c.decodeIfPresent(Double.self, forKey: .speed) {
            // Legacy: `speed` was a percentage of a 120 BPM baseline.
            bpm = (120.0 * speed / 100.0).rounded()
        }
        repeatCount = try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1
        transposePerRepeat = try c.decodeIfPresent(Int.self, forKey: .transposePerRepeat) ?? 0
        switchDirectionAfter = try c.decodeIfPresent(Int.self, forKey: .switchDirectionAfter) ?? 0
        speedPerRepeat = try c.decodeIfPresent(Int.self, forKey: .speedPerRepeat) ?? 0
        beatsBetweenReps = try c.decodeIfPresent(Double.self, forKey: .beatsBetweenReps) ?? 0
        visibility = try c.decodeIfPresent(ExerciseVisibility.self, forKey: .visibility) ?? .private
        uploaderName = try c.decodeIfPresent(String.self, forKey: .uploaderName) ?? ""
        downloadedFrom = try c.decodeIfPresent(String.self, forKey: .downloadedFrom)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Lowercase so the id is lowercase in the community request body; UUID
        // decoding is case-insensitive, so this round-trips unchanged.
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(details, forKey: .details)
        try c.encode(category, forKey: .category)
        try c.encode(pitchShift, forKey: .pitchShift)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(repeatCount, forKey: .repeatCount)
        try c.encode(transposePerRepeat, forKey: .transposePerRepeat)
        try c.encode(switchDirectionAfter, forKey: .switchDirectionAfter)
        try c.encode(speedPerRepeat, forKey: .speedPerRepeat)
        try c.encode(beatsBetweenReps, forKey: .beatsBetweenReps)
        try c.encode(visibility, forKey: .visibility)
        try c.encode(uploaderName, forKey: .uploaderName)
        // Omitted when nil, so exercises the user made themselves upload exactly
        // the same document body as before this field existed.
        try c.encodeIfPresent(downloadedFrom, forKey: .downloadedFrom)
    }
}

// MARK: - Repetition layout

/// Where each repetition of an exercise's pattern sits on the timeline.
///
/// Repetitions don't all last the same number of beats once "speed up per
/// repetition" is set. The timeline is still played at the exercise's own tempo
/// throughout, so a repetition is made to *sound* faster by squeezing its beats
/// together and slower by spreading them apart: that factor is its `scale` — 0.5
/// is twice the tempo — and every repetition after it shifts along accordingly.
/// With no speed change every scale is 1 and the repetitions sit on a plain grid.
struct RepeatLayout {
    /// One repetition's length in beats at the exercise's own tempo: the pattern
    /// rounded up to a whole beat, plus any silence between repetitions.
    private(set) var span: Double
    /// The beat each repetition starts on, ascending.
    private(set) var starts: [Double]
    /// How each repetition's beats are scaled; same count as `starts`.
    private(set) var scales: [Double]

    /// The layout of content that doesn't repeat.
    init() {
        span = 0
        starts = []
        scales = []
    }

    /// `count` repetitions of `span` beats, the `rep`th of them scaled by `scale(rep)`.
    init(span: Double, count: Int, scale: (Int) -> Double = { _ in 1 }) {
        self.span = span
        starts = []
        scales = []
        var start = 0.0
        for rep in 0..<max(0, count) {
            let s = scale(rep)
            starts.append(start)
            scales.append(s)
            start += span * s
        }
    }

    var count: Int { starts.count }

    /// Index of the repetition `beat` falls in. The lead-in (a negative beat) belongs
    /// to the first repetition and anything past the end stays with the last, so the
    /// result can always be used to index a per-repetition table.
    func index(at beat: Double) -> Int {
        // Searched rather than walked: this runs per note on every rendered frame,
        // and an exercise can repeat a hundred times over.
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if beat >= starts[mid] - 1e-6 { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// The beat `beats` beats of room before repetition `rep` begins comes out at.
    /// The silence in front of a repetition is the tail of the one before it, so it
    /// is measured at *that* repetition's tempo; the lead-in before the first is
    /// never scaled.
    func beat(_ beats: Double, before rep: Int, startingAt startBeat: Double) -> Double {
        let scale = rep >= 1 && rep - 1 < scales.count ? scales[rep - 1] : 1
        return startBeat - beats * scale
    }
}

extension Exercise {
    /// Largest per-repetition tempo change the settings screen accepts, in BPM.
    static let maxSpeedPerRepeat = 150
    /// The tempo a single repetition is held inside, in BPM. A long run of speed
    /// steps would otherwise reach a standstill (or a tempo running backwards) at
    /// one end and an unsingable blur at the other.
    static let repetitionTempoLimits = (min: 20.0, max: 400.0)

    /// Tempo of a repetition (0-based) in BPM: `speedPerRepeat` faster than the one
    /// before it, held inside `repetitionTempoLimits`.
    func tempo(forRepetition rep: Int) -> Double {
        let raw = bpm + Double(rep) * Double(speedPerRepeat)
        return min(max(raw, Self.repetitionTempoLimits.min), Self.repetitionTempoLimits.max)
    }

    /// Lay this exercise's repetitions out over a pattern `span` beats long (rounded
    /// up to a whole beat, plus the silence between repetitions), scaling each one so
    /// a timeline played at `bpm` sounds every repetition at its own tempo.
    func repeatLayout(span: Double) -> RepeatLayout {
        RepeatLayout(span: span, count: max(1, repeatCount)) { rep in
            bpm > 0 ? bpm / tempo(forRepetition: rep) : 1
        }
    }
}

enum ExerciseRoute: Hashable {
    case play(UUID)      // the intro/description screen shown before playback
    case playback(UUID)  // the actual note-scrolling playback screen
    case settings(UUID)
    case edit(UUID)
    // A community uploader's profile. Carries the public user id their exercises
    // are fetched by as well as the username the screen is titled with, since the
    // profile asks the server for that id's records rather than sifting the
    // Community tab's list for a matching name.
    case user(id: String, name: String)
    case editCategories        // the drag-to-reorder/rename screen for the tab's categories
    case routine(UUID)         // a routine's edit screen (Home tab)
    case routineIntro(UUID)    // a routine's description/exercise-order screen (Home tab)
    case routinePicker(UUID)   // multi-select exercise picker for a routine (Home tab)
    case favourites            // the edit-favourites screen (Home tab)
    case favouritesPicker      // multi-select exercise picker for favourites (Home tab)
    // Playing a routine walks these two alternately through the routine's
    // exercises: intro of exercise #index, its playback, intro of #index+1, …
    case routinePlay(UUID, Int)      // intro screen of the routine's #index exercise
    case routinePlayback(UUID, Int)  // playback of the routine's #index exercise
}

/// The inline-editable category name on the edit-categories screen. Edits are
/// committed (via `onRename`) when the user submits, focus moves away, or the row
/// goes away — leaving while still editing is the norm for a category just made
/// with the + button, and the row being removed doesn't report the lost focus. A
/// commit the store refuses — duplicate name, empty after trimming — reverts the
/// text.
private struct CategoryNameField: View {
    let category: String
    /// The screen's focus, keyed by category name, so a category the + button just
    /// created can be handed the keyboard from outside the row.
    let focus: FocusState<String?>.Binding
    let onRename: (String) -> Void
    @State private var name: String

    /// What the field shows, and what an edit is measured against. The app's own
    /// categories are stored in English and displayed translated, so leaving the
    /// field untouched must not read as a rename.
    private var displayName: String { ExerciseCategoryName.localized(category) }

    /// `isNew` starts the field empty: the category exists already, under the
    /// placeholder name the + button gave it, and the user shouldn't have to clear
    /// that before typing their own. Leaving it empty keeps the placeholder name.
    init(category: String,
         isNew: Bool,
         focus: FocusState<String?>.Binding,
         onRename: @escaping (String) -> Void) {
        self.category = category
        self.focus = focus
        self.onRename = onRename
        _name = State(initialValue: isNew ? "" : ExerciseCategoryName.localized(category))
    }

    var body: some View {
        TextField("Name", text: $name)
            .focused(focus, equals: category)
            .onSubmit(commit)
            // Every row sees every focus change; only the one losing it commits.
            .onChange(of: focus.wrappedValue) { old, _ in
                if old == category { commit() }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != displayName {
            onRename(trimmed)
        }
        // On success the row is replaced (its ForEach identity is the name), so
        // this only shows through when the rename was refused: revert.
        name = displayName
    }
}

/// The edit-categories screen: every category as a draggable row whose name is an
/// inline text field, with a trash button that swaps the drag handles for delete
/// buttons and a + that adds another category. Opened by long-pressing a category
/// header on the Exercises tab, or from its + menu.
///
/// Pushed onto the tab's navigation stack rather than swapped in behind the same
/// title, so it is left the way every other screen is: the back button, or the
/// system's swipe in from the leading edge, which slides the screen off the list
/// it belongs to. Either way the edits stay — every change is written to the
/// store as it is made, and a name still being typed is committed when the screen
/// goes (see CategoryNameField).
private struct CategoryEditView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    /// A category the + button just created, waiting to be scrolled to and handed
    /// the keyboard. Cleared once it has focus. Owned by the tab, since its own +
    /// menu opens this screen with a new category already on it.
    @Binding var newCategory: String?

    /// Renames through the tab, which carries the category's collapse state over
    /// to the new name. Old name first.
    let onRename: (String, String) -> Void

    /// Always active so the rows show drag handles; turned off while deleting.
    @State private var editMode: EditMode = .active

    /// True while the drag handles are swapped for per-row delete buttons.
    /// Toggled by the trash toolbar button.
    @State private var isDeletingCategories = false

    /// Which category's name field currently has the keyboard. nil when nothing
    /// is being renamed.
    @FocusState private var focusedCategory: String?

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(store.categories, id: \.self) { category in
                    row(category)
                }
                .onMove { source, destination in
                    store.moveCategory(from: source, to: destination)
                }
            }
            .environment(\.editMode, $editMode)
            // A category the + button just added sits at the bottom of the list,
            // usually off screen — and a row that was never laid out can't take
            // the keyboard. Bring it into view first, then focus it. Runs on
            // appear too, since the same button opens this screen.
            .task(id: newCategory) {
                guard let name = newCategory else { return }
                proxy.scrollTo(name, anchor: .center)
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                focusedCategory = name
                newCategory = nil
            }
        }
        .navigationTitle(L("Edit Categories"))
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleDeleteMode()
                } label: {
                    Image(systemName: isDeletingCategories ? "trash.fill" : "trash")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newCategory = Self.addCategory(to: store)
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }

    /// One category's row. Rendered as a plain row (not `Section(header:)`) so the
    /// List's native `.onMove` can actually move it; in delete mode the drag
    /// handle is replaced by a delete button — "No Category" gets neither, since
    /// it can't be renamed or deleted.
    private func row(_ category: String) -> some View {
        let count = store.exercises.filter { $0.category == category }.count
        return HStack {
            if category == ExerciseStore.noCategoryName {
                // Fill the row like the text field does so the count stays trailing.
                Text(ExerciseCategoryName.localized(category))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CategoryNameField(category: category,
                                  isNew: category == newCategory,
                                  focus: $focusedCategory) { newName in
                    onRename(category, newName)
                }
            }
            Text(verbatim: "(\(count))")
                .foregroundStyle(.secondary)
            if isDeletingCategories && category != ExerciseStore.noCategoryName {
                Button {
                    withAnimation { store.deleteCategory(category) }
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
            isDeletingCategories.toggle()
            editMode = isDeletingCategories ? .inactive : .active
        }
    }

    /// Create a category under a placeholder name — numbered if the user already
    /// has one by that name, since the store refuses a duplicate — and return it,
    /// so its row can be handed the keyboard. Like a new exercise, it is named
    /// where it lives rather than in an alert beforehand. Shared with the tab's
    /// own "New Category", which creates one on the way to this screen.
    static func addCategory(to store: ExerciseStore) -> String {
        let base = L("New Category")
        var name = base
        var suffix = 2
        while store.categories.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        store.addCategory(name)
        return name
    }
}

struct ExercisesView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @EnvironmentObject private var toasts: ToastCenter
    // Typed (not NavigationPath) so pops can be inspected for the saved toasts.
    @State private var navigationPath: [ExerciseRoute] = []

    /// Every exercise the list was showing when the user started playing one, in
    /// list order — what the score screen's "Next" button walks along. It runs
    /// straight through the category boundaries, so the last exercise of a
    /// category leads to the first one of the category below it; a collapsed
    /// category shows no exercises and so contributes none. Captured on the tap
    /// rather than recomputed later, so a filter or search change can't reorder it
    /// mid-play.
    @State private var playQueue: [UUID] = []

    /// Categories the user has collapsed. Their exercises are hidden and the
    /// header shows the exercise count in parentheses instead.
    @State private var collapsedCategories: Set<String> = []

    /// True while an exercise is actually held in a drag, which the title says.
    @State private var isDraggingExercise = false

    /// A category the + button just created, waiting to be scrolled to and handed
    /// the keyboard on the edit-categories screen. Cleared once it has focus.
    @State private var newCategory: String?

    /// The filters picked in the toolbar's filter menu. Empty (the default) shows
    /// the whole library. Deliberately not persisted: a filter that survived a
    /// relaunch would look like exercises had gone missing.
    @State private var activeFilters: Set<ExerciseFilter> = []

    /// The search field's text. Unlike the Community tab's field — which also
    /// looks up uploaders — this one only matches exercise names and descriptions,
    /// since everything here is the user's own.
    @State private var searchText = ""

    /// `searchText` without surrounding whitespace; empty means "not searching".
    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Case- and diacritic-insensitive substring match, so "jose" finds "José".
    private static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The exercises the list may show, narrowed by the active filters only. The
    /// search is applied per category on top of this, since a category whose own
    /// name matches keeps all of its exercises.
    private var filteredExercises: [Exercise] {
        guard !activeFilters.isEmpty else { return store.exercises }
        return store.exercises.filter {
            activeFilters.matches($0, isBundled: store.isBundled($0.id))
        }
    }

    /// Does this exercise match the search text? Bundled exercises are shown
    /// under their translated name, so the search has to look at that as well as
    /// the stored English one.
    private func matchesQuery(_ exercise: Exercise, _ query: String) -> Bool {
        Self.matches(exercise.name, query) || Self.matches(exercise.details, query)
            || Self.matches(exercise.localizedName, query)
            || Self.matches(exercise.localizedDetails, query)
    }

    /// Does the category's own name match the search text? App-provided
    /// categories are listed under their translated name, so — as with exercises
    /// — both that and the stored English one are checked.
    private func matchesQuery(category: String, _ query: String) -> Bool {
        !category.isEmpty
            && (Self.matches(category, query)
                || Self.matches(ExerciseCategoryName.localized(category), query))
    }

    /// The list content in normal mode: one section per category (in the user's
    /// order, empty ones included) plus the uncategorized group — exercises with
    /// no category, or whose category was deleted, so none are ever lost from the
    /// list — at the end, ready to hand to the UIKit-backed list that does the
    /// rendering and drag & drop.
    private var listSections: [ExerciseListSection] {
        func rows(_ exercises: [Exercise]) -> [ExerciseListRow] {
            exercises.map { ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id)) }
        }
        let exercises = filteredExercises
        let query = self.query
        let isSearching = !query.isEmpty
        let isFiltering = !activeFilters.isEmpty || isSearching
        var result: [ExerciseListSection] = []
        for category in store.categories {
            let inCategory = exercises.filter { $0.category == category }
            // A category the search text names is shown whole — the user asked
            // for the category, not for exercises inside it — and stays visible
            // even when it's empty, so the name they typed doesn't come back
            // "no results".
            let categoryMatches = isSearching && matchesQuery(category: category, query)
            let items = isSearching && !categoryMatches
                ? inCategory.filter { matchesQuery($0, query) }
                : inCategory
            // Empty categories normally stay visible (showing "(0)"), but while
            // filtering a category with no match left is just noise.
            if items.isEmpty && isFiltering && !categoryMatches { continue }
            // A collapsed category would hide its matches, so results are always
            // shown expanded; the collapse state is left untouched underneath and
            // comes back when the field is cleared.
            let isCollapsed = !isSearching && collapsedCategories.contains(category)
            result.append(ExerciseListSection(category: category,
                                              isCollapsed: isCollapsed,
                                              totalCount: items.count,
                                              items: isCollapsed ? [] : rows(items),
                                              // While searching there's nothing
                                              // to collapse — the chevron would
                                              // only offer an action that does
                                              // nothing until the field clears.
                                              showsChevron: !isSearching))
        }
        let uncategorized = exercises.filter {
            ($0.category.isEmpty || !store.categories.contains($0.category))
                && (!isSearching || matchesQuery($0, query))
        }
        if !uncategorized.isEmpty {
            result.append(ExerciseListSection(category: "",
                                              isCollapsed: false,
                                              totalCount: uncategorized.count,
                                              items: rows(uncategorized)))
        }
        return result
    }

    /// The exercise listed below `id` — in the next category, if `id` was the last
    /// one of its own — skipping any that have been deleted since. nil at the very
    /// end of the list, where the Next button is left out.
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

    /// Menu toggle state for one filter.
    private func filterBinding(_ filter: ExerciseFilter) -> Binding<Bool> {
        Binding(
            get: { activeFilters.contains(filter) },
            set: { isOn in
                if isOn {
                    activeFilters.insert(filter)
                } else {
                    activeFilters.remove(filter)
                }
            }
        )
    }

    /// Rename via the store, then carry the collapse state over to the new name so
    /// the category doesn't spring open when the edit-categories screen is left.
    private func renameCategory(_ category: String, to newName: String) {
        guard store.renameCategory(category, to: newName) else { return }
        if collapsedCategories.remove(category) != nil {
            collapsedCategories.insert(newName)
        }
    }

    /// Create the category immediately under a placeholder name and open the
    /// edit-categories screen with its name field ready to type in — like a new
    /// exercise, it's named where it lives rather than in an alert beforehand.
    private func addCategory() {
        // A search the new category doesn't match would hide it the moment the
        // user came back from naming it.
        searchText = ""
        newCategory = CategoryEditView.addCategory(to: store)
        navigationPath.append(ExerciseRoute.editCategories)
    }

    /// The as-created snapshot of an exercise added via the + menu. Compared
    /// against on return to the list so an exercise the user never touched
    /// (no setting, name, description, or MIDI change) is silently discarded.
    @State private var pendingNewExercise: Exercise?

    /// The exercise the list should scroll to and flash: a newly created one,
    /// which otherwise lands at the bottom of its category off screen. Cleared
    /// once the flash is over so it isn't repeated.
    @State private var highlightedExerciseID: UUID?

    /// Create the exercise immediately and open its settings, where the user
    /// picks the name and everything else.
    private func addExercise() {
        // A filter (or search) the new exercise doesn't match would hide it the
        // moment the user came back from its settings, so adding one drops both.
        activeFilters.removeAll()
        searchText = ""
        let exercise = store.add(name: L("New Exercise"))
        pendingNewExercise = exercise
        navigationPath.append(ExerciseRoute.settings(exercise.id))
    }

    /// Ask the list to scroll to a just-created exercise and flash it. Its
    /// category is expanded first — otherwise the row it should point at isn't in
    /// the list at all.
    private func revealCreatedExercise(_ id: UUID) {
        guard let exercise = store.exercises.first(where: { $0.id == id }) else { return }
        if collapsedCategories.contains(exercise.category) {
            withAnimation { _ = collapsedCategories.remove(exercise.category) }
        }
        highlightedExerciseID = id
        // Long enough for the scroll and the flash to have finished, so a later
        // rebuild of the list (switching tabs and back) doesn't replay them.
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if highlightedExerciseID == id { highlightedExerciseID = nil }
        }
    }

    var body: some View {
        let sections = listSections
        return NavigationStack(path: $navigationPath) {
            Group {
                if sections.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if sections.isEmpty && !activeFilters.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Exercises", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("No exercise matches the selected filters.")
                    } actions: {
                        Button("Clear Filters") { activeFilters.removeAll() }
                    }
                } else {
                    ExerciseCollectionList(
                        sections: sections,
                        onSelect: { id, _ in
                            // Everything on screen, categories in order, so "Next"
                            // can carry on into the category below.
                            playQueue = sections.flatMap { $0.items.map(\.id) }
                            navigationPath.append(ExerciseRoute.play(id))
                        },
                        onSettings: { navigationPath.append(ExerciseRoute.settings($0)) },
                        onToggleCollapse: { category in
                            // The chevron is hidden while searching; a header tap
                            // there must not quietly change a state the user
                            // can't see until the field is cleared.
                            guard query.isEmpty else { return }
                            if collapsedCategories.contains(category) {
                                collapsedCategories.remove(category)
                            } else {
                                collapsedCategories.insert(category)
                            }
                        },
                        onHeaderLongPress: {
                            navigationPath.append(ExerciseRoute.editCategories)
                        },
                        onMove: { id, category, before in
                            store.moveExercise(id, toCategory: category, before: before)
                        },
                        onDragChange: { isDraggingExercise = $0 },
                        hidesSearchBarInitially: true,
                        highlightedID: highlightedExerciseID
                    )
                    // Span the full screen like a List so content scrolls under the
                    // navigation and tab bars.
                    .ignoresSafeArea()
                }
            }
            .navigationTitle(L("Exercises"))
            .navigationBarTitleDisplayMode(.inline)
            // Unlike Community's always-visible field, this one starts scrolled
            // out of sight (see ExerciseCollectionList's hidesSearchBarInitially)
            // and is revealed by pulling the list down.
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: L("Exercises, Descriptions"))
            .stableTopEdgeFade()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ReorderableListTitle(title: L("Exercises"), isDragging: isDraggingExercise)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Source") {
                            ForEach(ExerciseFilter.sourceCases) { filter in
                                Toggle(isOn: filterBinding(filter)) {
                                    Label(filter.label, systemImage: filter.systemImage)
                                }
                            }
                        }
                        Section("Visibility") {
                            ForEach(ExerciseFilter.visibilityCases) { filter in
                                Toggle(isOn: filterBinding(filter)) {
                                    Label(filter.label, systemImage: filter.systemImage)
                                }
                            }
                        }
                        if !activeFilters.isEmpty {
                            Section {
                                Button(role: .destructive) {
                                    activeFilters.removeAll()
                                } label: {
                                    Label("Clear Filters", systemImage: "xmark.circle")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: activeFilters.isEmpty
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filter")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            addExercise()
                        } label: {
                            Label("New Exercise", systemImage: "music.note")
                        }
                        Button {
                            addCategory()
                        } label: {
                            Label("New Category", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .onChange(of: navigationPath) { old, new in
                // Back at the list after creating an exercise: if it was never
                // touched (settings screens deeper in this path can't be showing
                // anymore), remove it again — and skip the "Saved!" toast for it.
                if new.isEmpty, let created = pendingNewExercise {
                    pendingNewExercise = nil
                    store.discardIfUntouched(created)
                    if !store.exercises.contains(where: { $0.id == created.id }) { return }
                    // Kept: point it out, since it lands at the bottom of its
                    // category and is very likely off screen.
                    revealCreatedExercise(created.id)
                }
                toasts.routesPopped(from: old, to: new)
            }
            // Deleting an exercise from its settings screen pops that screen but
            // leaves the intro screen it was opened from on the path, where it can
            // no longer find its exercise and renders blank. Drop those routes so
            // the delete lands back on the list. A delete is the only thing that
            // can shorten the library.
            .onChange(of: store.exercises.count) { _, _ in
                while let route = navigationPath.last {
                    switch route {
                    case .play(let id), .playback(let id), .settings(let id), .edit(let id):
                        guard !store.exercises.contains(where: { $0.id == id }) else { return }
                    default:
                        return
                    }
                    navigationPath.removeLast()
                }
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
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
                case .editCategories:
                    CategoryEditView(newCategory: $newCategory, onRename: renameCategory)
                case .user, .routine, .routineIntro, .routinePicker, .routinePlay, .routinePlayback,
                     .favourites, .favouritesPicker:
                    // Never appended from this tab; usernames only show in
                    // Community, routines and favourites live on the Home tab.
                    EmptyView()
                }
            }
        }
    }
}
