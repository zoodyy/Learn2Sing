//
//  CommunitySync.swift
//  Learn2Sing
//

import Foundation
import Combine

/// The document persisted per public exercise, under the exercise's own ID:
/// the exercise together with its MIDI pattern and text labels. `exercise` is
/// nil in a tombstone — the overwrite posted when an exercise is made private
/// or deleted, since the server has no delete and keeps one latest record per
/// ID.
///
/// Like and download counts used to live in here too, written back by whoever
/// tapped the heart; they are now the server's own tally of the user events
/// this app posts (see `UserEventType` / `EventSummary`), so nothing but the
/// uploader ever writes this document. Documents written by older versions
/// still carry their `likes`/`downloads` keys — decoding simply ignores them,
/// and the next upload drops them.
struct SharedExerciseDoc: Codable {
    /// The uploader's public user id (see PublicIdentifier) — never the raw
    /// device id. `exercise.id` likewise carries the public exercise id.
    var userID: String
    var exercise: Exercise? = nil
    var midi: [MIDINote] = []
    var texts: [MIDIText]? = nil
    /// When the exercise was first shared, as seconds since 1970. Stamped by the
    /// uploader on the first upload and then carried forward unchanged (edits
    /// don't reset it), so the Community tab can sort by age. Optional: exercises
    /// shared before this field existed have no date until their next upload, and
    /// sort as the oldest.
    var createdAt: Double? = nil
}

/// The document each user keeps on the server under PUBLIC_NAME: their current
/// profile username. Fetched per user on refresh, so renaming yourself in the
/// profile updates the label on your exercises for everyone.
nonisolated struct PublicNameDoc: Codable {
    /// The uploader's public user id (see PublicIdentifier), matching the
    /// `userID` stamped on their shared exercises.
    var userID: String
    var username: String
}

/// What a user did to a public exercise. Posted one call per action to the
/// `user-event` endpoint, which owns the counting: the server keeps one row per
/// user, exercise and event type, so it — not this app — decides what a like or
/// a download total is.
enum UserEventType: String {
    case addLike = "ADD_LIKE"
    case removeLike = "REMOVE_LIKE"
    case addDownload = "ADD_DOWNLOAD"
    case addPlay = "ADD_PLAY"
}

/// The server's tally for one public exercise, from the `event-summary`
/// endpoint. The counts every user sees come from here; this device's own taps
/// are applied optimistically on top until the next refresh.
nonisolated struct EventSummary: Decodable {
    var totalLikes: Int
    var totalDownloads: Int
    var totalPlays: Int
}

/// Connects the Community tab to the server. Each device persists one
/// SHARED_EXERCISE document per public exercise, keyed by the exercise's public
/// ID (see PublicIdentifier — the raw id and device id never leave the device)
/// (re-uploaded when the exercise changes, and overwritten with a tombstone
/// when it goes private or is deleted, so it disappears for everyone) plus a
/// PUBLIC_NAME document with its username, and the tab lists every exercise
/// document — including this device's — via the public fetch endpoint. The list itself is never persisted: it holds exactly
/// what the server returned this session, so every user's Community tab looks
/// the same. Fetched patterns are cached under the standard `midi_<uuid>` /
/// `miditext_<uuid>` UserDefaults keys, so thumbnails, playback, and Download
/// treat community exercises exactly like local ones.
@MainActor
final class CommunitySync: ObservableObject {
    static let shared = CommunitySync()

    nonisolated private static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
    /// UUID strings whose midi/miditext keys were written by a fetch, so a later
    /// fetch can clean up patterns of exercises that left the community list.
    private static let cachedPatternIDsKey = "communityPatternIDs"
    /// UUID strings of this device's exercises that have a live record on the
    /// server; persisted so exercises unshared or deleted while offline (or in
    /// a previous session) still get their tombstone on the next upload.
    private static let uploadedExerciseIDsKey = "communityUploadedExerciseIDs"
    /// Last known like count per public exercise id, persisted so the hearts show
    /// a number straight away at launch instead of flashing zero until the first
    /// event summaries land (and so a failed fetch leaves the last known totals up).
    private static let likeCountsKey = "communityLikeCounts"
    /// Same, for the download count.
    private static let downloadCountsKey = "communityDownloadCounts"
    /// Same, for the play count.
    private static let playCountsKey = "communityPlayCounts"
    /// Share date (seconds since 1970) per public exercise id, so re-uploading an
    /// edited exercise keeps the date it was first shared.
    private static let shareDatesKey = "communityShareDates"
    /// The key the Community tab's sort menu writes with @AppStorage; the fetch
    /// reads it so the server can do the sorting.
    private static let sortKey = "communitySort"
    /// Same, for the menu's reverse switch.
    private static let reversedKey = "communitySortReversed"
    /// Records per page of the public fetch, and the ceiling on how many pages one
    /// refresh walks. The tab searches, filters and groups the whole community by
    /// uploader, so it needs the full list in memory; paging is how the endpoint
    /// hands it over, not something the UI scrolls through.
    private static let pageSize = 100
    private static let maxPages = 100

