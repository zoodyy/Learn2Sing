//
//  NewForYou.swift
//  Learn2Sing
//
//  The Home tab's "New for You" category: what the community is singing right
//  now, narrowed to the exercises pitched at this singer.
//

import Foundation
import Combine

/// The candidates the Home tab's "New for You" picks from, and the pick itself:
/// the community's hottest exercises, cut down to the handful whose difficulty
/// sits closest to the singer's own level.
///
/// Deliberately not the Community tab's feed. That one is the whole community in
/// whatever order the sort menu is set to, paged as the user scrolls; this is a
/// fixed question — the first `pageCount` pages of "Hot" — asked once a session
/// and never paged. Sharing the feed would have this category reshuffle whenever
/// the Community tab's sort menu was touched, and have that tab pay for pages
/// nobody scrolled to.
///
/// The narrowing is the singer's skill level against the server's difficulty for
/// each candidate: the same two numbers "Recommended" is built out of, on the
/// same 0-100 hardness scale (see SkillLevel). Those difficulties cost one call
/// per exercise (see `EventAverage`), so they are asked for as one batch when the
/// pages land and left on CommunitySync's cache, where the intro screen's stars
/// read them from too.
@MainActor
final class NewForYouFeed: ObservableObject {
    static let shared = NewForYouFeed()

    /// How many pages of the "Hot" order the candidates are drawn from — the
    /// `page` parameter of the public fetch, which counts from 0. Two pages of
    /// `CommunityFeed.pageSize` is a wide enough net to find `count` exercises
    /// near almost any level, without the category costing a difficulty call for
    /// every exercise in the community.
    static let pageCount = 2

    /// How many exercises the category lists.
    static let count = 5

    /// Everything those pages returned, in the order the server ranked them —
    /// what `exercises(atLevel:)` picks out of. Published rather than the pick
    /// itself, since the pick depends on a level that moves with every run the
    /// singer finishes. Empty until the first fetch lands.
    @Published private(set) var candidates: [Exercise] = []

    /// true while the fetch is on the wire. It keeps a second visit to the tab
    /// from asking again mid-flight, and it is what the category draws its
    /// spinner off while it has nothing to list yet.
    @Published private(set) var isFetching = false

    /// Whether a fetch has succeeded this session. A failed one leaves this
    /// false, so the next visit to the tab tries again.
    @Published private(set) var hasLoaded = false

    /// Whether the last attempt came back with nothing — no connection, or a
    /// server that answered with an error. It is the difference between a
    /// category that is still filling and one that never will on its own, so it
    /// is what puts the reload button in the spinner's place. Cleared the moment
    /// another attempt starts.
    @Published private(set) var didFail = false

    private init() {}

    /// Loads the candidates the first time the Home tab appears, and again after
    /// a fetch that failed. Every later visit leaves them alone: the category
    /// shows five rows and never grows, so there is nothing to page towards and
    /// nothing a refetch would add but a list that changed while it was being
    /// looked at.
    func refreshIfNeeded() async {
        guard !hasLoaded, !isFetching else { return }
        await refresh()
    }

    /// Reads the first `pageCount` pages of the community's "Hot" order and looks
    /// up what the server rates each exercise at.
    ///
    /// The pages are read one after the other rather than at once: the fetch
    /// endpoint answers for one page per call, and two calls off to the side of a
    /// launch is not worth parallelising. A call that fails abandons the whole
    /// thing — a half-read pair of pages is a narrower net, not a shorter list,
    /// and would quietly change what the category is — leaving whatever an
    /// earlier fetch turned up in place.
    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        didFail = false
        // Set on the one path that runs to the end. Every `return` before that
        // is a call that didn't come back, and leaving this false is how the
        // category is told to offer the reload button rather than go on
        // spinning at something that has stopped.
        var succeeded = false
        defer {
            isFetching = false
            didFail = !succeeded
        }

