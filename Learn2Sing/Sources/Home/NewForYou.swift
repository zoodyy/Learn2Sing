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
/// fixed question — the top of the community's "Hot" order — asked once a session
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

    /// How many pages of any one order the candidates are drawn from — the
    /// `page` parameter of the public fetch, which counts from 0. Two pages of
    /// `CommunityFeed.pageSize` is a wide enough net to find `count` exercises
    /// near almost any level, without the category costing a difficulty call for
    /// every exercise in the community.
    static let pageCount = 2

    /// How wide the net is cast: `pageCount` pages' worth of records, however
    /// many queries it takes to find them (see `fetchCandidates`).
    static let candidateTarget = pageCount * CommunityFeed.pageSize

    /// How many exercises the category lists.
    static let count = 5

    /// How long the category goes on saying it is loading once it has started,
    /// however quickly the answer comes back.
    ///
    /// Without a floor there are fetches nothing is ever drawn for. Both of this
    /// object's published flags move inside one turn of the main actor when an
    /// attempt is answered straight away — a request that fails the instant it
    /// is made because there is no connection, or one the URL cache answers out
    /// of the last launch — and SwiftUI draws the state a turn leaves behind,
    /// not the ones it passed through. So the category jumps from the reload
    /// button to five rows (or back to the reload button) with no spinner
    /// between them, and a tap on that button looks like it did nothing at all.
    static let minimumSpinner = Duration.milliseconds(500)

    /// Everything those pages returned, in the order the server ranked them —
    /// what `exercises(atLevel:)` picks out of. Published rather than the pick
    /// itself, since the pick depends on a level that moves with every run the
    /// singer finishes. Empty until the first fetch lands.
    @Published private(set) var candidates: [Exercise] = []

    /// true while the fetch is on the wire — and for as long after it as
    /// `minimumSpinner` asks for. It keeps a second visit to the tab from asking
    /// again mid-flight, and it is what the category draws its spinner off while
    /// it has nothing to list yet.
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

    /// Fetches the candidates and puts them on screen, with the spinner up for
    /// as long as that takes — and never for less than `minimumSpinner`, so that
    /// an answer that arrives too quickly to be drawn is still shown arriving.
    ///
    /// The wait is taken before the result is published rather than after: the
    /// rows and the reload button are both what the category shows *instead* of
    /// the spinner, so holding one of them back for a moment is what leaves the
    /// spinner standing there.
    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        didFail = false
        let started = ContinuousClock.now

        let fetched = await fetchCandidates()

        let remaining = Self.minimumSpinner - started.duration(to: .now)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
        if let fetched {
            candidates = fetched
            hasLoaded = true
        }
        isFetching = false
        // Every way out of the fetch that isn't a list is a call that didn't
        // come back, and that is how the category is told to offer the reload
        // button rather than go on spinning at something that has stopped.
        didFail = fetched == nil
    }

    /// Reads the community's "Hot" order and looks up what the server rates each
    /// exercise at, answering with the candidates it turned up — or nil if any of
    /// the calls didn't come back.
    ///
    /// "Hot" comes out of the server's event tables, so it lists only the
    /// exercises somebody has already played, liked or downloaded. That is how
    /// the ranking is meant to work, but on its own it would leave this category
    /// with however few exercises the community has got round to — and with
    /// nothing at all where the ones it has got round to have since been taken
    /// down, which is where the server stands today. So a short answer is topped
    /// up from the same order the Community tab tops its own "Hot" list up in
    /// (see `CommunitySort.topUpSort`), until the net is `candidateTarget` wide
    /// or there is no more community to read.
    private func fetchCandidates() async -> [Exercise]? {
        let query = [URLQueryItem(name: "userId", value: PublicIdentifier.user)]
        guard var records = await readPages(of: .hot, onto: [], query: query) else { return nil }
        if records.count < Self.candidateTarget, let topUp = CommunitySort.hot.topUpSort {
            guard let topped = await readPages(of: topUp, onto: records, query: query) else {
                return nil
            }
            records = topped
        }
        let entityIDs = Set(records.map(\.entityId))

        let sync = CommunitySync.shared
        sync.remember(fetchedNames: CommunityFeed.publicNames(in: records))
        // Never `isComplete`: these pages are a slice of the community, and
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

        return applied.exercises
    }

    /// Reads pages of one order onto the end of `earlier` — skipping the records
    /// it already holds — until the net is `candidateTarget` wide, `pageCount`
    /// pages have been read, or the query runs out. nil means a call didn't come
    /// back, which abandons the whole fetch: a half-read net is a narrower one,
    /// not a shorter list, and would quietly change what the category is.
    ///
    /// The pages are read one after the other rather than at once: the fetch
    /// endpoint answers for one page per call, and a handful of calls off to the
    /// side of a launch is not worth parallelising.
    private func readPages(of sort: CommunitySort,
                           onto earlier: [PersistRecord],
                           query: [URLQueryItem]) async -> [PersistRecord]? {
        var records = earlier
        // The same record can come back on two pages if the ranking shifts
        // between the calls, and every record "Hot" returned comes back again in
        // the top-up behind it; each belongs in the list once, where the first
        // query to turn it up put it.
        var entityIDs = Set(records.map(\.entityId))
        // Which spelling of the sort key this backend takes, most likely first —
        // see `CommunitySort.serverSortBy`. A rejected one is dropped and the
        // same page asked for again with the next.
        var sortBy = sort.serverSortBy
        var page = 0
        while page < Self.pageCount, records.count < Self.candidateTarget {
            guard let sortKey = sortBy.first else { return nil }
            let result = await CommunityFeed.fetchPage(storageType: "SHARED_EXERCISE",
                                                       sortBy: sortKey,
                                                       sortDirection: sort.serverSortDirection(reversed: false),
                                                       page: page,
                                                       extraQuery: query)
            switch result {
            case .failed:
                return nil
            case .unknownSortKey:
                guard sortBy.count > 1 else { return nil }
                sortBy.removeFirst()
            case .page(let fetched, let isLast):
                for record in fetched where entityIDs.insert(record.entityId).inserted {
                    records.append(record)
                }
                if isLast { return records }
                page += 1
            }
        }
        return records
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
