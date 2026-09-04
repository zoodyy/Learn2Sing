import SwiftUI
import UIKit

/// The Community tab: every user's public exercises, in one flat list (no
/// categories), exactly as fetched from the server by CommunitySync — nothing
/// local is mixed in, so every user sees the same list. Refreshed when the tab
/// appears and by pulling down. Looks like the Exercises tab but read-only —
/// no add button, no settings swipe, no drag & drop — and each row shows the
/// uploader's username in grey between the name and the pattern thumbnail.
/// The search field filters the list to matching uploaders (as tappable rows
/// leading to their profile) and to exercises whose name or description matches,
/// and the toolbar's filter menu narrows it to the ones this user has (or hasn't)
/// liked. Both are applied by the server — the search field's text rides along on
/// the fetch as `searchTerm` — so they narrow what the tab holds rather than just
/// what this screen draws.
struct CommunityView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @ObservedObject private var community = CommunitySync.shared
    /// The whole community, as fetched. The uploader profiles pushed from here
    /// fetch their own (see CommunityFeed), so nothing they are sorted, filtered
    /// or searched by touches this list.
    @ObservedObject private var list = CommunitySync.shared.list
    @State private var navigationPath = NavigationPath()
    @State private var searchText = ""
    /// The order the list is shown in, picked from the toolbar's sort menu.
    /// Persisted, so it survives launches (and applies on the uploader profiles
    /// pushed from here, which read the same key). Changing it refetches, since
    /// the server is what puts "Hot" and "Recently Updated" in order.
    @AppStorage("communitySort") private var sort: CommunitySort = .hot
    /// The sort menu's reverse switch, persisted alongside the order it flips.
    /// Off to begin with, and ignored while an order that doesn't offer it is
    /// picked — the switch is hidden there rather than reset, so it comes back
    /// as it was left.
    @AppStorage("communitySortReversed") private var isReversed = false
    /// The reverse switch as it actually applies to the current order.
    private var reversed: Bool { sort.isReversible && isReversed }
    /// The order to fetch in: the picked sort together with the reverse switch as
    /// it applies to it. Watched as one value because picking an order that
    /// doesn't offer the switch changes both at once, and two `onChange`s would
    /// then fire two identical refreshes.
    private var sortRequest: CommunitySortRequest {
        CommunitySortRequest(sort: sort, reversed: reversed)
    }
    /// The exercises of the list the user started playing from — this tab's own
    /// list or an uploader's profile — in the order it showed them, which is what
    /// the score screen's "Next" button walks along. Captured on the tap, so a
    /// refresh arriving mid-play can't reorder it.
    @State private var playQueue: [UUID] = []

    /// Whether the search field has something in it. The matches are drawn from
    /// every matching exercise in the community rather than the page of them the
    /// list has scrolled to — the "Users" section is a summary of the whole
    /// result — so while this is true the feed keeps loading the rest in the
    /// background.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The exercise behind a pushed route. Looked up across every list fetched
    /// this session rather than in the tab's own: the route may have been pushed
    /// from an uploader's profile, which fetches separately, and a search or a
    /// filter can narrow this list out from under a screen already open on it.
    private func exercise(for id: UUID) -> Exercise? {
        community.exercise(for: id)
    }

    /// The exercise listed below `id`, skipping any that a refresh has since
    /// dropped. nil at the end of the list, where the Next button is left out.
    private func nextExercise(after id: UUID) -> UUID? {
        guard let index = playQueue.firstIndex(of: id) else { return nil }
        return playQueue[(index + 1)...].first { exercise(for: $0) != nil }
    }

    /// The score screen's Next button: swap the finished exercise's intro/playback
    /// pair for the next exercise's intro screen.
    private func advance(to id: UUID) {
        navigationPath.removeLast(2)
        navigationPath.append(ExerciseRoute.play(id))
    }

    /// Copies a community exercise into the user's library and counts the
    /// download towards its total (only the first time this user downloads it).
    private func download(_ exercise: Exercise) {
        _ = store.downloadCopy(of: exercise)
        community.registerDownload(for: exercise.id)
    }

    /// Case- and diacritic-insensitive substring match, so "jose" finds "José".
    static func matches(_ text: String, _ query: String) -> Bool {
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

    /// The public id of the uploader going by `username`, since a profile is
    /// fetched by id rather than by name. This tab's own list first, then every
    /// uploader any list has named this session — the intro screen's "Created
    /// by" line asks for exercises opened from an uploader's profile too, and
    /// that profile fetches separately from this list.
    private func uploaderID(named username: String) -> String? {
        community.uploaderID(named: username, in: list)
    }

    /// What the list shows for the current search text: every fetched exercise in
    /// one unlabelled section while the field is empty (an empty `category` makes
    /// the list render no header), otherwise a "Users" section of the matching
    /// uploaders followed by the exercises whose name or description matches.
    /// `users` maps each user row's id back to the uploader it opens.
    ///
    /// The server has already narrowed the fetched list to the search term, so
    /// this is what splits its answer into the two sections — and what keeps the
    /// list narrowing as the user types, in the moment before the refetch that
    /// each new term triggers lands.
    private var results: (sections: [ExerciseListSection], users: [UUID: CommunityUploader]) {
        func exerciseRows(_ exercises: [Exercise]) -> [ExerciseListRow] {
            exercises.map { exercise in
                ExerciseListRow(exercise: exercise,
                                pattern: store.notes(for: exercise.id),
                                uploaderName: exercise.uploaderName)
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            let rows = exerciseRows(list.exercises)
            guard !rows.isEmpty else { return ([], [:]) }
            return ([ExerciseListSection(category: "",
                                         isCollapsed: false,
                                         totalCount: rows.count,
                                         items: rows)], [:])
        }

        var sections: [ExerciseListSection] = []
        var users: [UUID: CommunityUploader] = [:]

        // Only uploaders present in the fetched list, which by definition are the
        // users with at least one public exercise. Not narrowed by the filters:
        // these rows lead to a profile, which fetches that uploader's exercises
        // unfiltered anyway.
        var uploaders: [String: String] = [:]
        for exercise in list.exercises {
            guard !exercise.uploaderName.isEmpty,
                  Self.matches(exercise.uploaderName, query),
                  let id = list.uploaderIDs[exercise.id]
            else { continue }
            uploaders[id] = exercise.uploaderName
        }
        if !uploaders.isEmpty {
            let rows = uploaders
                .map { CommunityUploader(id: $0.key, name: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { uploader in
                    var placeholder = Exercise(name: uploader.name)
                    placeholder.id = Self.userRowID(for: uploader.name)
                    users[placeholder.id] = uploader
                    return ExerciseListRow(exercise: placeholder, pattern: [])
                }
            sections.append(ExerciseListSection(category: "Users",
                                                isCollapsed: false,
                                                totalCount: rows.count,
                                                items: rows,
                                                showsCount: false,
                                                showsChevron: false,
                                                displayName: L("Users")))
        }

        let exerciseMatches = exerciseRows(list.exercises.filter {
            Self.matches($0.name, query) || Self.matches($0.details, query)
        })
        if !exerciseMatches.isEmpty {
            sections.append(ExerciseListSection(category: "Exercises",
                                                isCollapsed: false,
                                                totalCount: exerciseMatches.count,
                                                items: exerciseMatches,
                                                showsCount: false,
                                                showsChevron: false,
                                                displayName: L("Exercises")))
        }
        return (sections, users)
    }

    var body: some View {
        let results = self.results
        NavigationStack(path: $navigationPath) {
            Group {
                if results.sections.isEmpty {
                    CommunityEmptyState(list: list, searchText: searchText) {
                        ContentUnavailableView(
                            "No Community Exercises",
                            systemImage: "person.3",
                            description: Text("Public exercises shared by all users appear here. Pull down to refresh.")
                        )
                    }
                } else {
                    ExerciseCollectionList(
                        sections: results.sections,
                        onSelect: { id, _ in
                            // A user row opens the uploader's profile; anything
                            // else is an exercise.
                            if let uploader = results.users[id] {
                                navigationPath.append(ExerciseRoute.user(id: uploader.id,
                                                                        name: uploader.name))
                            } else {
                                // The listed exercises (never the user rows) are
                                // what "Next" walks along afterwards.
                                playQueue = results.sections
                                    .flatMap { $0.items.map(\.id) }
                                    .filter { results.users[$0] == nil }
                                navigationPath.append(ExerciseRoute.play(id))
                            }
                        },
                        onSelectUploader: { name in
                            guard let id = uploaderID(named: name) else { return }
                            navigationPath.append(ExerciseRoute.user(id: id, name: name))
                        },
                        onRefresh: { await list.refresh() },
                        // The list is a page of the community at a time, topped
                        // up as the user scrolls towards the end of it. Not while
                        // searching: the "Users" section summarises every match,
                        // so the whole (already narrowed) result is being loaded
                        // anyway — see below — and how far down it the user has
                        // scrolled says nothing about how much is left.
                        onLoadMore: isSearching ? nil : { Task { await list.loadNextPage() } },
                        loadMoreThreshold: CommunityFeed.pageSize,
                        // Under the last row for as long as the server has more
                        // of the community to give, so scrolling to the end of
                        // what has loaded shows that the rest is on its way —
                        // and nothing at the end of the community itself. Not
                        // while searching, where the whole (already narrowed)
                        // result is being loaded whatever the user scrolls to.
                        showsLoadMoreSpinner: !isSearching && list.hasMorePages
                    )
                    // Span the full screen like a List so content scrolls under the
                    // navigation and tab bars.
                    .ignoresSafeArea()
                }
            }
            .navigationTitle(L("Community"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L("Users, Exercises, Descriptions"))
            // Swiping down over the search field's keyboard puts it away, like
            // everywhere else. This covers the empty state, which is a scroll
            // view of its own; the list itself is a collection view and asks for
            // the same behaviour directly (see ExerciseCollectionList).
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CommunityFilterMenu(list: list)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CommunitySortMenu(sort: $sort, isReversed: $isReversed)
                }
            }
            .stableTopEdgeFade()
            // Load the list the first time the tab is visited, and after a fetch
            // that failed; a visit to a tab already showing one leaves it — and
            // the pages scrolled through since — alone, since reloading it would
            // mean fetching them all again. Pull down to reload deliberately.
            .task { await list.refreshIfNeeded() }
            .onChange(of: isSearching) { list.setNeedsFullList(isSearching, for: .search) }
            // The search runs on the server; the term goes into the fetch and
            // what comes back is the result.
            .communitySearchTerm(searchText, on: list)
            // The fetch asks the server for the picked order, so a new pick has
            // to go back to it — the orders it ranks itself ("Hot", "Recently
            // Updated") can't be worked out from the list already held. The
            // reverse switch rides along as the fetch's `sortDirection`.
            .onChange(of: sortRequest) { Task { await list.refresh() } }
            .navigationDestination(for: ExerciseRoute.self) { route in
                switch route {
                case .play(let id):
                    if let ex = exercise(for: id) {
                        ExerciseIntroView(exercise: ex,
                                          likeID: ex.id,
                                          uploaderName: ex.uploaderName,
                                          // By the exercise rather than by the
                                          // name on it, since this screen has it
                                          // — and resolved here rather than on
                                          // the tap, so an uploader who can't be
                                          // reached leaves the line off the
                                          // screen entirely.
                                          onSelectUploader: community.uploaderID(of: ex.id).map { uploader in
                                              { navigationPath.append(
                                                  ExerciseRoute.user(id: uploader, name: ex.uploaderName)) }
                                          },
                                          onDownload: { download(ex) }) {
                            navigationPath.append(ExerciseRoute.playback(id))
                        }
                    }
                case .playback(let id):
                    if let ex = exercise(for: id) {
                        // Pop the intro screen along with playback so Exit lands back
                        // where the exercise was tapped (the list or a user profile).
                        PlaybackView(exercise: ex,
                                     onScoreExit: { navigationPath.removeLast(2) },
                                     onScoreNext: nextExercise(after: id).map { next in
                                         { advance(to: next) }
                                     },
                                     onScoreDownload: { download(ex) },
                                     // Community exercises are listed by their
                                     // public id, so the play this run posts is
                                     // handed the id it already carries rather
                                     // than deriving one from it.
                                     communityID: ex.id)
                    }
                case .user(let id, let name):
                    CommunityUserProfileView(uploaderID: id, username: name) { id, listed in
                        playQueue = listed
                        navigationPath.append(ExerciseRoute.play(id))
                    }
                case .settings, .edit, .editCategories, .routine, .routineIntro, .routinePicker,
                     .routinePlay, .routinePlayback, .recommendationIntro, .recommendationPlay,
                     .recommendationPlayback, .exercisesSettings, .recommendationWhitelist,
                     .favourites, .favouritesPicker,
                     .communityPlay, .communityPlayback:
                    // Never appended from this tab; exercises aren't editable
                    // here, routines, favourites and recommendations live on the
                    // Home tab, and every exercise this tab lists is a community
                    // one already — `play` is the community pair here.
                    EmptyView()
                }
            }
        }
    }
}

/// A community uploader as a list row leads to one: the public id their exercises
/// are fetched by, and the username the row and the profile's title show.
struct CommunityUploader: Hashable {
    var id: String
    var name: String
}

/// The order to fetch in — the picked sort together with the reverse switch as it
/// applies to it — watched as one value so picking an order that doesn't offer
/// the switch fires one refresh rather than two.
struct CommunitySortRequest: Equatable {
    var sort: CommunitySort
    var reversed: Bool
}

/// A community uploader's profile: their username as the title and their public
/// exercises, rendered like the Community list but without the redundant uploader
/// name on each row. Pushed onto the Community stack, so the standard back button
/// appears top-left.
///
/// It fetches its own list rather than sifting the tab's, scoped to this
/// uploader's public id (see `CommunityFeed.uploaderID`), and carries the same
/// three controls the tab does — search, sort and filter — every one of them
/// applied by the server. The list starts clean: whatever the tab was searching
/// for when the profile was opened narrows the tab, not this.
struct CommunityUserProfileView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    /// This uploader's exercises, fetched on their own. A @StateObject, so it
    /// lives exactly as long as the profile screen and its paging isn't shared
    /// with — or reset by — anything else on the stack.
    @StateObject private var list: CommunityFeed
    /// This uploader's public user id, which their published profile is fetched
    /// under — the same id their exercises are listed by.
    private let uploaderID: String
    let username: String
    /// Called with the tapped exercise's id and every exercise this profile lists,
    /// in display order; the Community stack pushes playback and lets the score
    /// screen's "Next" button carry on down that list.
    let onSelect: (UUID, [UUID]) -> Void
    /// The order picked in the Community tab's sort menu, reverse switch and
    /// all, applied here too — this screen's menu writes the same keys, so the
    /// tab and every profile stay in one order.
    @AppStorage("communitySort") private var sort: CommunitySort = .hot
    @AppStorage("communitySortReversed") private var isReversed = false
    @State private var searchText = ""
    /// What this uploader has published about themselves, once the fetch has
    /// answered. nil until then, and for a user who has published nothing — the
    /// header shows what it has either way.
    @State private var publicProfile: PublicProfileDoc?

    init(uploaderID: String, username: String, onSelect: @escaping (UUID, [UUID]) -> Void) {
        _list = StateObject(wrappedValue: CommunityFeed(uploaderID: uploaderID))
        self.uploaderID = uploaderID
        self.username = username
        self.onSelect = onSelect
    }

    private var reversed: Bool { sort.isReversible && isReversed }
    private var sortRequest: CommunitySortRequest {
        CommunitySortRequest(sort: sort, reversed: reversed)
    }

    /// The fetched exercises as one unlabelled section. Nothing is filtered out
    /// here: the search term, the like filter and the order are all the server's,
    /// so what came back is the list — including the exercises it matched on this
    /// uploader's name rather than on their own.
    private var listSections: [ExerciseListSection] {
        let rows = list.exercises
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

    /// This uploader's exercises, or the empty state when the fetch hands back
    /// none — with the profile header above either of them.
    @ViewBuilder private var content: some View {
        if listSections.isEmpty {
            CommunityEmptyState(list: list, searchText: searchText) {
                ContentUnavailableView(
                    "No Public Exercises",
                    systemImage: "person.crop.circle",
                    description: Text(L("%@ has no public exercises right now.", username))
                )
            }
        } else {
            let sections = listSections
            ExerciseCollectionList(
                sections: sections,
                onSelect: { id, _ in
                    onSelect(id, sections.flatMap { $0.items.map(\.id) })
                },
                onRefresh: { await list.refresh() },
                onLoadMore: { Task { await list.loadNextPage() } },
                loadMoreThreshold: CommunityFeed.pageSize
            )
            // Span the width like a List and carry on under the tab bar — but
            // not under the navigation bar, the way the Community tab's own list
            // does: the header sits up there, and a list that ignored the top
            // inset would be laid out across it.
            .ignoresSafeArea(edges: .bottom)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            CommunityProfileHeader(profile: publicProfile)
            content
        }
        .navigationTitle(username)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L("Exercises, Descriptions"))
        // Swiping down over the search field's keyboard puts it away, like
        // everywhere else — see the Community tab's own field for the two scroll
        // views this screen has.
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CommunityFilterMenu(list: list)
            }
            ToolbarItem(placement: .topBarTrailing) {
                CommunitySortMenu(sort: $sort, isReversed: $isReversed)
            }
        }
        .stableTopEdgeFade()
        .task { await list.refreshIfNeeded() }
        // One call, for the description and join date this uploader published.
        // It is their own document rather than anything the list carries, so it
        // is fetched once for the screen and not per refresh.
        .task { publicProfile = await CommunitySync.shared.publicProfile(for: uploaderID) }
        // This uploader's exercises can sit anywhere in what the fetch hands
        // back, since the server doesn't act on the scope it is asked for yet
        // (see `CommunityFeed.uploaderID`), so the profile shows what it can and
        // the rest loads behind it.
        .onAppear { list.setNeedsFullList(true, for: .profile) }
        .onDisappear { list.setNeedsFullList(false, for: .profile) }
        .communitySearchTerm(searchText, on: list)
        .onChange(of: sortRequest) { Task { await list.refresh() } }
    }
}

