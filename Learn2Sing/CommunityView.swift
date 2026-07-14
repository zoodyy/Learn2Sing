import SwiftUI

/// The Community tab: every user's public exercises, in one flat list (no
/// categories), exactly as fetched from the server by CommunitySync — nothing
/// local is mixed in, so every user sees the same list. Refreshed when the tab
/// appears and by pulling down. Looks like the Exercises tab but read-only —
/// no add button, no settings swipe, no drag & drop — and each row shows the
/// uploader's username in grey between the name and the pattern thumbnail.
struct CommunityView: View {
    @EnvironmentObject private var store: ExerciseStore
    @ObservedObject private var community = CommunitySync.shared
    @State private var navigationPath = NavigationPath()

    private func exercise(for id: UUID) -> Exercise? {
        community.exercises.first { $0.id == id }
    }

    /// All fetched exercises as a single unlabelled section. An empty `category`
    /// makes the list render no header.
    private var listSections: [ExerciseListSection] {
        let rows = community.exercises
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
                    // A scroll view so pull-to-refresh also works while the list
                    // is empty (e.g. after launching without a connection).
                    GeometryReader { geo in
                        ScrollView {
                            Group {
                                if community.isFetching {
                                    ProgressView()
                                } else {
                                    ContentUnavailableView(
                                        "No Community Exercises",
                                        systemImage: "person.3",
                                        description: Text("Public exercises shared by all users appear here. Pull down to refresh.")
                                    )
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                        .refreshable { await community.refresh() }
                    }
                } else {
                    ExerciseCollectionList(
                        sections: listSections,
                        onSelect: { navigationPath.append(ExerciseRoute.play($0)) },
                        onSelectUploader: { navigationPath.append(ExerciseRoute.user($0)) },
                        onRefresh: { await community.refresh() }
                    )
                    // Span the full screen like a List so content scrolls under the
                    // navigation and tab bars.
                    .ignoresSafeArea()
                }
            }
            .navigationTitle("Community")
            .navigationBarTitleDisplayMode(.inline)
            .stableTopEdgeFade()
            // Reload from the server each time the tab is visited; the previous
            // list stays up while (and if) the fetch fails.
            .task { await community.refresh() }
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .play(let id):
                    if let ex = exercise(for: id) {
                        ExerciseIntroView(exercise: ex,
                                          onDownload: { store.downloadCopy(of: ex) }) {
                            navigationPath.append(ExerciseRoute.playback(id))
                        }
                    }
                case .playback(let id):
                    if let ex = exercise(for: id) {
                        // Pop the intro screen along with playback so Exit lands back
                        // where the exercise was tapped (the list or a user profile).
                        PlaybackView(exercise: ex,
                                     onScoreExit: { navigationPath.removeLast(2) },
                                     onScoreDownload: { store.downloadCopy(of: ex) })
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
    @ObservedObject private var community = CommunitySync.shared
    let username: String
    /// Called with the tapped exercise's id; the Community stack pushes playback.
    let onSelect: (UUID) -> Void

    private var listSections: [ExerciseListSection] {
        let rows = community.exercises
            .filter { $0.uploaderName == username }
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