        let sort = CommunitySort.hot
        // Which spelling of the sort key this backend takes, most likely first —
        // see `CommunitySort.serverSortBy`. A rejected one is dropped and the
        // same page asked for again with the next.
        var sortBy = sort.serverSortBy
        let query = [URLQueryItem(name: "userId", value: PublicIdentifier.user)]

        var records: [PersistRecord] = []
        // The same record can come back on both pages if the ranking shifts
        // between the two calls; it belongs in the list once, where the hotter
        // page put it.
        var entityIDs: Set<String> = []
        var page = 0
        var isLastPage = false
        while page < Self.pageCount, !isLastPage {
            guard let sortKey = sortBy.first else { return }
            let result = await CommunityFeed.fetchPage(storageType: "SHARED_EXERCISE",
                                                       sortBy: sortKey,
                                                       sortDirection: sort.serverSortDirection(reversed: false),
                                                       page: page,
                                                       extraQuery: query)
            switch result {
            case .failed:
                return
            case .unknownSortKey:
                guard sortBy.count > 1 else { return }
                sortBy.removeFirst()
            case .page(let fetched, let isLast):
                for record in fetched where entityIDs.insert(record.entityId).inserted {
                    records.append(record)
                }
                isLastPage = isLast
                page += 1
            }
        }

        let sync = CommunitySync.shared
        sync.remember(fetchedNames: CommunityFeed.publicNames(in: records))
        // Never `isComplete`: these two pages are a slice of the community, and
        // everything below them is still there — see `applyFetched`. Patterns,
        // share dates and the exercises the pushed screens resolve through all
        // come out of this, exactly as they do for the Community tab's list.
        let applied = sync.applyFetched(docs: sync.decodeDocs(from: records),
                                        entityIDs: entityIDs,
                                        isComplete: false)

        // Only the candidates with no rating on file. An average taken over the
        // whole community shifts slowly, and the intro screen brings one up to
        // date every time an exercise is opened, so re-asking for sixty of them
        // on every launch would buy a star moving by a hair. What is missing is
        // worth waiting for: without it a candidate can't be placed at all.
        let unrated = applied.exercises.map(\.id).filter { sync.counts.difficulties[$0] == nil }
        await sync.refreshDifficulties(for: unrated)

        candidates = applied.exercises
        hasLoaded = true
        succeeded = true
    }

    /// The exercises the category lists for a singer at `level`: the `count`
    /// candidates whose difficulty sits closest to it, shown in the order the
    /// server ranked them rather than by how well each matched — the category is
    /// the hot list narrowed to this singer, not a chart of near misses.
    ///
    /// The level and the difficulties meet on the hardness scale `SkillLevel`
    /// describes: the server rates an exercise by the average score everyone gets
    /// on it, which says how *easy* it is, and `hardness(ofDifficulty:)` turns
    /// that around.
    ///
    /// A candidate nobody has finished yet has no rating to be matched on, so it
    /// is passed over while there are rated ones to fill the list — and used to
    /// fill it out when there aren't, hottest first, rather than leaving the
    /// category short of what it promises.
    func exercises(atLevel level: Double) -> [Exercise] {
        let difficulties = CommunitySync.shared.counts.difficulties
        // Both hold positions in `candidates`, so the pick can be put back into
        // the server's order once it has been made.
        var rated: [(rank: Int, distance: Double)] = []
        var unrated: [Int] = []
        for (rank, exercise) in candidates.enumerated() {
            guard let difficulty = difficulties[exercise.id] else {
                unrated.append(rank)
                continue
            }
            rated.append((rank, abs(SkillLevel.hardness(ofDifficulty: difficulty) - level)))
        }
        // Closest first, an equally good match going to whichever the server
        // ranked hotter.
        rated.sort { $0.distance == $1.distance ? $0.rank < $1.rank : $0.distance < $1.distance }
        var picked = rated.prefix(Self.count).map(\.rank)
        picked += unrated.prefix(Self.count - picked.count)
        return picked.sorted().map { candidates[$0] }
    }
}