/// The top of an uploader's profile: a round picture beside the description they
/// wrote, with when they joined underneath if they made that public. The picture
/// is whatever they published (see `ProfilePictureDoc`), falling back to the
/// placeholder for the users who have set none; tapping it opens the whole
/// picture at the biggest size their profile carries.
///
/// Hidden while the search field is in use: the screen is a list of matches then,
/// and whose profile they were found on is what the title says. Reading
/// `isSearching` is why this is a view of its own — the environment value is set
/// for the children of the view carrying `.searchable`, not for that view itself.
private struct CommunityProfileHeader: View {
    /// Re-renders when the language is changed in Settings; the strings are
    /// resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared
    @Environment(\.isSearching) private var isSearching

    /// What the uploader published, or nil while the fetch is out — in which case
    /// the picture stands on its own until it answers.
    let profile: PublicProfileDoc?

    /// The round rendition, decoded once the fetch has answered.
    @State private var thumb: UIImage?
    /// The whole picture, once the circle has been tapped — nil until then, and
    /// again once it is closed. Decoded on demand: it is several times the size
    /// of the round one, and most profiles are looked at without ever being
    /// opened.
    ///
    /// Presented by value rather than with a separate `isPresented` flag, so the
    /// picture and the decision to show it are one state change. Split across
    /// two, the cover could be told to open while a redraw — the `.task` below
    /// re-running as the fetch answers — had already cleared the picture, and it
    /// would come up empty.
    @State private var expanded: ExpandedPicture?