    /// Every device's public exercises as last fetched, in the order the server
    /// returns them. Empty until the first fetch of the session succeeds.
    @Published private(set) var exercises: [Exercise] = []
    /// true while a fetch is on the wire; drives the tab's initial spinner.
    @Published private(set) var isFetching = false
    /// Like count per public exercise id, as the server summarised it at the last
    /// fetch plus this session's own likes.
    @Published private(set) var likeCounts: [UUID: Int] = [:]
    /// Download count per public exercise id, from the same summaries.
    @Published private(set) var downloadCounts: [UUID: Int] = [:]
    /// Play count per public exercise id, from the same summaries. Not shown on
    /// any row — the sort menu's "Most Played" order is what they are for.
    @Published private(set) var playCounts: [UUID: Int] = [:]
    /// Public ids of the exercises this user has liked. Mirrored into the
    /// profile JSON (and so onto the server) on every change.
    @Published private(set) var likedExerciseIDs: Set<UUID> = []
    /// Public ids of the exercises this user has downloaded. Mirrored into the
    /// profile JSON like the likes, so downloading the same exercise again —
    /// including after a reinstall — doesn't count twice.
    @Published private(set) var downloadedExerciseIDs: Set<UUID> = []
    /// When each fetched exercise was first shared. Missing for exercises shared
    /// before the date was recorded; they sort as the oldest.
    @Published private(set) var shareDates: [UUID: Date] = [:]
    /// The narrowing picked in the Community tab's filter menu, nil for the whole
    /// list. Handed to the server on every fetch; deliberately not persisted, so a
    /// relaunch never looks like exercises have gone missing. Set it through
    /// `setFilter(_:)`, which refetches.
    @Published private(set) var activeFilter: CommunityFilter?

    private weak var store: ExerciseStore?
    private var storeObservation: AnyCancellable?
    private let uploadTrigger = PassthroughSubject<Void, Never>()
    private var uploadDebounce: AnyCancellable?
    private var readyToUpload = false
    /// Body of the last accepted upload per exercise ID; identical re-encodes
    /// are skipped, so the store's frequent unrelated changes don't cause
    /// redundant POSTs.
    private var lastUploadedBodies: [String: Data] = [:]
    /// Same skip-if-unchanged guard for the PUBLIC_NAME document.
    private var lastUploadedName: Data?
    /// Whether a fetch has succeeded since launch; gates stamping share dates.
    private var hasFetched = false
    /// The order the held `exercises` array is actually in: what the fetch that
    /// produced it asked the server for, reverse switch included. nil until the
    /// first fetch of the session lands. `sorted(_:by:reversed:)` falls back to
    /// it for the orders only the server can work out.
    private var fetchedSort: CommunitySort?
    private var fetchedReversed = false
    /// Bumped by every refresh, so only the newest one's response is applied: a
    /// slow fetch for an order the user has already moved on from must not land
    /// on top of a newer one and leave `fetchedSort` describing the wrong list.
    private var refreshGeneration = 0
    /// How many refreshes are on the wire; `isFetching` is true while any is, so
    /// an abandoned one finishing can't take the initial spinner down with it.
    private var activeFetches = 0

