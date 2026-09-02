//
//  CommunityFeed.swift
//  Learn2Sing
//

import Foundation
import Combine

/// A record as returned by the fetch endpoint: the stored document sits in
/// `jsonData` as a JSON string. `entityId` is the id it was persisted under
/// (the public exercise id for SHARED_EXERCISE), and `storageType` says which
/// kind of document it is — which has to be checked, see `fetchPage`.
///
/// `customId1` is the query parameter the record was posted with — the
/// uploader's public user id — and `customName1` is the server's lookup of
/// it: the `customName` that user's PUBLIC_PROFILE document was posted with,
/// which is to say their username. That is where the Community tab's
/// uploader labels come from; a user with no PUBLIC_PROFILE document gets the
/// id echoed back instead, or nothing at all (see `publicNames(in:)`).
struct PersistRecord: Decodable {
    var storageType: String
    var entityId: String
    var jsonData: String
    var customId1: String?
    var customName1: String?
}

/// A fetched document together with the hash of the JSON it came from, which
/// tells `CommunitySync.applyFetched` whether this session has already cached
/// its pattern.
struct FetchedDoc {
    var doc: SharedExerciseDoc
    var source: Int
}

/// One list of community exercises read from the server: the query behind it,
/// how far through that query's pages it has read, and the exercises it has
/// pulled down so far.
///
/// There is one of these for the Community tab — the whole community, see
/// `CommunitySync.list` — and one per uploader profile, scoped to that
/// uploader's public id. Each owns its own order, filter, search term and
/// paging, so a profile can be sorted and searched without disturbing the tab
/// behind it, and every narrowing is applied by the server rather than to the
/// rows already in hand: what comes back *is* the list.
///
/// The parts that belong to the whole session rather than to one list — the
/// pattern cache, the tallies, the share dates, the decode cache — stay on
/// CommunitySync, which every feed hands its pages to (see `applyFetched`).
@MainActor
final class CommunityFeed: ObservableObject {
    /// Records per page of the public fetch, and so the size of the chunk a list
    /// loads at a time: opening the tab — or picking another order — costs one
    /// call, and the next page is asked for as the user scrolls towards the end
    /// of what's loaded (see `loadNextPage`), rather than every exercise in the
    /// community being fetched before anything can be shown.
    static let pageSize = 30
    /// The ceiling on how many pages one query is walked for, so a server that
    /// never reports a last page can't be paged forever.
    private static let maxPages = 300
    /// The key the Community tab's sort menu writes with @AppStorage; the fetch
    /// reads it so the server can do the sorting. The uploader profiles use the
    /// same menu, and so the same key.
    static let sortKey = "communitySort"
    /// Same, for the menu's reverse switch.
    static let reversedKey = "communitySortReversed"
    /// How long to leave a failed page alone for. Short enough that scrolling on
    /// after a blip picks the list back up, long enough that a list parked at
    /// its end doesn't retry in a tight loop.
    private static let failedPageRetryDelay: TimeInterval = 3

    /// The uploader this list is scoped to, as their public user id, or nil for
    /// the whole community. Sent as `customId1` — the parameter every
    /// SHARED_EXERCISE record is persisted with — so the narrowing is the
    /// server's, exactly like the filter and the search term.
    ///
    /// The fetch endpoint does not act on it yet: it hands back every uploader's
    /// records whether the parameter is there or not. So the records it returns
    /// are also matched against this id here (see `append`), and a scoped feed
    /// reads itself to the end rather than waiting to be scrolled — which is
    /// what a profile did before it had a feed of its own. Once the server
    /// honours the parameter both become no-ops: what comes back is already this
    /// uploader's, and there is nothing after their last page to read.
    let uploaderID: String?

    /// Whether this feed speaks for the whole community. Only that one owns the
    /// session-wide bookkeeping that means "no longer in the community" — see
    /// `isComplete` below.
    private var isWholeCommunity: Bool { uploaderID == nil }

