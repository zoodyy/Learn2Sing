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
/// your exercises for everyone.
///
/// It is never fetched. The username is posted as the document's `customName`
/// as well as in its JSON, and the server resolves the `customId1` stamped on
/// each shared exercise — the uploader's public user id — to that name, handing
/// it back as `customName1` on every SHARED_EXERCISE record (see
/// `PersistRecord`). So the names arrive with the list itself, and someone
/// else's rename shows up on the next refresh rather than costing a call per
/// uploader to find.
nonisolated struct PublicNameDoc: Codable {
    /// The uploader's public user id (see PublicIdentifier), matching the
    /// `userID` stamped on their shared exercises.
    var userID: String
    var username: String
}

/// What the server made of a posted username.
///
/// A public name belongs to one record: the persist endpoint refuses a
/// `customName` that already exists with a 412, naming it in the body as
/// `error.save.public.name.not.unique#<name>`. There is no separate "is this
/// name free" call, so posting the name *is* the check — which is why the
/// profile screen keeps a rename only once the server has taken it (see
/// `CommunitySync.claimUsername(_:)` and `ProfileView`).
enum UsernameClaimResult {
    /// The server took the name; it is this user's public name from now on.
    case accepted
    /// The name is spoken for. The name is the one the server named in its
    /// error, falling back to the one that was posted.
    ///
    /// It doesn't tell you *by whom*: re-posting the name a record already holds
    /// is refused just the same, so this is also the answer to "keep my name as
    /// it is". Only ask about a name the user is actually moving to — which is
    /// what makes this mean "somebody else has it" where the profile screen
    /// reads it.
    case taken(String)
    /// No answer to go on — offline, or any other status. Whether the name is
    /// free is unknown, so it isn't held against the user.
    case failed
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

    nonisolated static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
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

    /// The whole community, as the Community tab lists it. Its own object, like
    /// the per-uploader lists `profileFeed(for:)` hands out — see CommunityFeed.
    let list = CommunityFeed()
    /// Every exercise any feed has fetched this session, by public id. The lists
    /// come and go (a profile is fetched on its own, a search narrows the tab to
    /// a slice of the community), but a screen pushed from one of them has to
    /// keep resolving its exercise after the list behind it has moved on — so
    /// what has been seen is remembered here for the session.
    private var fetchedExercises: [UUID: Exercise] = [:]
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
    /// Each uploader's current username by public user id, as the fetched
    /// records carried it (see `CommunityFeed.publicNames(in:)`). In-session
    /// only: it is filled from the same call that fills the list, so there is
    /// nothing a relaunch could usefully remember, and this device's own rename
    /// is put in as it is uploaded.
    private var uploaderNames: [String: String] = [:]
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
        // And the uploader names under this one, back when finding them cost a
        // PUBLIC_NAME fetch per uploader; they now come with the list.
        UserDefaults.standard.removeObject(forKey: "communityUploaderNames")
        // "Oldest First" is now the reverse switch on top of "Newest First";
        // carry anyone left on it over rather than dropping them to the default.
        if UserDefaults.standard.string(forKey: CommunityFeed.sortKey) == "oldest" {
            UserDefaults.standard.set(CommunitySort.newest.rawValue, forKey: CommunityFeed.sortKey)
            UserDefaults.standard.set(true, forKey: CommunityFeed.reversedKey)
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
        await list.refresh()
    }

    /// Request an upload soon; safe to call from any change handler.
    func scheduleUpload() {
        guard readyToUpload else { return }
        uploadTrigger.send()
    }

    /// A list of one uploader's public exercises, scoped by their public user id
    /// — the `customId1` their records are persisted with. A fresh one per
    /// profile screen, so its own order, filter and search term start clean and
    /// nothing it does touches the Community tab behind it.
    func profileFeed(for uploaderID: String) -> CommunityFeed {
        CommunityFeed(uploaderID: uploaderID)
    }

