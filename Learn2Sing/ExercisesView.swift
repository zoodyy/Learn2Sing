import SwiftUI

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
    var beatsBetweenReps: Double = 0  // silent beats inserted between repetitions

    init(name: String) { self.name = name }

    private enum CodingKeys: String, CodingKey {
        case id, name, details, category, pitchShift, bpm, speed, repeatCount, transposePerRepeat, switchDirectionAfter, beatsBetweenReps
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
        beatsBetweenReps = try c.decodeIfPresent(Double.self, forKey: .beatsBetweenReps) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(details, forKey: .details)
        try c.encode(category, forKey: .category)
        try c.encode(pitchShift, forKey: .pitchShift)
        try c.encode(bpm, forKey: .bpm)
        try c.encode(repeatCount, forKey: .repeatCount)
        try c.encode(transposePerRepeat, forKey: .transposePerRepeat)
        try c.encode(switchDirectionAfter, forKey: .switchDirectionAfter)
        try c.encode(beatsBetweenReps, forKey: .beatsBetweenReps)
    }
}

enum ExerciseRoute: Hashable {
    case play(UUID)      // the intro/description screen shown before playback
    case playback(UUID)  // the actual note-scrolling playback screen
    case settings(UUID)
    case edit(UUID)
}

struct ExercisesView: View {
    @EnvironmentObject private var store: ExerciseStore
    @State private var navigationPath = NavigationPath()

    /// Categories the user has collapsed. Their exercises are hidden and the
    /// header shows the exercise count in parentheses instead.
    @State private var collapsedCategories: Set<String> = []

    /// True while the user is rearranging category order. Entered by long-pressing
    /// a category header (which just switches the mode — it never picks up a row to
    /// drag), exited via the top-leading ✗ button.
    @State private var isReordering = false

    /// Drives the List into edit mode so `.onMove` shows drag handles.
    @State private var editMode: EditMode = .inactive

    /// The collapse state captured when entering reorder mode. Restored on exit so
    /// categories that were expanded before the mode switch become expanded again.
    @State private var collapsedBeforeReorder: Set<String> = []

    /// Exercises with no category, or whose category was deleted, shown in an
    /// unlabelled section so none are ever lost from the list.
    private var uncategorized: [Exercise] {
        store.exercises.filter { $0.category.isEmpty || !store.categories.contains($0.category) }
    }

    /// A tappable section header showing the category name and a collapse arrow.
    /// While collapsed the exercise count is shown in parentheses.
    private func categoryHeader(_ category: String, count: Int, isCollapsed: Bool) -> some View {
        Button {
            withAnimation {
                if isCollapsed {
                    collapsedCategories.remove(category)
                } else {
                    collapsedCategories.insert(category)
                }
            }
        } label: {
            HStack {
                Text(category)
                if isCollapsed {
                    Text("(\(count))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A long press only flips into reorder mode; it deliberately does not begin
        // dragging this row. `.simultaneousGesture` keeps the tap-to-collapse working.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                enterReorderMode()
            }
        )
    }

    /// A collapsed, drag-reorderable row for a category, shown only in reorder mode.
    /// Rendered as a plain row (not `Section(header:)`) so the List's native `.onMove`
    /// can actually move it.
    private func reorderRow(_ category: String) -> some View {
        let count = store.exercises.filter { $0.category == category }.count
        return HStack {
            Text(category)
            Text("(\(count))")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func enterReorderMode() {
        guard !isReordering else { return }
        collapsedBeforeReorder = collapsedCategories
        withAnimation {
            collapsedCategories = Set(store.categories)
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

    private func moveCategory(from source: IndexSet, to destination: Int) {
        store.moveCategory(from: source, to: destination)
    }

    @ViewBuilder
    private func exerciseRow(_ exercise: Exercise) -> some View {
        Button(exercise.name) {
            navigationPath.append(ExerciseRoute.play(exercise.id))
        }
        .foregroundStyle(.primary)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                navigationPath.append(ExerciseRoute.settings(exercise.id))
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .tint(.blue)
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                if isReordering {
                    // Reorder mode: every category collapsed to a single draggable row.
                    ForEach(store.categories, id: \.self) { category in
                        reorderRow(category)
                    }
                    .onMove(perform: moveCategory)
                } else {
                    // One section per category, in the user's defined order. A category
                    // with no exercises is skipped so its header never shows.
                    ForEach(store.categories, id: \.self) { category in
                        let items = store.exercises.filter { $0.category == category }
                        if !items.isEmpty {
                            let isCollapsed = collapsedCategories.contains(category)
                            Section(header: categoryHeader(category, count: items.count, isCollapsed: isCollapsed)) {
                                if !isCollapsed {
                                    ForEach(items) { exerciseRow($0) }
                                }
                            }
                        }
                    }

                    if !uncategorized.isEmpty {
                        Section {
                            ForEach(uncategorized) { exerciseRow($0) }
                        }
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(isReordering ? "Reorder" : "Exercises")
            .navigationBarTitleDisplayMode(.inline)
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
                            // Create the exercise immediately and open its settings, where
                            // the user picks the name and everything else.
                            let exercise = store.add(name: "New Exercise")
                            navigationPath.append(ExerciseRoute.settings(exercise.id))
                        } label: {
                            Image(systemName: "plus")
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
                }
            }
        }
    }
}