    /// The exercises fetched so far, in the order the server returned them.
    /// Empty until the first fetch succeeds.
    @Published private(set) var exercises: [Exercise] = []
    /// true while a refresh is on the wire; drives the initial spinner.
    @Published private(set) var isFetching = false
    /// Whether the last refresh came back empty-handed — no connection, or a
    /// server that answered with an error. It tells a list with no rows on it
    /// that they aren't on their way, which is what the empty state offers its
    /// reload button off. Cleared by the next refresh that lands.
    @Published private(set) var didFail = false
    /// Whether the server has more of this list to give: false once the feed has
    /// been read to its last page (and before the first one lands, when there is
    /// no feed to read). The list puts a spinner under its last row while this
    /// is true, so scrolling to the end of what has loaded shows that more is
    /// coming — and shows nothing at the true end of the list.
    @Published private(set) var hasMorePages = false
    /// true while a page is on the wire, so the list asking for more with every
    /// row it displays costs one fetch rather than one per row.
    ///
    /// Published because turning an ask down has to be temporary: the list only
    /// asks as rows come into view, and by the time it runs out of rows to bring
    /// into view it has none left to ask off the back of. This flipping back to
    /// false is what has it look again at how much is left below the screen (see
    /// `ExerciseListController.checkLoadMore`), so the page that landed while a
    /// fetch was on the wire is followed by the next one without the user having
    /// to nudge the list.
    @Published private(set) var isLoadingPage = false
    /// The narrowing picked in the filter menu, nil for the unnarrowed list.
    /// Handed to the server on every fetch; deliberately not persisted, so a
    /// relaunch never looks like exercises have gone missing. Set it through
    /// `setFilter(_:)`, which refetches.
    @Published private(set) var activeFilter: CommunityFilter?
    /// What the search field holds, trimmed; "" while it is empty. Handed to the
    /// server on every fetch, which narrows the list to the exercises whose
    /// uploader name, exercise name or description matches. Set it through
    /// `setSearchTerm(_:)`, which refetches.
    @Published private(set) var activeSearchTerm = ""
    /// Which uploader each fetched exercise belongs to, by public user id — the
    /// `customId1` its record was persisted with. What a tap on a row's uploader
    /// name is resolved through, since a profile is fetched by id.
    @Published private(set) var uploaderIDs: [UUID: String] = [:]

    /// Bumped by every refresh, so only the newest one's response is applied: a
    /// slow fetch for an order the user has already moved on from must not land
    /// on top of a newer one and leave the list in an order the menu stopped
    /// asking for.
    private var refreshGeneration = 0
    /// How many refreshes are on the wire; `isFetching` is true while any is, so
    /// an abandoned one finishing can't take the initial spinner down with it.
    private var activeFetches = 0
    /// How far through the server's list this one has read, and what's left to
    /// read. Replaced by every refresh; nil until the first one succeeds.
    /// Every move through it — a page read, a stage finished, a failed refresh
    /// put back — is also what says whether there is any of the list left, so
    /// `hasMorePages` is kept in step from here rather than at each of them.
    private var feed: Feed? {
        didSet { hasMorePages = feed.map { !$0.isExhausted } ?? false }
    }
    /// The documents behind `exercises`, in the order they were loaded: what the
    /// refresh's first page returned, plus every page appended since.
    private var loadedDocs: [FetchedDoc] = []
    /// The ids of every record read since the last refresh — the ones that
    /// decoded to nothing (tombstones and the like) included, since a record
    /// already read shouldn't be read again when a later query re-lists it.
    private var loadedEntityIDs: Set<String> = []
    /// When the last page fetch failed, if it hasn't been followed by one that
    /// worked. The list looks again at what's left below the screen every time
    /// anything about it changes, so without a pause a server that's down — or a
    /// device that's offline — would be asked again the instant each attempt
    /// came back.
    private var lastPageFailure: Date?
    /// Set when the list asked for a page and something else was on the wire.
    /// The ask has to be remembered rather than dropped: the list only asks as
    /// rows come into view, and it has none left to bring into view — that's why
    /// it asked.
    private var wantsAnotherPage = false
    /// What's on screen that looks through more of this list than it has been
    /// scrolled to; while it isn't empty the feed reads itself to the end in the
    /// background (see `continueFullLoad`).
    private var fullListNeeds: Set<FullListNeed> = []
    /// true while `continueFullLoad` is walking the feed, so the requests that
    /// start it don't start a second walk.
    private var isFullLoading = false

    init(uploaderID: String? = nil) {
        self.uploaderID = uploaderID
    }

    // MARK: - Order

    /// The order the sort menu currently asks for, which the fetch hands to the
    /// server. Read straight from the @AppStorage key rather than passed in, so
    /// every existing caller of `refresh()` picks it up.
    private static var currentSort: CommunitySort {
        CommunitySort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .hot
    }

