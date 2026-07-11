import SwiftUI

/// The Community tab: every exercise whose visibility is set to public, in one
/// flat list (no categories). Looks like the Exercises tab but read-only — no
/// add button, no settings swipe, no drag & drop — and each row shows the
/// uploader's username in grey between the name and the pattern thumbnail.
struct CommunityView: View {
    @EnvironmentObject private var store: ExerciseStore
    @State private var navigationPath = NavigationPath()

    /// All public exercises as a single unlabelled section. An empty `category`
    /// makes the list render no header.
    private var listSections: [ExerciseListSection] {
        let rows = store.exercises
            .filter { $0.visibility == .public }
            .map { exercise in
                ExerciseListRow(exercise: exercise,
                                pattern: store.notes(for: exercise.id),
                                uploaderName: exercise.uploaderName)
            }
        guard !rows.isEmpty else { return [] }
        return [ExerciseListSection(category: "",
                                    isCollapsed: false,
                                    totalCount: rows.count,
                                    items: rows)]
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if listSections.isEmpty {
                    ContentUnavailableView(
                        "No Community Exercises",
                        systemImage: "person.3",
                        description: Text("Exercises set to public in their settings appear here.")
                    )
                } else {
                    ExerciseCollectionList(
                        sections: listSections,
                        onSelect: { navigationPath.append(ExerciseRoute.play($0)) },
                        onSelectUploader: { navigationPath.append(ExerciseRoute.user($0)) }
                    )
                    // Span the full screen like a List so content scrolls under the
                    // navigation and tab bars.
                    .ignoresSafeArea()
                }
            }
            .navigationTitle("Community")
            .navigationBarTitleDisplayMode(.inline)
            .stableTopEdgeFade()
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .play(let id):
                    if let ex = store.exercises.first(where: { $0.id == id }) {
                        ExerciseIntroView(exercise: ex,
                                          onDownload: { store.downloadCopy(of: id) }) {
                            navigationPath.append(ExerciseRoute.playback(id))
                        }
                    }
                case .playback(let id):
                    if let ex = store.exercises.first(where: { $0.id == id }) {
                        PlaybackView(exercise: ex)
                    }
                case .user(let username):
                    CommunityUserProfileView(username: username) {
                        navigationPath.append(ExerciseRoute.play($0))
                    }
                case .settings, .edit, .routine, .routinePicker, .routinePlay, .routinePlayback:
                    // Never appended from this tab; exercises aren't editable
                    // here and routines live on the Home tab.
                    EmptyView()
                }
            }
        }
    }
}

/// A community uploader's profile: their username as the title and all of their
/// public exercises, rendered like the Community list but without the redundant
/// uploader name on each row. Pushed onto the Community stack, so the standard
/// back button appears top-left.
struct CommunityUserProfileView: View {
    @EnvironmentObject private var store: ExerciseStore
    let username: String
    /// Called with the tapped exercise's id; the Community stack pushes playback.
    let onSelect: (UUID) -> Void

    private var listSections: [ExerciseListSection] {
        let rows = store.exercises
            .filter { $0.visibility == .public && $0.uploaderName == username }
            .map { exercise in
                ExerciseListRow(exercise: exercise,
                                pattern: store.notes(for: exercise.id))
            }
        guard !rows.isEmpty else { return [] }
        return [ExerciseListSection(category: "",
                                    isCollapsed: false,
                                    totalCount: rows.count,
                                    items: rows)]
    }

    var body: some View {
        Group {
            if listSections.isEmpty {
                ContentUnavailableView(
                    "No Public Exercises",
                    systemImage: "person.crop.circle",
                    description: Text("\(username) has no public exercises right now.")
                )
            } else {
                ExerciseCollectionList(
                    sections: listSections,
                    onSelect: onSelect
                )
                // Span the full screen like a List so content scrolls under the
                // navigation and tab bars.
                .ignoresSafeArea()
            }
        }
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
    }
}
