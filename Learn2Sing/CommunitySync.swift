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
/// profile username, so renaming yourself in the profile updates the label on
/// your exercises for everyone. There is one document per user and so one fetch
/// per uploader: the names are cached and looked up once a session rather than
/// on every refresh (see `CommunitySync.refreshUploaderNames`), which means
/// someone else's rename shows up on their next launch, and this device's own
/// goes into the cache as it is uploaded.
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
/// are applied optimistically on top until the next fetch.
///
/// One call answers for one exercise, so it is fetched when an exercise is
/// opened rather than for the whole list — the counts appear on the intro
/// screen only, and summarising a few hundred exercises to draw none of them
/// meant a few hundred calls on every refresh (every change of sort order
/// included). The orders that rank on these counts are the server's to work out
/// (see `CommunitySort.isServerOrdered`).
nonisolated struct EventSummary: Decodable {
    var totalLikes: Int
    var totalDownloads: Int
    var totalPlays: Int
}

/// The like/download/play tallies and this user's own likes and downloads,
/// published on their own object rather than as part of CommunitySync.
///
/// They change on a tap — the heart on the intro screen — and that screen is the
/// only thing that draws them, while the Community tab's list rebuilds every row
/// (reading every pattern back out of UserDefaults) whenever CommunitySync
/// publishes. Keeping the counts out of that made the difference between a heart
/// that fills on the next frame and one that waits for a few hundred rows to be
/// rebuilt first.
///
/// Held by CommunitySync as a plain `let`, which is what keeps a change here
/// from publishing there as well; only CommunitySync writes to it.
@MainActor
final class CommunityCounts: ObservableObject {
    /// Like count per public exercise id: the server's tally as of the last time
    /// that exercise was opened (see `CommunitySync.refreshSummary(for:)`), plus
    /// this device's own likes. Exercises never opened on this device have no
    /// entry until one is, which is why nothing but the intro screen shows the
    /// number.
    @Published fileprivate(set) var likeCounts: [UUID: Int] = [:]
    /// Download count per public exercise id, from the same summaries.
    @Published fileprivate(set) var downloadCounts: [UUID: Int] = [:]
    /// Play count per public exercise id, from the same summaries. Not shown
    /// anywhere; kept so a play registered this session is reflected the moment
    /// the exercise is reopened.
    @Published fileprivate(set) var playCounts: [UUID: Int] = [:]
    /// Public ids of the exercises this user has liked. Mirrored into the
    /// profile JSON (and so onto the server) on every change.
    @Published fileprivate(set) var likedExerciseIDs: Set<UUID> = []
    /// Public ids of the exercises this user has downloaded. Mirrored into the
    /// profile JSON like the likes, so downloading the same exercise again —
    /// including after a reinstall — doesn't count twice.
    @Published fileprivate(set) var downloadedExerciseIDs: Set<UUID> = []
}