    /// A community exercise by its public id, from whichever list turned it up.
    /// Used by the screens pushed off a list — the intro, playback and score
    /// screens — which outlive the list they were opened from: a refresh, a
    /// search or a filter can narrow it out from under them.
    func exercise(for publicExerciseID: UUID) -> Exercise? {
        fetchedExercises[publicExerciseID]
    }

    /// The public user id of whoever uploaded the exercises going by `username`
    /// in the lists loaded so far, so a tap on a row's uploader name can open
    /// their profile — which is fetched by id.
    func uploaderID(named username: String, in feed: CommunityFeed) -> String? {
        guard !username.isEmpty else { return nil }
        for exercise in feed.exercises where exercise.uploaderName == username {
            if let id = feed.uploaderIDs[exercise.id] { return id }
        }
        return uploaderNames.first { $0.value == username }?.key
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
                          exerciseName: exercise.name,
                          description: exercise.details) {
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
                          exerciseName: "",
                          description: "") {
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
    ///
    /// The name and description go in query parameters as well as in the document
    /// body: that is what the server indexes, and so what a fetch's `searchTerm`
    /// is matched against (see `makeFeed`).
    private func post(body: Data,
                      publicExerciseID: String,
                      userID: String,
                      exerciseName: String,
                      description: String) async -> Bool {
        var components = URLComponents(string: "\(Self.baseURL)/persist/\(publicExerciseID)/SHARED_EXERCISE")
        components?.queryItems = [
            URLQueryItem(name: "customId1", value: userID),
            URLQueryItem(name: "customName", value: exerciseName),
            URLQueryItem(name: "description", value: description),
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

    /// Re-posts the stored profile username, so a rename made while offline —
    /// or in a build that never got to post it — catches up.
    ///
    /// The result is deliberately dropped: the first post of a session is of a
    /// name the server usually holds already, and it refuses a name that exists
    /// whoever holds it — this user included (verified against this device's own
    /// record). So `.taken` here is the ordinary answer for "nothing to change",
    /// not something to report or act on.
    private func uploadPublicName() async {
        guard readyToUpload else { return }
        await claimUsername(UserProfile.load().username)
    }

    /// POSTs `username` as this device's PUBLIC_NAME document and reports what
    /// the server made of it. The name goes in the `customName` query parameter
    /// as well as in the document itself: that parameter is what the server
    /// resolves this user's id to on every shared exercise they have uploaded,
    /// and so what labels their rows in everyone's Community tab (see
    /// `PublicNameDoc`).
    ///
    /// `customName` is unique across users, so this is also the only way to find
    /// out whether a name is free — hence the result, which the profile screen
    /// renames on (see `UsernameClaimResult`). Nothing is remembered locally for
    /// a name the server didn't take: `lastUploadedName` stays as it was, so the
    /// next upload asks again rather than assuming the name went through.
    @discardableResult
    func claimUsername(_ username: String) async -> UsernameClaimResult {
        let userID = PublicIdentifier.user
        let doc = PublicNameDoc(userID: userID, username: username)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var components = URLComponents(string: "\(Self.baseURL)/persist/\(userID)/PUBLIC_NAME")
        components?.queryItems = [
            URLQueryItem(name: "customId1", value: userID),
            URLQueryItem(name: "customName", value: doc.username),
        ]
        guard let body = try? encoder.encode(doc), let url = components?.url else { return .failed }
        // The name the server last took is this one: it is already this user's.
        guard body != lastUploadedName else { return .accepted }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if (200...299).contains(http.statusCode) {
                lastUploadedName = body
                // This device's own rename, straight into the names the list is
                // labelled from — otherwise the tab would keep showing the old
                // name on this user's own exercises until the next refresh
                // brought the records (and with them the names) back down.
                remember(ownName: doc.username, for: userID)
                return .accepted
            }
            if http.statusCode == 412 {
                return .taken(Self.rejectedName(in: data) ?? username)
            }
            print("CommunitySync: name upload failed with status \(http.statusCode)")
        } catch {
            print("CommunitySync: name upload failed: \(error)")
        }
        return .failed
    }

    /// The name a 412 body names, out of the server's
    /// `error.save.public.name.not.unique#<name>` token — bare, or as a value
    /// inside a JSON error object. Only the part after the `#` is of any use to
    /// a reader; what precedes it is the server's own error code. nil when the
    /// body carries no such token, leaving the caller to fall back to the name
    /// it posted.
    private static func rejectedName(in data: Data) -> String? {
        guard let body = String(data: data, encoding: .utf8),
              let marker = body.range(of: "name.not.unique#")
        else { return nil }
        // Stop at whatever ends the token: the closing quote or brace of a JSON
        // error object, or the end of a bare one.
        let name = body[marker.upperBound...]
            .prefix { !"\"}\n".contains($0) }
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
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

    /// Holds on to the usernames a page of records carried, so `applyFetched`
    /// can label the rows with them. Every uploader's name arrives this way; the
    /// one exception is this device's own rename, see `remember(ownName:for:)`.
    func remember(fetchedNames names: [String: String]) {
        guard !names.isEmpty else { return }
        uploaderNames.merge(names) { _, new in new }
    }

    /// Puts this device's own rename straight onto the rows it labels, without
    /// waiting for a refetch to carry it back down. Applied to whatever the
    /// community list holds now, however many refreshes later: a name belongs to
    /// an uploader, not to the order their exercises are in.
    private func remember(ownName name: String, for userID: String) {
        // An empty username is no username: the row keeps the name stamped on the
        // exercise at publish time, the same as when the fetch can't find one.
        guard !name.isEmpty else { return }
        uploaderNames[userID] = name
        list.relabel(with: [userID: name])
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

    /// One document per record; tombstones and documents that fail to decode
    /// (e.g. the pre-split whole-library documents, or ones written by a newer
    /// app version) are skipped.
    ///
    /// Records whose JSON is byte for byte what this session already decoded come
    /// straight out of `decodedDocs` — which, on a sort switch, is every one of
    /// them: the same documents came back, only in a different order, and
    /// decoding a whole community's patterns again (on the main actor, since this
    /// class is @MainActor) is time spent producing what is already in hand.
    func decodeDocs(from records: [PersistRecord]) -> [FetchedDoc] {
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

    /// Turns the documents a feed has loaded into the exercises it lists —
    /// relabelled with each uploader's current PUBLIC_NAME where one is known —
    /// and swaps their patterns into the UserDefaults cache. Also everything
    /// about them that belongs to the session rather than to one list: the share
    /// dates, the tallies, and the exercises the pushed screens resolve through
    /// (see `exercise(for:)`).
    ///
    /// `docs` is the feed's whole list, not the page that has just arrived: the
    /// pattern cache and the counts are keyed off what it holds, and re-applying
    /// a page already applied costs nothing (see `cachedPatternSources`).
    ///
    /// Everything that means "no longer in the community" — dropping a cached
    /// pattern, a count, a decoded document — waits for `isComplete`: the whole
    /// community read to its last page with nothing narrowing it. Until then an
    /// exercise missing from the list is one the user simply hasn't scrolled to
    /// yet — or one this list was never asking about, since a profile, a filter
    /// and a search term each fetch a slice of the community rather than the
    /// whole of it — and throwing its pattern away would only mean fetching it
    /// again a page later.
    func applyFetched(docs: [FetchedDoc],
                      entityIDs: Set<String>,
                      isComplete: Bool) -> (exercises: [Exercise], uploaderIDs: [UUID: String]) {
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
            fetchedExercises[exercise.id] = exercise
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
            decodedDocs = decodedDocs.filter { entityIDs.contains($0.key) }
        } else {
            defaults.set(cached.union(cachedIDs).sorted(), forKey: Self.cachedPatternIDsKey)
        }
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
        return (fetched, uploaders)
    }
}