    /// Whether the sort menu's reverse switch is on, read the same way. False
    /// for the orders that don't offer it, whatever was last remembered.
    private static var currentReversed: Bool {
        currentSort.isReversible && UserDefaults.standard.bool(forKey: reversedKey)
    }

    // MARK: - Fetch

    /// One server query the list is filled from, and how far through its pages
    /// it has read.
    private struct FeedStage {
        /// The endpoint's `sortBy` values to try, most likely first — see
        /// `CommunitySort.serverSortBy`. A rejected one is dropped and the same
        /// page asked for again with the next.
        var sortBy: [String]
        var sortDirection: String
        var page = 0
    }

    /// How the list is being filled: the queries behind the picked order, in the
    /// order their records belong in, and how far through them it has read. A
    /// refresh builds one of these and reads its first page; the rest are read as
    /// the user scrolls towards the end of the list.
    private struct Feed {
        /// The user, scope and narrowing query items every page of every stage
        /// carries.
        var query: [URLQueryItem]
        var stages: [FeedStage]
        var stageIndex = 0
        /// Whether the whole list (as this order and narrowing see it) has been
        /// read: every stage walked to its last page.
        var isExhausted: Bool { stageIndex >= stages.count }
    }

    /// What one call for one page came back with.
    enum PageResult {
        case page(records: [PersistRecord], isLast: Bool)
        /// This backend spells the `sortBy` the other way; try the next candidate.
        case unknownSortKey
        case failed
    }

    /// Loads the list only if it has nothing to show yet — the first visit of
    /// the session, or one after a fetch that failed. Visiting the tab is not
    /// worth throwing away the pages the user has already scrolled through and
    /// paying for them again: a deliberate reload is pull-to-refresh, and picking
    /// another order, filter or search term refetches on its own.
    func refreshIfNeeded() async {
        guard feed == nil else { return }
        await refresh()
    }

    /// Picks (or clears) the filter menu's narrowing and refetches, since the
    /// server is the one applying it.
    func setFilter(_ filter: CommunityFilter?) {
        guard filter != activeFilter else { return }
        activeFilter = filter
        Task { await refresh() }
    }