/// Connects the Community tab to the server. Each device persists one
/// SHARED_EXERCISE document per public exercise, keyed by the exercise's public
/// ID (see PublicIdentifier — the raw id and device id never leave the device)
/// (re-uploaded when the exercise changes, and overwritten with a tombstone
/// when it goes private or is deleted, so it disappears for everyone) plus a
/// PUBLIC_NAME document with its username, and the tab lists those exercise
/// documents — this device's included — via the public fetch endpoint, a page of
/// `pageSize` at a time as the user scrolls (see `refresh` and `loadNextPage`).
/// The list itself is never persisted: it holds exactly
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
    /// Username per public user id as last fetched, persisted so a relaunch —
    /// and every refresh after the first of a session — can label the list
    /// without a PUBLIC_NAME call per uploader.
    private static let uploaderNamesKey = "communityUploaderNames"
    /// The key the Community tab's sort menu writes with @AppStorage; the fetch
    /// reads it so the server can do the sorting.
    private static let sortKey = "communitySort"
    /// Same, for the menu's reverse switch.
    private static let reversedKey = "communitySortReversed"
    /// Records per page of the public fetch, and so the size of the chunk the
    /// Community tab loads at a time: opening the tab — or picking another order —
    /// costs one call, and the next page is asked for as the user scrolls towards
    /// the end of what's loaded (see `loadNextPage`), rather than every exercise in
    /// the community being fetched before anything can be shown.
    static let pageSize = 30
    /// The ceiling on how many pages one query is walked for, so a server that
    /// never reports a last page can't be paged forever.
    private static let maxPages = 300

    /// Every device's public exercises as last fetched, in the order the server
    /// returns them. Empty until the first fetch of the session succeeds.
    @Published private(set) var exercises: [Exercise] = []
    /// true while a fetch is on the wire; drives the tab's initial spinner.
    @Published private(set) var isFetching = false
    /// The tallies and this user's likes and downloads. Its own observable
    /// object, so the heart can fill without the whole Community list being
    /// rebuilt — see CommunityCounts. The properties below read and write
    /// through to it.
    let counts = CommunityCounts()
    private var likeCounts: [UUID: Int] {
        get { counts.likeCounts }
        set { counts.likeCounts = newValue }
    }
    private var downloadCounts: [UUID: Int] {
        get { counts.downloadCounts }
        set { counts.downloadCounts = newValue }
    }
    private var playCounts: [UUID: Int] {
        get { counts.playCounts }
        set { counts.playCounts = newValue }
    }
    private var likedExerciseIDs: Set<UUID> {
        get { counts.likedExerciseIDs }
        set { counts.likedExerciseIDs = newValue }
    }
    private var downloadedExerciseIDs: Set<UUID> {
        get { counts.downloadedExerciseIDs }
        set { counts.downloadedExerciseIDs = newValue }
    }
    /// When each fetched exercise was first shared. Missing for exercises shared
    /// before the date was recorded; they sort as the oldest.
    @Published private(set) var shareDates: [UUID: Date] = [:]
    /// The narrowing picked in the Community tab's filter menu, nil for the whole
    /// list. Handed to the server on every fetch; deliberately not persisted, so a
    /// relaunch never looks like exercises have gone missing. Set it through
    /// `setFilter(_:)`, which refetches.
    @Published private(set) var activeFilter: CommunityFilter?

    /// Which tap on each exercise's heart is the live one, bumped by every
    /// toggle. A post or a tally that comes back for an older tap has been
    /// overtaken and is dropped — see `settleLike`.
    private var likeGenerations: [UUID: Int] = [:]
    /// Exercises whose like hasn't been settled with the server yet. While an id
    /// is in here the only tally allowed to land on it is the one fetched to
    /// settle it; anything else was asked for before the like was counted and
    /// would undo the tap on screen.
    private var pendingLikes: Set<UUID> = []

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
    /// How far through the server's list the tab has read, and what's left to
    /// read. Replaced by every refresh; nil until the first one succeeds.
    private var feed: Feed?
    /// The documents behind `exercises`, in the order they were loaded: what the
    /// refresh's first page returned, plus every page appended since.
    private var loadedDocs: [FetchedDoc] = []
    /// The ids of every record read since the last refresh — the ones that
    /// decoded to nothing (tombstones and the like) included, since a record
    /// already read shouldn't be read again when a later query re-lists it.
    private var loadedEntityIDs: Set<String> = []
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
    /// When the last page fetch failed, if it hasn't been followed by one that
    /// worked. The list looks again at what's left below the screen every time
    /// anything about it changes, so without a pause a server that's down — or a
    /// device that's offline — would be asked again the instant each attempt
    /// came back.
    private var lastPageFailure: Date?
    /// How long to leave a failed page alone for. Short enough that scrolling on
    /// after a blip picks the list back up, long enough that a list parked at
    /// its end doesn't retry in a tight loop.
    private static let failedPageRetryDelay: TimeInterval = 3
    /// Set when the list asked for a page and something else was on the wire.
    /// The ask has to be remembered rather than dropped: the list only asks as
    /// rows come into view, and it has none left to bring into view — that's why
    /// it asked.
    private var wantsAnotherPage = false
    /// What's on screen that looks through more of the community than the list
    /// has been scrolled to; while it isn't empty the feed reads itself to the
    /// end in the background (see `continueFullLoad`).
    private var fullListNeeds: Set<FullListNeed> = []
    /// true while `continueFullLoad` is walking the feed, so the requests that
    /// start it don't start a second walk.
    private var isFullLoading = false
    /// Each uploader's current username by public user id, as last fetched.
    /// Persisted (see `uploaderNamesKey`), because one PUBLIC_NAME document per
    /// uploader is one call per uploader — worth making once a session, not on
    /// every refresh.
    private var uploaderNames: [String: String] = [:]
    /// Which uploader each listed exercise belongs to, so names arriving after
    /// the list can be put on the right rows.
    private var uploaderIDs: [UUID: String] = [:]
    /// Whether this session has been through the uploaders once already; after
    /// that only uploaders with no cached name are looked up.
    private var hasRefreshedNames = false
    /// The fetched JSON each exercise was last decoded from, hashed, with what it
    /// decoded to. A refresh handing back a document already in here — which is
    /// all of them when only the sort order changed — skips both the decode and
    /// the re-encode of its pattern into UserDefaults, since both would produce
    /// exactly what is already there. In-session only: hash seeds differ between
    /// launches, and the first refresh of a session should write the cache anyway.
    private var decodedDocs: [String: (source: Int, doc: SharedExerciseDoc)] = [:]
    /// The hash of the JSON each exercise's cached `midi_<uuid>` /
    /// `miditext_<uuid>` pattern was written from, so a refresh that hands the
    /// same document back doesn't encode and rewrite it. In-session only, like
    /// `decodedDocs`.
    private var cachedPatternSources: [UUID: Int] = [:]

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
        uploaderNames = UserDefaults.standard.dictionary(forKey: Self.uploaderNamesKey) as? [String: String] ?? [:]
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
        var components = URLComponents(string: "\(Self.baseURL)/persist/\(userID)/PUBLIC_NAME")
        components?.queryItems = [
            URLQueryItem(name: "customId1", value: userID),
            URLQueryItem(name: "customName", value: doc.username),
        ]
        guard let body = try? encoder.encode(doc), body != lastUploadedName,
              let url = components?.url
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                lastUploadedName = body
                // This device's own rename, straight into the cache the list is
                // labelled from — otherwise the tab would keep showing the old
                // name on this user's own exercises until the next session, since
                // the names are no longer refetched on every refresh.
                remember(names: [userID: doc.username])
            } else if let http = response as? HTTPURLResponse {
                print("CommunitySync: name upload failed with status \(http.statusCode)")
            }
        } catch {
            print("CommunitySync: name upload failed: \(error)")
        }
    }

    // MARK: - Likes, downloads & plays

    /// Brings one exercise's like/download/play counts up to date from the
    /// server. Called when a community exercise is opened — the intro screen is
    /// the only place the numbers are shown, and the endpoint answers for one
    /// exercise at a time, so asking for the whole list on every refresh was one
    /// call per exercise to draw nothing.
    ///
    /// A failed call, or one the user has tapped through while it was on the
    /// wire, leaves the counts alone: the optimistic bump from a like, download
    /// or play made meanwhile is the newer truth, and the server's tally comes
    /// back on the next open. A like still on the wire does the same — the tally
    /// that settles it is the one `settleLike` fetches, after the event has been
    /// posted and so counted.
    func refreshSummary(for publicExerciseID: UUID) async {
        let generation = likeGenerations[publicExerciseID]
        let before = (likeCounts[publicExerciseID],
                      downloadCounts[publicExerciseID],
                      playCounts[publicExerciseID])
        guard let summary = await Self.fetchEventSummary(for: publicExerciseID) else { return }
        guard generation == likeGenerations[publicExerciseID],
              !pendingLikes.contains(publicExerciseID),
              before == (likeCounts[publicExerciseID],
                         downloadCounts[publicExerciseID],
                         playCounts[publicExerciseID]) else { return }
        likeCounts[publicExerciseID] = summary.totalLikes
        downloadCounts[publicExerciseID] = summary.totalDownloads
        playCounts[publicExerciseID] = summary.totalPlays
        persistCounts()
    }

    /// Adds or removes this user's like on a community exercise, addressed by
    /// its public id.
    ///
    /// The tap is taken at face value: the heart and the count change on this
    /// frame, and nothing else — not the write to UserDefaults, not the profile
    /// JSON, and certainly not the server — happens before they do. Posting the
    /// event and settling the count against the server's tally is left to
    /// `settleLike`, which also puts the tap back if the post never lands.
    func toggleLike(for publicExerciseID: UUID) {
        let liked = !likedExerciseIDs.contains(publicExerciseID)
        let generation = (likeGenerations[publicExerciseID] ?? 0) + 1
        likeGenerations[publicExerciseID] = generation
        pendingLikes.insert(publicExerciseID)
        apply(like: liked, for: publicExerciseID)
        Task {
            // Off the tap itself: the profile JSON is read, rewritten and
            // written back whole, which is work the heart shouldn't wait on.
            persistCounts()
            saveProfileSets()
            await settleLike(liked, for: publicExerciseID, generation: generation)
        }
    }

    /// The local half of a like: this user's heart and the exercise's count,
    /// which is all the button draws from. Also how a like that the server never
    /// took is undone.
    private func apply(like liked: Bool, for publicExerciseID: UUID) {
        if liked {
            likedExerciseIDs.insert(publicExerciseID)
        } else {
            likedExerciseIDs.remove(publicExerciseID)
        }
        likeCounts[publicExerciseID] = max(0, (likeCounts[publicExerciseID] ?? 0) + (liked ? 1 : -1))
    }

    /// Settles a like the user has already seen take effect: posts the event the
    /// server counts, then reads back the tally it produced so the number on
    /// screen becomes the server's rather than this device's arithmetic — which
    /// is off by every like made from another device since the exercise was
    /// opened.
    ///
    /// A post that fails takes the heart back off: the liked set rides along in
    /// the profile JSON, so a like the server never counted would otherwise
    /// outlive the session and even a reinstall.
    ///
    /// `generation` is the tap this is settling. A newer tap on the same
    /// exercise makes this one stale — the newer one owns the state, the pending
    /// mark and the settling from then on, so everything below is dropped.
    private func settleLike(_ liked: Bool, for publicExerciseID: UUID, generation: Int) async {
        let posted = await postEvent(liked ? .addLike : .removeLike, for: publicExerciseID)
        guard likeGenerations[publicExerciseID] == generation else { return }
        guard posted else {
            pendingLikes.remove(publicExerciseID)
            apply(like: !liked, for: publicExerciseID)
            persistCounts()
            saveProfileSets()
            return
        }
        let summary = await Self.fetchEventSummary(for: publicExerciseID)
        guard likeGenerations[publicExerciseID] == generation else { return }
        pendingLikes.remove(publicExerciseID)
        guard let summary else { return }
        likeCounts[publicExerciseID] = summary.totalLikes
        downloadCounts[publicExerciseID] = summary.totalDownloads
        playCounts[publicExerciseID] = summary.totalPlays
        persistCounts()
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

    /// POSTs one user event, reporting whether the server took it. The counts
    /// themselves are the server's business — it holds a row per user, exercise
    /// and event type — so this says only what happened and nothing about
    /// totals; a failed post shows up as the local count snapping back to the
    /// server's on the next refresh (for a like, straight away — see
    /// `settleLike`).
    ///
    /// The id in the path is this install's *public* user id, not the Keychain
    /// device id: it identifies the user just as uniquely (the mapping is 1:1
    /// and stable), and the device id must never reach a public endpoint —
    /// see PublicIdentifier for why.
    @discardableResult
    private func postEvent(_ event: UserEventType, for publicExerciseID: UUID) async -> Bool {
        let exerciseID = publicExerciseID.uuidString.lowercased()
        guard let url = URL(string: "\(Self.baseURL)/user-event/\(PublicIdentifier.user)/\(exerciseID)/\(event.rawValue)")
        else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("CommunitySync: \(event.rawValue) on \(exerciseID) failed with status \(http.statusCode)")
                return false
            }
            return true
        } catch {
            print("CommunitySync: \(event.rawValue) on \(exerciseID) failed: \(error)")
            return false
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
    /// kind of document it is — which has to be checked, see `fetchPage`.
    private struct PersistRecord: Decodable {
        var storageType: String
        var entityId: String
        var jsonData: String
    }

    /// One server query the list is filled from, and how far through its pages
    /// the tab has read.
    private struct FeedStage {
        /// The endpoint's `sortBy` values to try, most likely first — see
        /// `CommunitySort.serverSortBy`. A rejected one is dropped and the same
        /// page asked for again with the next.
        var sortBy: [String]
        var sortDirection: String
        var page = 0
    }

    /// How the Community tab's list is being filled: the queries behind the
    /// picked order, in the order their records belong in, and how far through
    /// them the list has read. A refresh builds one of these and reads its first
    /// page; the rest are read as the user scrolls towards the end of the list.
    private struct Feed {
        var sort: CommunitySort
        var reversed: Bool
        /// The user and filter query items every page of every stage carries.
        var query: [URLQueryItem]
        var stages: [FeedStage]
        var stageIndex = 0
        /// Whether the whole community (as this order and filter see it) has been
        /// read: every stage walked to its last page.
        var isExhausted: Bool { stageIndex >= stages.count }
    }

    /// What one call for one page came back with.
    private enum PageResult {
        case page(records: [PersistRecord], isLast: Bool)
        /// This backend spells the `sortBy` the other way; try the next candidate.
        case unknownSortKey
        case failed
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

    /// Loads the list only if the tab has nothing to show yet — the first visit of
    /// the session, or one after a fetch that failed. Visiting the tab is not
    /// worth throwing away the pages the user has already scrolled through and
    /// paying for them again: a deliberate reload is pull-to-refresh, and picking
    /// another order or filter refetches on its own.
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

    /// Reloads the community list from the server, in the order the sort menu is
    /// set to and narrowed to the filter menu's pick: the list starts again at its
    /// first page, and the rest is read as the user scrolls. Called at launch,
    /// when the sort or filter changes, and on pull-to-refresh; a failure keeps
    /// the list — and the pages already read — from the last successful fetch.
    func refresh() async {
        await performRefresh()
        // The list draws the first page while the refresh is still finishing off
        // (the uploader names), so an ask that arrived then is waiting on this.
        loadPendingPage()
        // A screen that looks through the whole community may be up (see
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
        // page lands: a failed refresh leaves the tab exactly as it was, still
        // able to page on from where the user has scrolled to.
        let previous = (feed: feed, docs: loadedDocs, entityIDs: loadedEntityIDs)
        // Pulling down (or picking another order) is a deliberate retry, so it
        // isn't held off by a page that failed before it.
        lastPageFailure = nil
        feed = makeFeed(sort: sort, reversed: reversed, filter: activeFilter)
        loadedDocs = []
        loadedEntityIDs = []
        guard let records = await nextRecords(generation: generation) else {
            if generation == refreshGeneration {
                (feed, loadedDocs, loadedEntityIDs) = previous
            }
            return
        }
        guard generation == refreshGeneration else { return }
        // Applied even when empty: an order and filter the server has nothing for
        // is an empty tab, not a failed fetch.
        let docs = append(records: records, sort: sort, reversed: reversed)
        // Only once the list is on screen, and only for uploaders whose name
        // isn't already known: a rename is worth one pass a session, not one
        // call per uploader every time the sort order changes.
        await refreshUploaderNames(for: Set(docs.map(\.doc.userID)))
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
    /// skipped as it is paged. The `filter` narrowing is taken at its word — what
    /// it returns is the list.
    ///
    /// Reversed, those leftovers would belong at the *head* of the list instead:
    /// they have no events at all, so their tally is zero. Which exercises they
    /// are can only be told from the whole answer to the order's own query, so
    /// there is no topping one up a page at a time — and that order is therefore
    /// taken at its word, listing what the query returns and nothing else. It is
    /// the server's to get right (the query leaving out what it has no events for
    /// is a bug there, being fixed), and the tab shows whatever it hands back.
    /// (`hot` is never reversed, so its leftovers always go last, ranked the way
    /// that order would rank them.)
    private func makeFeed(sort: CommunitySort,
                          reversed: Bool,
                          filter: CommunityFilter?) -> Feed {
        // `filter` only means anything next to the id of the user whose likes are
        // being asked about — the same public id the PUBLIC_NAME document is
        // persisted under.
        let query = [URLQueryItem(name: "userId", value: PublicIdentifier.user)]
            + (filter.map { [URLQueryItem(name: "filter", value: $0.serverValue)] } ?? [])
        let ranked = FeedStage(sortBy: sort.serverSortBy,
                               sortDirection: sort.serverSortDirection(reversed: reversed))
        guard let topUp = sort.topUpSort, !reversed else {
            return Feed(sort: sort, reversed: reversed, query: query, stages: [ranked])
        }
        let leftovers = FeedStage(sortBy: topUp.serverSortBy,
                                  sortDirection: topUp.serverSortDirection(reversed: false))
        return Feed(sort: sort, reversed: reversed, query: query, stages: [ranked, leftovers])
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

    /// Fetches one page of one public storage type.
    ///
    /// The endpoint requires `sortBy`, `sortDirection`, `page` and `pageSize`;
    /// without them it answers 500. It also ignores the storage type in the path
    /// once those are present, handing back documents of every kind, so the
    /// records are filtered by `storageType` here — while whether this was the
    /// last page is judged on what the server actually returned.
    private static func fetchPage(storageType: String,
                                  sortBy: String,
                                  sortDirection: String,
                                  page: Int,
                                  extraQuery: [URLQueryItem]) async -> PageResult {
        var components = URLComponents(string: "\(baseURL)/fetch-public/\(storageType)")
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
                print("CommunitySync: fetch of \(storageType) page \(page) failed with status \(http.statusCode)")
                return .failed
            }
            guard let records = try? JSONDecoder().decode([PersistRecord].self, from: data) else { return .failed }
            // A short page is the last one.
            return .page(records: records.filter { $0.storageType == storageType },
                         isLast: records.count < pageSize)
        } catch {
            print("CommunitySync: fetch of \(storageType) page \(page) failed: \(error)")
            return .failed
        }
    }

    /// Walks every page of one query, for the caller that wants the whole answer
    /// rather than a page of it: the one-record PUBLIC_NAME lookups. nil if any
    /// page failed.
    private static func fetchAllRecords(storageType: String,
                                        sortBy: [String],
                                        sortDirection: String,
                                        extraQuery: [URLQueryItem] = []) async -> [PersistRecord]? {
        var sortKeys = sortBy
        var all: [PersistRecord] = []
        var page = 0
        while page < maxPages {
            guard let sortKey = sortKeys.first else { return nil }
            switch await fetchPage(storageType: storageType,
                                   sortBy: sortKey,
                                   sortDirection: sortDirection,
                                   page: page,
                                   extraQuery: extraQuery) {
            case .failed:
                return nil
            // A rejected sort key means this backend spells it the other way;
            // retry the same page with the next candidate.
            case .unknownSortKey:
                guard sortKeys.count > 1 else { return nil }
                sortKeys.removeFirst()
            case .page(let records, let isLast):
                all += records
                if isLast { return all }
                page += 1
            }
        }
        return all
    }

    // MARK: - Paging

    /// Loads the next page of the community list and appends it to what's on
    /// screen. Called by the tab as the user scrolls towards the end of the list;
    /// does nothing once the whole community is in hand, while another page is on
    /// the wire, or while a refresh — which takes the list back to its first page —
    /// is.
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
        let sort = feed.sort
        let reversed = feed.reversed
        let records = await nextRecords(generation: generation)
        // nil is a call that failed; the list is left as it is and the next look
        // at it — once the pause above is up — tries again.
        lastPageFailure = records == nil ? Date() : nil
        guard let records, !records.isEmpty, generation == refreshGeneration else { return }
        let docs = append(records: records, sort: sort, reversed: reversed)
        await refreshUploaderNames(for: Set(docs.map(\.doc.userID)))
    }

    /// Loads the page the list asked for while a fetch was already on the wire —
    /// a refresh, or the page before it — now that one is done.
    private func loadPendingPage() {
        guard wantsAnotherPage else { return }
        wantsAnotherPage = false
        Task { await loadNextPage() }
    }

    /// Puts a page's records into the list, after the ones already loaded, and
    /// publishes the result. Returns the documents this page decoded to, for the
    /// uploader-name pass.
    private func append(records: [PersistRecord],
                        sort: CommunitySort,
                        reversed: Bool) -> [FetchedDoc] {
        let docs = decodeDocs(from: records)
        loadedDocs += docs
        apply(docs: loadedDocs, sort: sort, reversed: reversed)
        return docs
    }

    /// Something on screen that shows more of the community than the list has
    /// been scrolled to, and so needs the whole thing loaded.
    enum FullListNeed {
        /// The search field: it looks through every exercise's name and
        /// description, and lists the uploaders it finds.
        case search
        /// An uploader's profile: their exercises can be anywhere in the list.
        case profile
    }

    /// Says whether a screen needing the whole community is up. While one is, the
    /// feed reads itself to the end in the background instead of waiting to be
    /// scrolled, so those screens see what they saw when every exercise was
    /// fetched before the tab drew anything.
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

    /// Brings the uploader names up to date and relabels the list with them.
    ///
    /// A username changes only when its owner renames themselves, so the whole
    /// set is looked up once a session and cached (and persisted) from then on;
    /// later refreshes ask only about uploaders never seen before, which is
    /// usually none at all. That matters because there is one document per
    /// uploader and so one call per uploader: doing it on every refresh put a
    /// wave of them — six at a time, as many waves as it took — between picking a
    /// sort order and seeing it.
    private func refreshUploaderNames(for userIDs: Set<String>) async {
        let wanted = hasRefreshedNames ? userIDs.subtracting(uploaderNames.keys) : userIDs
        // Set before the fetch, not after: it makes the two refreshes that race
        // at launch (start(with:) and the tab appearing) share one pass, and a
        // name that fails to load simply stays unknown and is asked for again by
        // the next refresh.
        hasRefreshedNames = true
        guard !wanted.isEmpty else { return }
        let fetched = await Self.fetchPublicNames(for: wanted)
        guard !fetched.isEmpty else { return }
        remember(names: fetched)
    }

    /// Caches usernames and puts them on the rows they belong to. Applied to
    /// whatever the list holds now, however many refreshes later: a name belongs
    /// to an uploader, not to the order their exercises are in.
    private func remember(names: [String: String]) {
        // An empty username is no username: the row keeps the name stamped on the
        // exercise at publish time, the same as when the fetch can't find one.
        let names = names.filter { !$0.value.isEmpty }
        guard !names.isEmpty else { return }
        uploaderNames.merge(names) { _, new in new }
        UserDefaults.standard.set(uploaderNames, forKey: Self.uploaderNamesKey)
        var relabelled = exercises
        var changed = false
        for index in relabelled.indices {
            guard let userID = uploaderIDs[relabelled[index].id],
                  let name = uploaderNames[userID],
                  relabelled[index].uploaderName != name
            else { continue }
            relabelled[index].uploaderName = name
            changed = true
        }
        if changed { exercises = relabelled }
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
                    guard let record = await fetchAllRecords(
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

    /// Fetches the server's like/download/play tally for one exercise, or nil if
    /// the call fails — in which case the caller keeps the counts it has.
    private static func fetchEventSummary(for id: UUID) async -> EventSummary? {
        guard let url = URL(string: "\(baseURL)/event-summary/\(id.uuidString.lowercased())"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let summary = try? JSONDecoder().decode(EventSummary.self, from: data)
        else { return nil }
        return summary
    }

    /// A fetched document together with the hash of the JSON it came from, which
    /// tells `apply` whether this session has already cached its pattern.
    private struct FetchedDoc {
        var doc: SharedExerciseDoc
        var source: Int
    }

    /// One document per record; tombstones and documents that fail to decode
    /// (e.g. the pre-split whole-library documents, or ones written by a newer
    /// app version) are skipped.
    ///
    /// Records whose JSON is byte for byte what this session already decoded come
    /// straight out of `decodedDocs` — which, on a sort switch, is every one of
    /// them: the same documents came back, only in a different order, and
    /// decoding a whole community's patterns again (on the main actor, since this
    /// class is @MainActor) is time spent producing what is already in hand.
    private func decodeDocs(from records: [PersistRecord]) -> [FetchedDoc] {
        let decoder = JSONDecoder()
        var docs: [FetchedDoc] = []
        docs.reserveCapacity(records.count)
        for record in records {
            let source = record.jsonData.hashValue
            if let cached = decodedDocs[record.entityId], cached.source == source {
                docs.append(FetchedDoc(doc: cached.doc, source: source))
                continue
            }
            guard let doc = try? decoder.decode(SharedExerciseDoc.self,
                                                from: Data(record.jsonData.utf8))
            else { continue }
            decodedDocs[record.entityId] = (source, doc)
            docs.append(FetchedDoc(doc: doc, source: source))
        }
        return docs
    }

    /// Publishes the exercises loaded so far — relabelled with each uploader's
    /// current PUBLIC_NAME where one is known — and swaps their patterns into the
    /// UserDefaults cache. `sort` and `reversed` are what the fetch behind them
    /// asked the server for, remembered alongside the list so
    /// `sorted(_:by:reversed:)` knows what order it is in.
    ///
    /// `docs` is the whole list, not the page that has just arrived: the pattern
    /// cache and the counts are keyed off what the tab holds, and re-applying a
    /// page already applied costs nothing (see `cachedPatternSources`).
    ///
    /// Everything that means "no longer in the community" — dropping a cached
    /// pattern, a count, a decoded document — waits until the whole list has been
    /// read. Until then an exercise missing from it is one the user simply hasn't
    /// scrolled to yet, and throwing its pattern away would only mean fetching it
    /// again a page later.
    private func apply(docs: [FetchedDoc],
                       sort: CommunitySort,
                       reversed: Bool) {
        let isComplete = feed?.isExhausted ?? false
        let defaults = UserDefaults.standard
        var seenExercises = Set<UUID>()
        var fetched: [Exercise] = []
        var cachedIDs: [String] = []
        var uploaders: [UUID: String] = [:]
        var likes: [UUID: Int] = [:]
        var downloads: [UUID: Int] = [:]
        var plays: [UUID: Int] = [:]
        var dates: [UUID: Date] = [:]
        for fetchedDoc in docs {
            let doc = fetchedDoc.doc
            guard var exercise = doc.exercise, exercise.visibility == .public,
                  seenExercises.insert(exercise.id).inserted else { continue }
            if let name = uploaderNames[doc.userID] { exercise.uploaderName = name }
            uploaders[exercise.id] = doc.userID
            fetched.append(exercise)
            // Counts come from opening an exercise, not from listing it: carry
            // over what is known and leave the rest to `refreshSummary(for:)`.
            // Rebuilding the dictionaries — once the whole list is in — is what
            // drops the counts of exercises that have left the community.
            if let count = likeCounts[exercise.id] { likes[exercise.id] = count }
            if let count = downloadCounts[exercise.id] { downloads[exercise.id] = count }
            if let count = playCounts[exercise.id] { plays[exercise.id] = count }
            if let createdAt = doc.createdAt {
                dates[exercise.id] = Date(timeIntervalSince1970: createdAt)
            }
            // Every fetched exercise carries its public id, a namespace distinct
            // from any local raw id, so caching the server pattern here can never
            // clobber a local one — even for this device's own uploads.
            cachedIDs.append(exercise.id.uuidString)
            // The pattern already in UserDefaults was written from this very
            // JSON, so re-encoding it would write back what is already there.
            // Skipping that is what keeps a sort switch — where every document
            // comes back unchanged — from re-encoding the whole community.
            guard cachedPatternSources[exercise.id] != fetchedDoc.source else { continue }
            if let data = try? JSONEncoder().encode(doc.midi) {
                defaults.set(data, forKey: ExerciseStore.midiKey(exercise.id))
            }
            if let texts = doc.texts, let data = try? JSONEncoder().encode(texts) {
                defaults.set(data, forKey: ExerciseStore.midiTextKey(exercise.id))
            } else {
                defaults.removeObject(forKey: ExerciseStore.midiTextKey(exercise.id))
            }
            cachedPatternSources[exercise.id] = fetchedDoc.source
        }
        let cached = Set(defaults.stringArray(forKey: Self.cachedPatternIDsKey) ?? [])
        if isComplete {
            for idString in cached.subtracting(cachedIDs) {
                guard let id = UUID(uuidString: idString) else { continue }
                defaults.removeObject(forKey: ExerciseStore.midiKey(id))
                defaults.removeObject(forKey: ExerciseStore.midiTextKey(id))
                // The pattern is gone, so the next fetch that lists this exercise
                // again has to write it back even if the document hasn't changed.
                cachedPatternSources.removeValue(forKey: id)
            }
            defaults.set(cachedIDs, forKey: Self.cachedPatternIDsKey)
            decodedDocs = decodedDocs.filter { loadedEntityIDs.contains($0.key) }
        } else {
            defaults.set(cached.union(cachedIDs).sorted(), forKey: Self.cachedPatternIDsKey)
        }
        exercises = fetched
        uploaderIDs = uploaders
        fetchedSort = sort
        fetchedReversed = reversed
        if isComplete {
            likeCounts = likes
            downloadCounts = downloads
            playCounts = plays
        }
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
    /// The server-only orders (see `isServerOrdered`) are instead kept as the
    /// fetch returned them — a subset of a sorted list is still sorted, so the
    /// searches and profiles come out right without the app knowing what the
    /// server ranked on. `reversed` is already in that order too, having been
    /// fetched as `sortDirection`, so it's applied to every *other* order only.
    ///
    /// Which is also why picking one of those shows the list in the order it is
    /// already in until the refetch lands: their ranking isn't in what came
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
            case .hot, .recentlyUpdated, .mostLiked, .mostPlayed, .mostDownloaded:
                let (x, y) = (fetchedRank[a.id] ?? .max, fetchedRank[b.id] ?? .max)
                return x == y ? byName(a, b) : x < y
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