    private init() {
        // An earlier version persisted the fetched list under this key.
        UserDefaults.standard.removeObject(forKey: "communityExercises")
        // "Oldest First" is now the reverse switch on top of "Newest First";
        // carry anyone left on it over rather than dropping them to the default.
        if UserDefaults.standard.string(forKey: Self.sortKey) == "oldest" {
            UserDefaults.standard.set(CommunitySort.newest.rawValue, forKey: Self.sortKey)
            UserDefaults.standard.set(true, forKey: Self.reversedKey)
        }
        likeCounts = Self.storedCounts(forKey: Self.likeCountsKey)
        downloadCounts = Self.storedCounts(forKey: Self.downloadCountsKey)
        playCounts = Self.storedCounts(forKey: Self.playCountsKey)
        let dates = UserDefaults.standard.dictionary(forKey: Self.shareDatesKey) as? [String: Double] ?? [:]
        shareDates = dates.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) {
                result[id] = Date(timeIntervalSince1970: entry.value)
            }
        }
    }

    private static func storedCounts(forKey key: String) -> [UUID: Int] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        return stored.reduce(into: [:]) { counts, entry in
            if let id = UUID(uuidString: entry.key) { counts[id] = entry.value }
        }
    }

    /// Call once at launch, after ProfileSync has restored the library (so a
    /// fresh install can't overwrite the server document with an empty list):
    /// fetches the community list and keeps the server copy of this device's
    /// public exercises up to date.
    func start(with store: ExerciseStore) async {
        guard self.store == nil else { return }
        self.store = store
        // Read back the likes and downloads after ProfileSync's restore, so a
        // fresh install picks up the sets that came down with the profile.
        let profile = UserProfile.load()
        likedExerciseIDs = Set((profile.likedExercises ?? []).compactMap(UUID.init(uuidString:)))
        downloadedExerciseIDs = Set((profile.downloadedExercises ?? []).compactMap(UUID.init(uuidString:)))

        // Coalesce bursts of edits into one upload.
        uploadDebounce = uploadTrigger
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { Task { @MainActor in await CommunitySync.shared.upload() } }
        storeObservation = store.objectWillChange
            .sink { [weak self] _ in self?.scheduleUpload() }

        readyToUpload = true
        // One upload per launch so pattern edits (which bypass the store's
        // published properties) and changes made while offline catch up.
        scheduleUpload()
        await refresh()
    }

    /// Request an upload soon; safe to call from any change handler.
    func scheduleUpload() {
        guard readyToUpload else { return }
        uploadTrigger.send()
    }

    // MARK: - Upload

    /// Pushes both server documents: the shared exercises and the username.
    /// Each one is skipped when its body hasn't changed since the last accept.
    private func upload() async {
        await uploadSharedExercises()
        await uploadPublicName()
    }

    /// POSTs each public exercise with its pattern as its own document, then
    /// overwrites the records of exercises that are no longer public with
    /// tombstones so they vanish from everyone's Community tab.
    private func uploadSharedExercises() async {
        guard readyToUpload, let store else { return }
        let userID = PublicIdentifier.user
        let publicExercises = store.exercises.filter { $0.visibility == .public }
        let defaults = UserDefaults.standard
        // Exercise IDs with a live record on the server as of the last upload.
        var onServer = Set(defaults.stringArray(forKey: Self.uploadedExerciseIDsKey) ?? [])
        // Compact and key-sorted: the server rejects documents past roughly
        // 64 KB, and a deterministic encoding makes the skip-if-unchanged
        // comparison below reliable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for exercise in publicExercises {
            let idString = exercise.id.uuidString
            let t = store.texts(for: exercise.id)
            // Publish under the exercise's public id; the raw id stays local
            // (it still keys the pattern lookups and the bookkeeping below).
            var shared = exercise
            shared.id = PublicIdentifier.exercise(exercise.id)
            let doc = SharedExerciseDoc(userID: userID,
                                        exercise: shared,
                                        midi: store.notes(for: exercise.id),
                                        texts: t.isEmpty ? nil : t,
                                        createdAt: shareDate(for: shared.id)?.timeIntervalSince1970)
            guard let body = try? encoder.encode(doc) else { continue }
            if body == lastUploadedBodies[idString] {
                onServer.insert(idString)
                continue
            }
            if await post(body: body,
                          publicExerciseID: shared.id.uuidString.lowercased(),
                          userID: userID,
                          exerciseName: exercise.name) {
                lastUploadedBodies[idString] = body
                onServer.insert(idString)
            }
        }

        let publicIDs = Set(publicExercises.map { $0.id.uuidString })
        for idString in onServer.subtracting(publicIDs) {
            guard let body = try? encoder.encode(SharedExerciseDoc(userID: userID)) else { continue }
            if await post(body: body,
                          publicExerciseID: PublicIdentifier.exerciseID(idString),
                          userID: userID,
                          exerciseName: "") {
                lastUploadedBodies.removeValue(forKey: idString)
                onServer.remove(idString)
            }
        }
        defaults.set(onServer.sorted(), forKey: Self.uploadedExerciseIDsKey)
    }

    /// When this exercise was first shared: the date the last fetch found on the
    /// server, otherwise now — stamped once and persisted, so later uploads of an
    /// edited exercise keep it. nil until a fetch has succeeded this session, so
    /// an upload made before the app has seen the server can't overwrite a date
    /// this install doesn't know about yet (a reinstall, or a launch whose fetch
    /// failed); the next upload after a successful fetch fills it in.
    private func shareDate(for publicExerciseID: UUID) -> Date? {
        if let date = shareDates[publicExerciseID] { return date }
        guard hasFetched else { return nil }
        let now = Date()
        shareDates[publicExerciseID] = now
        persistShareDates()
        return now
    }

    /// POSTs one per-exercise document to the persist endpoint; returns whether
    /// the server accepted it. `userID` is the *uploader's* public id, which stays
    /// stamped on the record even when this device rewrites the document to like
    /// someone else's exercise.
    private func post(body: Data, publicExerciseID: String, userID: String, exerciseName: String) async -> Bool {
        var components = URLComponents(string: "\(Self.baseURL)/persist/\(publicExerciseID)/SHARED_EXERCISE")
        components?.queryItems = [
            URLQueryItem(name: "customId1", value: userID),
            URLQueryItem(name: "customName", value: exerciseName),
            URLQueryItem(name: "customId2", value: publicExerciseID),
        ]
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                return true
            }
            if let http = response as? HTTPURLResponse {
                print("CommunitySync: upload of \(publicExerciseID) failed with status \(http.statusCode)")
            }
        } catch {
            print("CommunitySync: upload of \(publicExerciseID) failed: \(error)")
        }
        return false
    }

    /// POSTs the profile username as this device's PUBLIC_NAME document.
    private func uploadPublicName() async {
        guard readyToUpload else { return }
        let userID = PublicIdentifier.user
        let doc = PublicNameDoc(userID: userID, username: UserProfile.load().username)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(doc), body != lastUploadedName,
              let url = URL(string: "\(Self.baseURL)/persist/\(userID)/PUBLIC_NAME?customId1=\(userID)")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                lastUploadedName = body
            } else if let http = response as? HTTPURLResponse {
                print("CommunitySync: name upload failed with status \(http.statusCode)")
            }
        } catch {
            print("CommunitySync: name upload failed: \(error)")
        }
    }

    // MARK: - Likes, downloads & plays

    /// Adds or removes this user's like on a community exercise, addressed by
    /// its public id. The heart and count update immediately; the like itself is
    /// posted to the server as a user event (which owns the total) and the liked
    /// set goes into the profile JSON (which ProfileSync uploads).
    func toggleLike(for publicExerciseID: UUID) {
        let wasLiked = likedExerciseIDs.contains(publicExerciseID)
        if wasLiked {
            likedExerciseIDs.remove(publicExerciseID)
        } else {
            likedExerciseIDs.insert(publicExerciseID)
        }
        likeCounts[publicExerciseID] = max(0, (likeCounts[publicExerciseID] ?? 0) + (wasLiked ? -1 : 1))
        persistCounts()
        saveProfileSets()
        Task { await postEvent(wasLiked ? .removeLike : .addLike, for: publicExerciseID) }
    }

    /// Counts a download of a community exercise, addressed by its public id.
    /// Only the user's first download of a given exercise counts — the set of
    /// downloaded ids rides along in the profile JSON, so downloading the same
    /// exercise again, on this or a reinstalled device, doesn't post a second
    /// event.
    func registerDownload(for publicExerciseID: UUID) {
        guard downloadedExerciseIDs.insert(publicExerciseID).inserted else { return }
        downloadCounts[publicExerciseID] = (downloadCounts[publicExerciseID] ?? 0) + 1
        persistCounts()
        saveProfileSets()
        Task { await postEvent(.addDownload, for: publicExerciseID) }
    }

    /// Counts a play of a community exercise, addressed by its public id. Called
    /// when playback starts from the Community tab and again when the score
    /// screen's replay button restarts it. Unlike likes and downloads every play
    /// counts, so there is nothing to remember locally.
    func registerPlay(for publicExerciseID: UUID) {
        playCounts[publicExerciseID] = (playCounts[publicExerciseID] ?? 0) + 1
        persistCounts()
        Task { await postEvent(.addPlay, for: publicExerciseID) }
    }

    /// POSTs one user event. The counts themselves are the server's business —
    /// it holds a row per user, exercise and event type — so this says only what
    /// happened and nothing about totals; a failed post shows up as the local
    /// count snapping back to the server's on the next refresh.
    ///
    /// The id in the path is this install's *public* user id, not the Keychain
    /// device id: it identifies the user just as uniquely (the mapping is 1:1
    /// and stable), and the device id must never reach a public endpoint —
    /// see PublicIdentifier for why.
    private func postEvent(_ event: UserEventType, for publicExerciseID: UUID) async {
        let exerciseID = publicExerciseID.uuidString.lowercased()
        guard let url = URL(string: "\(Self.baseURL)/user-event/\(PublicIdentifier.user)/\(exerciseID)/\(event.rawValue)")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("CommunitySync: \(event.rawValue) on \(exerciseID) failed with status \(http.statusCode)")
            }
        } catch {
            print("CommunitySync: \(event.rawValue) on \(exerciseID) failed: \(error)")
        }
    }

    private func persistCounts() {
        func store(_ counts: [UUID: Int], forKey key: String) {
            let stored = counts.reduce(into: [String: Int]()) { dict, entry in
                dict[entry.key.uuidString.lowercased()] = entry.value
            }
            UserDefaults.standard.set(stored, forKey: key)
        }
        store(likeCounts, forKey: Self.likeCountsKey)
        store(downloadCounts, forKey: Self.downloadCountsKey)
        store(playCounts, forKey: Self.playCountsKey)
    }

    private func persistShareDates() {
        let stored = shareDates.reduce(into: [String: Double]()) { dict, entry in
            dict[entry.key.uuidString.lowercased()] = entry.value.timeIntervalSince1970
        }
        UserDefaults.standard.set(stored, forKey: Self.shareDatesKey)
    }

    /// Mirrors the liked and downloaded sets into the profile JSON and asks
    /// ProfileSync to push them, so the hearts — and the "already counted"
    /// downloads — come back after a reinstall.
    private func saveProfileSets() {
        var profile = UserProfile.load()
        profile.likedExercises = likedExerciseIDs.map { $0.uuidString.lowercased() }.sorted()
        profile.downloadedExercises = downloadedExerciseIDs.map { $0.uuidString.lowercased() }.sorted()
        profile.save()
        ProfileSync.shared.scheduleUpload()
    }

    // MARK: - Fetch

    /// A record as returned by the fetch endpoint: the stored document sits in
    /// `jsonData` as a JSON string. `entityId` is the id it was persisted under
    /// (the public exercise id for SHARED_EXERCISE), and `storageType` says which
    /// kind of document it is — which has to be checked, see `fetchRecords`.
    private struct PersistRecord: Decodable {
        var storageType: String
        var entityId: String
        var jsonData: String
    }

    /// The order the Community tab's sort menu currently asks for, which the
    /// fetch hands to the server. Read straight from the @AppStorage key rather
    /// than passed in, so every existing caller of `refresh()` picks it up.
    private static var currentSort: CommunitySort {
        CommunitySort(rawValue: UserDefaults.standard.string(forKey: sortKey) ?? "") ?? .hot
    }

    /// Whether the sort menu's reverse switch is on, read the same way. False
    /// for the orders that don't offer it, whatever was last remembered.
    private static var currentReversed: Bool {
        currentSort.isReversible && UserDefaults.standard.bool(forKey: reversedKey)
    }

    /// Picks (or clears) the filter menu's narrowing and refetches, since the
    /// server is the one applying it.
    func setFilter(_ filter: CommunityFilter?) {
        guard filter != activeFilter else { return }
        activeFilter = filter
        Task { await refresh() }
    }

    /// Reloads the community list from the server, in the order the sort menu is
    /// set to and narrowed to the filter menu's pick. Called at launch, whenever
    /// the Community tab appears, when the filter changes, and on pull-to-refresh;
    /// a failure keeps the list from the last successful fetch of this session.
    func refresh() async {
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
        let filter = activeFilter
        // `filter` only means anything next to the id of the user whose likes are
        // being asked about — the same public id the PUBLIC_NAME document is
        // persisted under.
        let userQuery = [URLQueryItem(name: "userId", value: PublicIdentifier.user)]
        let filterQuery = filter.map { [URLQueryItem(name: "filter", value: $0.serverValue)] } ?? []
        guard var records = await Self.fetchRecords(storageType: "SHARED_EXERCISE",
                                                    sortBy: sort.serverSortBy,
                                                    sortDirection: sort.serverSortDirection(reversed: reversed),
                                                    extraQuery: userQuery + filterQuery)
        else { return }
        // The like/download orders come out of the event tables and so list only
        // exercises that have been liked (or downloaded) at least once. Everything
        // else has a count of zero and belongs at the tail of the descending order
        // anyway, so top the list up rather than let those exercises vanish from
        // the tab. Drop this once the server outer-joins. The `filter` narrowing
        // above is taken at its word — what it returns is the list.
        if sort.isServerEventSorted,
           let rest = await Self.fetchRecords(storageType: "SHARED_EXERCISE",
                                              sortBy: CommunitySort.newest.serverSortBy,
                                              sortDirection: CommunitySort.newest.serverSortDirection(reversed: false),
                                              extraQuery: userQuery + filterQuery) {
            let listed = Set(records.map(\.entityId))
            records += rest.filter { !listed.contains($0.entityId) }
        }
        let docs = Self.decodeDocs(from: records)
        async let names = Self.fetchPublicNames(for: Set(docs.map(\.userID)))
        async let summaries = Self.fetchEventSummaries(for: docs.compactMap { $0.exercise?.id })
        let (fetchedNames, fetchedSummaries) = (await names, await summaries)
        // A newer refresh started while this one was on the wire, so this list is
        // in an order the menu has already moved on from.
        guard generation == refreshGeneration else { return }
        apply(docs: docs,
              names: fetchedNames,
              summaries: fetchedSummaries,
              sort: sort,
              reversed: reversed)
    }

    /// Walks every page of one public storage type and returns the records in the
    /// server's order, or nil if any page failed — the caller keeps its previous
    /// list rather than showing half of a new one.
    ///
    /// The endpoint requires `sortBy`, `sortDirection`, `page` and `pageSize`;
    /// without them it answers 500. It also ignores the storage type in the path
    /// once those are present, handing back documents of every kind, so the
    /// records are filtered by `storageType` here.
    private static func fetchRecords(storageType: String,
                                     sortBy: [String],
                                     sortDirection: String,
                                     extraQuery: [URLQueryItem] = []) async -> [PersistRecord]? {
        var sortKeys = sortBy
        var all: [PersistRecord] = []
        var page = 0
        while page < maxPages {
            guard let sortKey = sortKeys.first else { return nil }
            var components = URLComponents(string: "\(baseURL)/fetch-public/\(storageType)")
            components?.queryItems = extraQuery + [
                URLQueryItem(name: "sortBy", value: sortKey),
                URLQueryItem(name: "sortDirection", value: sortDirection),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "pageSize", value: String(pageSize)),
            ]
            guard let url = components?.url else { return nil }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse else { return nil }
                // A rejected sort key means this backend spells it the other way;
                // retry the same page with the next candidate.
                if http.statusCode == 400, sortKeys.count > 1 {
                    sortKeys.removeFirst()
                    continue
                }
                guard (200...299).contains(http.statusCode) else {
                    print("CommunitySync: fetch of \(storageType) page \(page) failed with status \(http.statusCode)")
                    return nil
                }
                guard let records = try? JSONDecoder().decode([PersistRecord].self, from: data) else { return nil }
                all += records.filter { $0.storageType == storageType }
                // A short page is the last one.
                if records.count < pageSize { return all }
                page += 1
            } catch {
                print("CommunitySync: fetch of \(storageType) page \(page) failed: \(error)")
                return nil
            }
        }
        return all
    }

    /// Fetches every uploader's PUBLIC_NAME document in parallel and returns the
    /// non-empty usernames by public user id. Users whose fetch fails are simply
    /// absent, so their exercises keep the name stamped at publish time.
    private static func fetchPublicNames(for userIDs: Set<String>) async -> [String: String] {
        await withTaskGroup(of: (String, String)?.self) { group in
            for userID in userIDs {
                group.addTask {
                    // The endpoint keeps one latest record per id, so one page of
                    // one record is the current name.
                    guard let record = await fetchRecords(
                        storageType: "PUBLIC_NAME",
                        sortBy: CommunitySort.newest.serverSortBy,
                        sortDirection: CommunitySort.newest.serverSortDirection(reversed: false),
                        extraQuery: [URLQueryItem(name: "customId1", value: userID)]
                    )?.first,
                          let doc = try? JSONDecoder().decode(PublicNameDoc.self,
                                                              from: Data(record.jsonData.utf8)),
                          !doc.username.isEmpty
                    else { return nil }
                    return (userID, doc.username)
                }
            }
            var names: [String: String] = [:]
            for await pair in group {
                if let (userID, username) = pair { names[userID] = username }
            }
            return names
        }
    }

    /// Fetches the server's like/download/play tally for each exercise in
    /// parallel. Exercises whose summary fails to load are absent, and keep the
    /// counts already on screen.
    private static func fetchEventSummaries(for ids: [UUID]) async -> [UUID: EventSummary] {
        await withTaskGroup(of: (UUID, EventSummary)?.self) { group in
            for id in ids {
                group.addTask {
                    guard let url = URL(string: "\(baseURL)/event-summary/\(id.uuidString.lowercased())"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                          let summary = try? JSONDecoder().decode(EventSummary.self, from: data)
                    else { return nil }
                    return (id, summary)
                }
            }
            var summaries: [UUID: EventSummary] = [:]
            for await pair in group {
                if let (id, summary) = pair { summaries[id] = summary }
            }
            return summaries
        }
    }

    /// One document per record; tombstones and documents that fail to decode
    /// (e.g. the pre-split whole-library documents, or ones written by a newer
    /// app version) are skipped.
    private static func decodeDocs(from records: [PersistRecord]) -> [SharedExerciseDoc] {
        let decoder = JSONDecoder()
        return records.compactMap {
            try? decoder.decode(SharedExerciseDoc.self, from: Data($0.jsonData.utf8))
        }
    }

    /// Publishes the fetched exercises — relabelled with each uploader's current
    /// PUBLIC_NAME where one was fetched, and counted by the server's event
    /// summaries — and swaps their patterns into the UserDefaults cache,
    /// dropping patterns of exercises no longer shared.
    /// `sort` and `reversed` are what this fetch asked the server for, remembered
    /// alongside the list so `sorted(_:by:reversed:)` knows what order it is in.
    private func apply(docs: [SharedExerciseDoc],
                       names: [String: String],
                       summaries: [UUID: EventSummary],
                       sort: CommunitySort,
                       reversed: Bool) {
        let defaults = UserDefaults.standard
        var seenExercises = Set<UUID>()
        var fetched: [Exercise] = []
        var cachedIDs: [String] = []
        var counts: [UUID: Int] = [:]
        var downloads: [UUID: Int] = [:]
        var plays: [UUID: Int] = [:]
        var dates: [UUID: Date] = [:]
        for doc in docs {
            guard var exercise = doc.exercise, exercise.visibility == .public,
                  seenExercises.insert(exercise.id).inserted else { continue }
            if let name = names[doc.userID] { exercise.uploaderName = name }
            fetched.append(exercise)
            // An exercise whose summary didn't load keeps whatever count is on
            // screen instead of dropping to zero.
            counts[exercise.id] = summaries[exercise.id]?.totalLikes ?? likeCounts[exercise.id] ?? 0
            downloads[exercise.id] = summaries[exercise.id]?.totalDownloads ?? downloadCounts[exercise.id] ?? 0
            plays[exercise.id] = summaries[exercise.id]?.totalPlays ?? playCounts[exercise.id] ?? 0
            if let createdAt = doc.createdAt {
                dates[exercise.id] = Date(timeIntervalSince1970: createdAt)
            }
            // Every fetched exercise carries its public id, a namespace distinct
            // from any local raw id, so caching the server pattern here can never
            // clobber a local one — even for this device's own uploads.
            cachedIDs.append(exercise.id.uuidString)
            if let data = try? JSONEncoder().encode(doc.midi) {
                defaults.set(data, forKey: ExerciseStore.midiKey(exercise.id))
            }
            if let texts = doc.texts, let data = try? JSONEncoder().encode(texts) {
                defaults.set(data, forKey: ExerciseStore.midiTextKey(exercise.id))
            } else {
                defaults.removeObject(forKey: ExerciseStore.midiTextKey(exercise.id))
            }
        }
        let stale = Set(defaults.stringArray(forKey: Self.cachedPatternIDsKey) ?? [])
            .subtracting(cachedIDs)
        for idString in stale {
            guard let id = UUID(uuidString: idString) else { continue }
            defaults.removeObject(forKey: ExerciseStore.midiKey(id))
            defaults.removeObject(forKey: ExerciseStore.midiTextKey(id))
        }
        defaults.set(cachedIDs, forKey: Self.cachedPatternIDsKey)
        exercises = fetched
        fetchedSort = sort
        fetchedReversed = reversed
        likeCounts = counts
        downloadCounts = downloads
        playCounts = plays
        // Dates this device stamped but hasn't uploaded yet (or whose upload the
        // server hasn't handed back yet) are kept, so an exercise doesn't lose
        // its date between the stamp and the next fetch.
        shareDates = shareDates.merging(dates) { _, fetched in fetched }
        hasFetched = true
        persistCounts()
        persistShareDates()
    }

    // MARK: - Sorting

    /// The community exercises in the order the given sort asks for. Exercises
    /// with no recorded share date (shared before dates existed) count as the
    /// oldest, and ties break by name so the order never jitters between fetches.
    ///
    /// The fetch already asks the server for this order, but the same ordering is
    /// needed for things the server can't sort: the search results, the like
    /// filters, the per-uploader profiles, and the moments between changing the
    /// sort menu and the next refresh.
    ///
    /// The two server-only orders (see `isServerOrdered`) are instead kept as
    /// the fetch returned them — a subset of a sorted list is still sorted, so
    /// the searches and profiles come out right without the app knowing what the
    /// server ranked on. `reversed` is already in that order too, having been
    /// fetched as `sortDirection`, so it's applied to every *other* order only.
    ///
    /// Which is also why picking one of those two shows the list in the order it
    /// is already in until the refetch lands: their ranking isn't in what came
    /// back, so the held list can't be put in it, and ranking by the positions it
    /// happens to have would shuffle the rows into an order that is neither the
    /// old one nor the new one — a visible reshuffle a moment before the real one.
    func sorted(_ exercises: [Exercise], by sort: CommunitySort, reversed: Bool) -> [Exercise] {
        var sort = sort
        var reversed = reversed
        if sort.isServerOrdered, let fetchedSort,
           (sort, reversed) != (fetchedSort, fetchedReversed) {
            sort = fetchedSort
            reversed = fetchedReversed
        }

        func byName(_ a: Exercise, _ b: Exercise) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func date(_ exercise: Exercise) -> Date {
            shareDates[exercise.id] ?? .distantPast
        }
        // Position in the fetched list, for the orders only the server knows.
        // Exercises absent from it (there are none today) go to the tail.
        var fetchedRank: [UUID: Int] = [:]
        if sort.isServerOrdered {
            for (index, exercise) in self.exercises.enumerated() where fetchedRank[exercise.id] == nil {
                fetchedRank[exercise.id] = index
            }
        }
        let ordered = exercises.sorted { a, b in
            switch sort {
            case .hot, .recentlyUpdated:
                let (x, y) = (fetchedRank[a.id] ?? .max, fetchedRank[b.id] ?? .max)
                return x == y ? byName(a, b) : x < y
            case .mostPlayed:
                let (x, y) = (playCounts[a.id] ?? 0, playCounts[b.id] ?? 0)
                return x == y ? byName(a, b) : x > y
            case .mostLiked:
                let (x, y) = (likeCounts[a.id] ?? 0, likeCounts[b.id] ?? 0)
                return x == y ? byName(a, b) : x > y
            case .mostDownloaded:
                let (x, y) = (downloadCounts[a.id] ?? 0, downloadCounts[b.id] ?? 0)
                return x == y ? byName(a, b) : x > y
            case .newest:
                let (x, y) = (date(a), date(b))
                return x == y ? byName(a, b) : x > y
            case .alphabetical:
                return byName(a, b)
            }
        }
        return reversed && !sort.isServerOrdered ? ordered.reversed() : ordered
    }
}