    /// Hands the search field's text (or "", once it is cleared) to the server
    /// and refetches, for the same reason: the search looks through the whole
    /// list, and the server is what holds it. The caller coalesces keystrokes —
    /// see `CommunitySearchTermModifier`.
    func setSearchTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed != activeSearchTerm else { return }
        activeSearchTerm = trimmed
        Task { await refresh() }
    }

    /// Reloads the list from the server, in the order the sort menu is set to and
    /// narrowed to the filter menu's pick and the search field's text: the list
    /// starts again at its first page, and the rest is read as the user scrolls.
    /// Called at launch, when the order or narrowing changes, and on
    /// pull-to-refresh; a failure keeps the list — and the pages already read —
    /// from the last successful fetch.
    func refresh() async {
        await performRefresh()
        // The list draws the first page while the refresh is still finishing off
        // (the uploader names), so an ask that arrived then is waiting on this.
        loadPendingPage()
        // A screen that looks through the whole list may be up (see
        // `setNeedsFullList`), in which case it wants the rest of the list the
        // refresh just went back to the first page of. Started rather than
        // awaited, so pull-to-refresh's spinner isn't held down by it.
        Task { await continueFullLoad() }
    }

    private func performRefresh() async {
        activeFetches += 1
        isFetching = true
        defer {
            activeFetches -= 1
            isFetching = activeFetches > 0
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let sort = Self.currentSort
        let reversed = Self.currentReversed
        // Read the new feed from its first page, keeping the old one until the
        // page lands: a failed refresh leaves the list exactly as it was, still
        // able to page on from where the user has scrolled to.
        let previous = (feed: feed, docs: loadedDocs, entityIDs: loadedEntityIDs)
        // Pulling down (or picking another order) is a deliberate retry, so it
        // isn't held off by a page that failed before it.
        lastPageFailure = nil
        feed = makeFeed(sort: sort, reversed: reversed)
        loadedDocs = []
        loadedEntityIDs = []
        guard let records = await nextRecords(generation: generation) else {
            if generation == refreshGeneration {
                (feed, loadedDocs, loadedEntityIDs) = previous
                didFail = true
            }
            return
        }
        guard generation == refreshGeneration else { return }
        didFail = false
        // Applied even when empty: an order and narrowing the server has nothing
        // for is an empty list, not a failed fetch.
        append(records: records)
    }

    /// The queries the picked order's list is filled from, in the order their
    /// records belong in.
    ///
    /// The hot and like/play/download orders come out of the event tables and so
    /// list only exercises with an event on them — no likes, plays or downloads
    /// yet and the server leaves it out, which is how those orders are meant to
    /// rank but would keep a just-published exercise off the tab entirely. So the
    /// order's own query is followed by a second one in its top-up order (see
    /// `CommunitySort.topUpSort`), with the records the first already listed
    /// skipped as it is paged. The narrowing is taken at its word — what it
    /// returns is the list.
    ///
    /// Reversed, those leftovers would belong at the *head* of the list instead:
    /// they have no events at all, so their tally is zero. Which exercises they
    /// are can only be told from the whole answer to the order's own query, so
    /// there is no topping one up a page at a time — and that order is therefore
    /// taken at its word, listing what the query returns and nothing else. It is
    /// the server's to get right (the query leaving out what it has no events for
    /// is a bug there, being fixed), and the list shows whatever it hands back.
    /// (`hot` is never reversed, so its leftovers always go last, ranked the way
    /// that order would rank them.)
    ///
    /// Everything narrowing the query rides along on every page of every stage:
    /// `userId` is who is asking (which is all `filter` means anything next to —
    /// the same public id the PUBLIC_PROFILE document is persisted under),
    /// `customId1` scopes the list to one uploader, and `searchTerm` is matched
    /// by the server against the uploader name, exercise name and description
    /// each record was persisted with (see `CommunitySync.post`).
    private func makeFeed(sort: CommunitySort, reversed: Bool) -> Feed {
        let query = [URLQueryItem(name: "userId", value: PublicIdentifier.user)]
            + (uploaderID.map { [URLQueryItem(name: "customId1", value: $0)] } ?? [])
            + (activeFilter.map { [URLQueryItem(name: "filter", value: $0.serverValue)] } ?? [])
            + (activeSearchTerm.isEmpty ? [] : [URLQueryItem(name: "searchTerm", value: activeSearchTerm)])
        let ranked = FeedStage(sortBy: sort.serverSortBy,
                               sortDirection: sort.serverSortDirection(reversed: reversed))
        guard let topUp = sort.topUpSort, !reversed else {
            return Feed(query: query, stages: [ranked])
        }
        let leftovers = FeedStage(sortBy: topUp.serverSortBy,
                                  sortDirection: topUp.serverSortDirection(reversed: false))
        return Feed(query: query, stages: [ranked, leftovers])
    }

    /// Reads on from the feed until it has a page's worth of records the list
    /// doesn't hold yet, or the feed runs out. nil means a call failed — the
    /// caller keeps what it has and the next scroll or refresh tries again.
    ///
    /// It takes more than one page to fill one where the queries overlap: the
    /// top-up query lists everything the order's own query already returned, so
    /// towards the end of the list a whole page can hold one new exercise or
    /// none. Reading on until there are enough is what keeps that stretch from
    /// growing the list a row at a time, one round trip each.
    private func nextRecords(generation: Int) async -> [PersistRecord]? {
        var new: [PersistRecord] = []
        while new.count < Self.pageSize {
            guard generation == refreshGeneration, feed?.isExhausted == false else { break }
            // A page that failed part way through a fill is still a page short,
            // not a page lost: the feed has moved past what did arrive, so hand
            // that over and leave the rest to the next scroll or refresh.
            guard let records = await advanceFeed(generation: generation) else {
                return new.isEmpty ? nil : new
            }
            new += records
        }
        return new
    }

    /// Reads one page of the feed's current stage and returns the records the
    /// list doesn't already hold. Empty means the page held nothing new; nil that
    /// the call failed.
    private func advanceFeed(generation: Int) async -> [PersistRecord]? {
        guard var feed, !feed.isExhausted else { return [] }
        let stage = feed.stages[feed.stageIndex]
        guard let sortKey = stage.sortBy.first, stage.page < Self.maxPages else {
            feed.stageIndex += 1
            self.feed = feed
            return []
        }
        let result = await Self.fetchPage(storageType: "SHARED_EXERCISE",
                                          sortBy: sortKey,
                                          sortDirection: stage.sortDirection,
                                          page: stage.page,
                                          extraQuery: feed.query)
        // Only a refresh replaces the feed, and it bumps the generation before it
        // does, so an unchanged generation means the copy taken above is still it.
        guard generation == refreshGeneration else { return nil }
        switch result {
        case .failed:
            return nil
        case .unknownSortKey:
            guard feed.stages[feed.stageIndex].sortBy.count > 1 else { return nil }
            feed.stages[feed.stageIndex].sortBy.removeFirst()
            self.feed = feed
            return []
        case .page(let records, let isLast):
            if isLast {
                feed.stageIndex += 1
            } else {
                feed.stages[feed.stageIndex].page += 1
            }
            self.feed = feed
            return read(records)
        }
    }

    /// Takes the records of a page the list hasn't seen — dropping the ones it
    /// has — and marks them read. Marked here rather than where they are put on
    /// screen, because filling one page of the list can take several of the
    /// server's (see `nextRecords`) and the later ones have to know what the
    /// earlier ones already turned up.
    private func read(_ records: [PersistRecord]) -> [PersistRecord] {
        let new = records.filter { !loadedEntityIDs.contains($0.entityId) }
        loadedEntityIDs.formUnion(new.map(\.entityId))
        return new
    }

    /// Fetches one page of one public storage type. Shared with the Home tab's
    /// "New for You" (see NewForYouFeed), which asks the same endpoint a fixed
    /// question of its own rather than borrowing this tab's paging.
    ///
    /// The endpoint requires `sortBy`, `sortDirection`, `page` and `pageSize`;
    /// without them it answers 500. It also ignores the storage type in the path
    /// once those are present, handing back documents of every kind, so the
    /// records are filtered by `storageType` here — while whether this was the
    /// last page is judged on what the server actually returned.
    static func fetchPage(storageType: String,
                          sortBy: String,
                          sortDirection: String,
                          page: Int,
                          extraQuery: [URLQueryItem]) async -> PageResult {
        var components = URLComponents(string: "\(CommunitySync.baseURL)/fetch-public/\(storageType)")
        components?.queryItems = extraQuery + [
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortDirection", value: sortDirection),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        guard let url = components?.url else { return .failed }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if http.statusCode == 400 { return .unknownSortKey }
            guard (200...299).contains(http.statusCode) else {
                print("CommunityFeed: fetch of \(storageType) page \(page) failed with status \(http.statusCode)")
                return .failed
            }
            guard let records = try? JSONDecoder().decode([PersistRecord].self, from: data) else { return .failed }
            // A short page is the last one.
            return .page(records: records.filter { $0.storageType == storageType },
                         isLast: records.count < pageSize)
        } catch {
            print("CommunityFeed: fetch of \(storageType) page \(page) failed: \(error)")
            return .failed
        }
    }

    // MARK: - Paging

    /// Loads the next page and appends it to what's on screen. Called by the list
    /// as the user scrolls towards the end of it; does nothing once the whole
    /// list is in hand, while another page is on the wire, or while a refresh —
    /// which takes the list back to its first page — is.
    func loadNextPage() async {
        guard let feed, !feed.isExhausted else { return }
        // A refresh is on the wire, and what it puts on screen is a first page
        // the list will have to ask past all over again — but it asks as rows
        // come into view, and it has run out of those. So this one is kept.
        guard !isFetching else {
            wantsAnotherPage = true
            return
        }
        // The page already on its way brings rows with it, and the list looks
        // again at how much is left below the screen once it lands — and again
        // when `isLoadingPage` goes back to false, which is what picks the
        // paging back up if the page that landed wasn't enough.
        guard !isLoadingPage else { return }
        if let lastPageFailure, Date().timeIntervalSince(lastPageFailure) < Self.failedPageRetryDelay {
            return
        }
        isLoadingPage = true
        defer {
            isLoadingPage = false
            loadPendingPage()
        }
        let generation = refreshGeneration
        let records = await nextRecords(generation: generation)
        // nil is a call that failed; the list is left as it is and the next look
        // at it — once the pause above is up — tries again.
        lastPageFailure = records == nil ? Date() : nil
        guard let records, !records.isEmpty, generation == refreshGeneration else { return }
        append(records: records)
    }

    /// Loads the page the list asked for while a fetch was already on the wire —
    /// a refresh, or the page before it — now that one is done.
    private func loadPendingPage() {
        guard wantsAnotherPage else { return }
        wantsAnotherPage = false
        Task { await loadNextPage() }
    }

    /// Puts a page's records into the list, after the ones already loaded, and
    /// publishes the result. The uploader names ride along on the records, so
    /// they are taken here and the list is labelled with them as it is applied.
    private func append(records: [PersistRecord]) {
        let sync = CommunitySync.shared
        sync.remember(fetchedNames: Self.publicNames(in: records))
        loadedDocs += sync.decodeDocs(from: records)
        // Only the whole-community feed, read to its last page with nothing
        // narrowing it, is entitled to say an exercise has left the community:
        // a profile, a filter or a search term is a slice of it, and everything
        // outside that slice is still there.
        let isComplete = isWholeCommunity && (feed?.isExhausted ?? false)
            && activeFilter == nil && activeSearchTerm.isEmpty
        let applied = sync.applyFetched(docs: loadedDocs,
                                        entityIDs: loadedEntityIDs,
                                        isComplete: isComplete)
        // The uploader scope is the server's to apply and it doesn't yet, so it
        // is applied to the answer as well — see `uploaderID`.
        if let uploaderID {
            exercises = applied.exercises.filter { applied.uploaderIDs[$0.id] == uploaderID }
        } else {
            exercises = applied.exercises
        }
        uploaderIDs = applied.uploaderIDs
    }

    /// The username per public user id carried by a page of records: the
    /// server's lookup of each record's `customId1` (see `PersistRecord`).
    /// Shared with NewForYouFeed, which labels its rows the same way.
    ///
    /// A user who has never posted a PUBLIC_PROFILE document has no name to look
    /// up, and the endpoint answers with their id — or with nothing — rather
    /// than leaving the field out, so both are dropped here. Their rows keep the
    /// name stamped on the exercise when it was published.
    static func publicNames(in records: [PersistRecord]) -> [String: String] {
        records.reduce(into: [String: String]()) { names, record in
            guard let userID = record.customId1, let name = record.customName1,
                  !name.isEmpty, name != userID
            else { return }
            names[userID] = name
        }
    }

    /// Puts this device's own rename on the rows it belongs to, without a
    /// refetch. Every other name arrives with the records it labels (see
    /// `append`).
    func relabel(with names: [String: String]) {
        var relabelled = exercises
        var changed = false
        for index in relabelled.indices {
            guard let userID = uploaderIDs[relabelled[index].id],
                  let name = names[userID],
                  relabelled[index].uploaderName != name
            else { continue }
            relabelled[index].uploaderName = name
            changed = true
        }
        if changed { exercises = relabelled }
    }

    // MARK: - Full load

    /// Something on screen that shows more of the list than it has been scrolled
    /// to, and so needs the whole thing loaded.
    enum FullListNeed {
        /// The search field: it lists the uploaders it finds among the matches,
        /// which means every match rather than the page of them on screen.
        case search
        /// An uploader's profile, for as long as the server hands back every
        /// uploader's records whatever `customId1` says: theirs can be anywhere
        /// in what comes back, so all of it has to be read to find them.
        case profile
    }

    /// Says whether a screen needing the whole list is up. While one is, the feed
    /// reads itself to the end in the background instead of waiting to be
    /// scrolled.
    func setNeedsFullList(_ needed: Bool, for need: FullListNeed) {
        if needed {
            guard fullListNeeds.insert(need).inserted else { return }
            Task { await continueFullLoad() }
        } else {
            fullListNeeds.remove(need)
        }
    }

    /// Reads the rest of the feed, a page at a time, for as long as something
    /// needs the whole list. Stops on the first page that adds nothing — a failed
    /// call or a feed that has run out — leaving the next refresh to try again.
    private func continueFullLoad() async {
        guard !fullListNeeds.isEmpty, !isFullLoading else { return }
        isFullLoading = true
        defer { isFullLoading = false }
        while !fullListNeeds.isEmpty, !isFetching, feed?.isExhausted == false {
            let loaded = loadedEntityIDs.count
            await loadNextPage()
            if loadedEntityIDs.count == loaded { return }
        }
    }
}
