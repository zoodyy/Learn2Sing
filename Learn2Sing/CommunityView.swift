import SwiftUI

/// The Community tab: every user's public exercises, in one flat list (no
/// categories), exactly as fetched from the server by CommunitySync — nothing
/// local is mixed in, so every user sees the same list. Refreshed when the tab
/// appears and by pulling down. Looks like the Exercises tab but read-only —
/// no add button, no settings swipe, no drag & drop — and each row shows the
/// uploader's username in grey between the name and the pattern thumbnail.
/// The search field filters the list to matching uploaders (as tappable rows
/// leading to their profile) and to exercises whose name or description matches.
struct CommunityView: View {
    @EnvironmentObject private var store: ExerciseStore
    @ObservedObject private var community = CommunitySync.shared
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""

    private func exercise(for id: UUID) -> Exercise? {
        community.exercises.first { $0.id == id }
    }

    /// Case- and diacritic-insensitive substring match, so "jose" finds "José".
    private static func matches(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// A stable row id for a user result row. The list is keyed by UUID and a
    /// user row isn't an exercise, so its id is derived (128-bit FNV-1a over a
    /// namespaced string) from the username: unchanged between keystrokes, so
    /// the diffable identity doesn't churn, and never equal to an exercise id.
    private static func userRowID(for username: String) -> UUID {
        var bytes: [UInt8] = []
        for seed in [0xcbf2_9ce4_8422_2325, 0x9e37_79b9_7f4a_7c15] as [UInt64] {
            var hash = seed
            for byte in "community.user:\(username)".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
            withUnsafeBytes(of: hash.bigEndian) { bytes.append(contentsOf: $0) }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// What the list shows for the current search text: every fetched exercise in
    /// one unlabelled section while the field is empty (an empty `category` makes
    /// the list render no header), otherwise a "Users" section of the matching
    /// uploaders followed by the exercises whose name or description matches.
    /// `users` maps each user row's id back to its username, for selection.
    private var results: (sections: [ExerciseListSection], users: [UUID: String]) {
        func exerciseRows(_ exercises: [Exercise]) -> [ExerciseListRow] {
            exercises.map { exercise in
                ExerciseListRow(exercise: exercise,
                                pattern: store.notes(for: exercise.id),
                                uploaderName: exercise.uploaderName)
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            let rows = exerciseRows(community.exercises)
            guard !rows.isEmpty else { return ([], [:]) }
            return ([ExerciseListSection(category: "",
                                         isCollapsed: false,
                                         totalCount: rows.count,
                                         items: rows)], [:])
        }

        var sections: [ExerciseListSection] = []
        var users: [UUID: String] = [:]

        // Only uploaders present in the fetched list, which by definition are the
        // users with at least one public exercise.
        let usernames = Set(community.exercises.map(\.uploaderName))
            .filter { !$0.isEmpty && Self.matches($0, query) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !usernames.isEmpty {
            let rows = usernames.map { username in
                var placeholder = Exercise(name: username)
                placeholder.id = Self.userRowID(for: username)
                users[placeholder.id] = username
                return ExerciseListRow(exercise: placeholder, pattern: [])
            }
            sections.append(ExerciseListSection(category: "Users",
                                                isCollapsed: false,
                                                totalCount: rows.count,
                                                items: rows,
                                                showsCount: false,
                                                showsChevron: false))
        }

        let exerciseMatches = exerciseRows(community.exercises.filter {
            Self.matches($0.name, query) || Self.matches($0.details, query)
        })
        if !exerciseMatches.isEmpty {
            sections.append(ExerciseListSection(category: "Exercises",
                                                isCollapsed: false,
                                                totalCount: exerciseMatches.count,
                                                items: exerciseMatches,
                                                showsCount: false,
                                                showsChevron: false))
        }
        return (sections, users)
    }

    var body: some View {
        let results = self.results
        NavigationStack(path: $navigationPath) {
            Group {
                if results.sections.isEmpty {
                    // A scroll view so pull-to-refresh also works while the list
                    // is empty (e.g. after launching without a connection).
                    GeometryReader { geo in
                        ScrollView {
                            Group {
                                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                                    ContentUnavailableView.search(text: searchText)
                                } else if community.isFetching {
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
                        sections: results.sections,
                        onSelect: { id in
                            // A user row opens the uploader's profile; anything
                            // else is an exercise.
                            if let username = results.users[id] {
                                navigationPath.append(ExerciseRoute.user(username))
                            } else {
                                navigationPath.append(ExerciseRoute.play(id))
                            }
                        },
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
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Users, Exercises, Descriptions")
            .stableTopEdgeFade()
            // Reload from the server each time the tab is visited; the previous
            // list stays up while (and if) the fetch fails.
            .task { await community.refresh() }
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .play(let id):
                    if let ex = exercise(for: id) {
                        ExerciseIntroView(exercise: ex,
                                          likeID: ex.id,
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
                case .settings, .edit, .routine, .routinePicker, .routinePlay, .routinePlayback,
                     .favourites, .favouritesPicker:
                    // Never appended from this tab; exercises aren't editable
                    // here and routines/favourites live on the Home tab.
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