    /// One decoded picture, wrapped so `fullScreenCover(item:)` can carry it.
    private struct ExpandedPicture: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    private var description: String {
        (profile?.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When this uploader joined, if they published it.
    private var joined: Date? {
        profile?.joinedAt.map { Date(timeIntervalSince1970: $0) }
    }

    var body: some View {
        if !isSearching {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    expand()
                } label: {
                    ProfileAvatar(image: thumb, side: 56)
                }
                .buttonStyle(.plain)
                // Nothing to open for a user who has published no picture; the
                // placeholder is not a picture of them.
                .disabled(profile?.picture == nil)
                .accessibilityLabel(L("Profile Picture"))
                .explain(L("This user's picture. Tap it to see it at full size."))

                VStack(alignment: .leading, spacing: 4) {
                    if !description.isEmpty {
                        Text(description)
                            .font(.subheadline)
                            // Wrap instead of shrinking the whole block to one
                            // line, however long the description is.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let joined {
                        Text(L("Joined %@", Self.joinedAgo(joined)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .explain(L("What this user wrote about themselves, and when they started using the app if they chose to show it."))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            // Decoded here rather than where the document is fetched, so a
            // profile that is only scrolled past never pays for it.
            .task(id: profile?.picture?.thumb) {
                thumb = Self.image(profile?.picture?.thumb)
            }
            .fullScreenCover(item: $expanded) { picture in
                ProfilePictureViewer(image: picture.image)
            }
        }
    }

    /// Opens the whole picture, decoding it on the way in. A picture that can't
    /// be decoded simply doesn't open, rather than opening onto nothing.
    private func expand() {
        guard let image = Self.image(profile?.picture?.full) else { return }
        expanded = ExpandedPicture(image: image)
    }

    private static func image(_ base64: String?) -> UIImage? {
        base64.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
    }

    /// "3 months ago" in the language the app is set to — not the device's, which
    /// is what a `.relative` format style would resolve against.
    private static func joinedAgo(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LanguageManager.shared.language.locale
        formatter.unitsStyle = .full
        // A date stamped moments ago reads as "in 0 seconds" if it lands even
        // slightly ahead of now; nobody joins in the future.
        return formatter.localizedString(for: min(date, Date()), relativeTo: Date())
    }
}

/// The toolbar's like filter, for the Community tab and for an uploader profile.
/// The pick belongs to the list it narrows, because the server is what applies
/// it: picking one refetches, and what comes back is the list.
private struct CommunityFilterMenu: View {
    @ObservedObject var list: CommunityFeed

    /// Menu toggle state for one filter. The picks are mutually exclusive — an
    /// exercise is either liked or not — so turning one on turns the other off
    /// rather than leaving both on, which would show the whole list anyway.
    private func binding(_ filter: CommunityFilter) -> Binding<Bool> {
        Binding(
            get: { list.activeFilter == filter },
            set: { isOn in list.setFilter(isOn ? filter : nil) }
        )
    }

    var body: some View {
        Menu {
            Section("Likes") {
                ForEach(CommunityFilter.allCases) { filter in
                    Toggle(isOn: binding(filter)) {
                        Label(filter.label, systemImage: filter.systemImage)
                    }
                }
            }
            if list.activeFilter != nil {
                Section {
                    Button(role: .destructive) {
                        list.setFilter(nil)
                    } label: {
                        Label("Clear Filters", systemImage: "xmark.circle")
                    }
                }
            }
        } label: {
            Image(systemName: list.activeFilter == nil
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter")
        .explain(L("Narrows the list to the exercises you have liked, or to the ones you have not. The button is filled in while a filter is on."))
    }
}

/// The toolbar's order menu. Both screens write the same @AppStorage keys, which
/// is what the fetch reads, so the tab and the profiles stay in one order.
private struct CommunitySortMenu: View {
    @Binding var sort: CommunitySort
    @Binding var isReversed: Bool

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(CommunitySort.allCases) { option in
                    Label(option.label, systemImage: option.systemImage)
                        .tag(option)
                }
            }
            // "Hot" is the server's own ranking and has no sensible other end,
            // so it goes without the switch entirely.
            if sort.isReversible {
                Section {
                    Toggle(isOn: $isReversed) {
                        Label("Reverse Order", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
        }
        .accessibilityLabel("Sort")
        .explain(L("Sets the order the exercises come in. “Reverse Order” turns whichever order is picked around."))
    }
}

/// What a community list shows when it has no rows: the search came back empty,
/// the fetch is still running, the filter matched nothing, or there is genuinely
/// nothing there. A scroll view, so pull-to-refresh also works while the list is
/// empty (e.g. after launching without a connection).
private struct CommunityEmptyState<Empty: View>: View {
    @ObservedObject var list: CommunityFeed
    let searchText: String
    /// What to show when the list is simply empty — nothing fetched, nothing
    /// searched for, nothing filtered out. Passed in rather than described by
    /// parameters so each screen's wording stays a literal at its call site,
    /// which is what the localization tooling extracts (see
    /// Tools/Localization/README.md).
    @ViewBuilder let empty: Empty

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                Group {
                    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else if list.isFetching {
                        ProgressView()
                    } else if list.didFail {
                        // The list is empty because the fetch never arrived — no
                        // connection, or a server that answered with an error —
                        // so the spinner above is replaced by the button that
                        // asks again, in the same spot. Pulling down does the
                        // same thing; this is what says the list is waiting on
                        // something rather than genuinely empty.
                        Button { Task { await list.refresh() } } label: {
                            FeedRetryIcon(help: L("The community list didn’t load. Tap to try again."))
                        }
                    } else if list.activeFilter != nil {
                        // The fetch asked the server for the filtered list and it
                        // came back with nothing, so the filter — not a missing
                        // fetch — is what left the list empty.
                        ContentUnavailableView {
                            Label("No Matching Exercises",
                                  systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No public exercise matches the selected filters.")
                        } actions: {
                            Button("Clear Filters") { list.setFilter(nil) }
                        }
                    } else {
                        empty
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .refreshable { await list.refresh() }
        }
    }
}

private extension View {
    /// Hands a search field's text to the list it searches, held off briefly.
    /// Each new term is a refetch — the search is the server's — which typing a
    /// word straight through would otherwise cost one of per letter;
    /// `.task(id:)` cancels the pending one on the next keystroke.
    func communitySearchTerm(_ text: String, on list: CommunityFeed) -> some View {
        task(id: text) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            list.setSearchTerm(text)
        }
    }
}
