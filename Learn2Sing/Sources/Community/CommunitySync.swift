//
//  CommunitySync.swift
//  Learn2Sing
//

import Foundation
import Combine

/// The document persisted per public exercise, under the exercise's own ID:
/// the exercise together with its MIDI pattern and text labels. An exercise made
/// private or deleted now has its record deleted outright (see
/// `deleteSharedExercise`), so nothing writes an `exercise` of nil any more —
/// but the tombstones older versions left in place of a delete are still on the
/// server, and are still what a nil `exercise` means when one is fetched.
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

/// The document each user keeps on the server under PUBLIC_PROFILE (called
/// PUBLIC_NAME until the backend renamed it): everything they publish about
/// themselves — their username, the description they wrote on the profile
/// screen, and their join date if they made it public.
///
/// The username is posted as the document's `customName` as well as in its JSON,
/// and the server resolves the `customId1` stamped on each shared exercise — the
/// uploader's public user id — to that name, handing it back as `customName1` on
/// every SHARED_EXERCISE record (see `PersistRecord`). So the names arrive with
/// the list itself rather than costing a call per uploader. The description and
/// join date come the other way: nothing carries them, so an uploader's profile
/// screen fetches this document by id when it opens (see `publicProfile(for:)`).
nonisolated struct PublicProfileDoc: Codable {
    /// The uploader's public user id (see PublicIdentifier), matching the
    /// `userID` stamped on their shared exercises.
    var userID: String
    var username: String
    /// The description as typed on the profile screen, "" when it was cleared.
    /// Optional so the documents written before this field existed — every one
    /// on the server today — still decode; a synthesised `init(from:)` throws on
    /// a missing key rather than falling back to a property's default value.
    var description: String? = nil
    /// When the user joined, as seconds since 1970 — nil unless they made it
    /// public, in which case it is left out of the document rather than put in
    /// and hidden.
    var joinedAt: Double? = nil
    /// This user's profile picture, as two Base64 AVIF renditions — the round one
    /// the circle draws and the whole one a tap on it opens. Optional both
    /// because most documents on the server predate it and because plenty of
    /// users won't have set one.
    var picture: ProfilePictureDoc? = nil
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
    /// The name is spoken for by *another* user. The name is the one the server
    /// named in its error, falling back to the one that was posted.
    ///
    /// The uniqueness check exempts the record that already holds the name, so
    /// re-posting a user's own name is accepted rather than refused, and this
    /// answer means what it says.
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
    /// No longer posted: an unlike deletes the like instead of offsetting it
    /// (see `deleteLike(for:)`). Kept because the rows older versions posted are
    /// still on the server, and deleting them is how they are cleared.
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
/// included). The orders that rank on these counts are the server's to work out.
nonisolated struct EventSummary: Decodable {
    var totalLikes: Int
    var totalDownloads: Int
    var totalPlays: Int
}

/// The server's average of one numeric event value for a single exercise, from
/// the `event-average` endpoint.
///
/// `EXERCISE_DIFFICULTY` is the only kind it answers for — the other event types
/// carry no value to average and come back as a 400. The number is worked out on
/// the server from the scores every user's finished runs post with `ADD_PLAY`
/// (see `registerPlay(for:score:)`), on the same 0-100 scale as a score, so it
/// says how *well* the exercise tends to go: 100 is the easiest. The intro
/// screen's stars show the other side of that — the higher this is, the fewer
/// of them fill.
///
/// An exercise nobody has finished yet answers `{}`, which decodes to a nil
/// `calculatedValue` — the intro screen leaves the stars off rather than drawing
/// an empty rating.
nonisolated struct EventAverage: Decodable {
    var calculatedValue: Double?
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
    /// The server's difficulty for each public exercise id — its average score,
    /// on the 0-100 scale `EventAverage` describes — as of the last time that
    /// exercise was opened. Persisted, so reopening one draws its stars on the
    /// first frame instead of after the round trip; the fetch still runs and
    /// moves them if the average has changed.
    @Published fileprivate(set) var difficulties: [UUID: Double] = [:]
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
/// PUBLIC_PROFILE document with its username, and the tab lists those exercise
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
    /// Storage type of the per-user public document (see `PublicProfileDoc`).
    /// It was called PUBLIC_NAME until the backend renamed it; the old name is
    /// now a 400, so a build asking for it can neither claim a name nor read a
    /// profile.
    nonisolated static let publicProfileType = "PUBLIC_PROFILE"
    /// Storage type of the per-exercise public document (see `SharedExerciseDoc`).
    nonisolated static let sharedExerciseType = "SHARED_EXERCISE"
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
    /// Last known difficulty per public exercise id, persisted so the intro
    /// screen's stars are up the moment it opens rather than a round trip later.
    private static let difficultiesKey = "communityDifficulties"
    /// How many difficulties are asked for at once. The endpoint answers for one
    /// exercise per call, so a whitelist — or a page of the community — costs a
    /// call apiece; a few in flight together get through them without the launch
    /// turning into a burst of a hundred requests.
    private static let difficultyFetchWidth = 4
    /// Share date (seconds since 1970) per public exercise id, so re-uploading an
    /// edited exercise keeps the date it was first shared.
    private static let shareDatesKey = "communityShareDates"
    /// Raw ids of the exercises whose difficulty this device has already
    /// estimated and posted. Persisted because the estimate is one per exercise
    /// for good (see `seedDifficulty(for:)`) — rewritten when an edit moves it,
    /// never posted a second time alongside the first — so the record has to
    /// outlive the launch that made it.
    private static let seededDifficultyIDsKey = "communitySeededDifficulties"
    /// Raw exercise id to the estimate its rows on the server carry, which is
    /// what an edit is measured against: the same score again is an edit that
    /// left the difficulty alone and is not worth a round trip. An id estimated
    /// before this was recorded has no entry, and the first edit to it rewrites
    /// its rows whether or not it needed to.
    private static let seededDifficultyScoresKey = "communitySeededDifficultyScores"
    /// Raw exercise id to the seeded score still owed to the server, for the
    /// exercises made while it couldn't be reached. Retried at the next launch.
    private static let pendingDifficultySeedsKey = "communityPendingDifficultySeeds"
    /// The users a seeded difficulty is posted as.
    ///
    /// Always these three, on every device: the server holds one row per user,
    /// exercise and event type, so a value posted from a fixed id lands in the
    /// same row rather than stacking another one up — which is what keeps the
    /// estimate a single opinion however many times it is posted.
    ///
    /// Three of them rather than one so the estimate holds its ground for a
    /// while: the first real score to arrive is one voice in four instead of one
    /// in two, and by the time a handful of singers have been through the
    /// exercise they outweigh it, which is the point at which it should stop
    /// counting for much.
    ///
    /// They are the only ids the app sends that aren't derived from a real
    /// install (see PublicIdentifier), and they are deliberately unmistakable:
    /// nothing else can collide with them, and anyone reading the event rows can
    /// see at a glance which scores were sung and which were estimated.
    ///
    /// The run starts at 2 rather than 1, which is not tidiness to be corrected:
    /// the backend silently drops everything posted from the all-ones id. It
    /// answers the POST 200 like any other and the row simply never reaches
    /// `event-average` — measured 2026-09-06 on throwaway exercise ids, both as
    /// the only post on an exercise (the average stayed `{}`) and against a
    /// settled one (a value that should have moved it left it alone, where the
    /// same post from an ordinary id moved it at once). While it was in this
    /// list the seed carried two voices and this comment claimed three. If the
    /// server ever stops filtering it, it can come back — but prove that with an
    /// average that moves, since the status code says nothing either way.
    private static let seedUserIDs = [
        "22222222-2222-2222-2222-222222222222",
        "33333333-3333-3333-3333-333333333333",
        "44444444-4444-4444-4444-444444444444",
    ]
    /// The most a public profile document may weigh. The backend keeps each
    /// document in a TEXT column and answers 500 to anything much over 64KB, so
    /// this leaves a margin rather than sitting on the edge.
    private static let maxProfileBytes = 60_000

    /// The whole community, as the Community tab lists it. Its own object, like
    /// the per-uploader lists `profileFeed(for:)` hands out — see CommunityFeed.
    let list = CommunityFeed()
    /// Every exercise any feed has fetched this session, by public id. The lists
    /// come and go (a profile is fetched on its own, a search narrows the tab to
    /// a slice of the community), but a screen pushed from one of them has to
    /// keep resolving its exercise after the list behind it has moved on — so
    /// what has been seen is remembered here for the session.
    private var fetchedExercises: [UUID: Exercise] = [:]
    /// Who uploaded each of those, by the same public exercise id — the exact
    /// answer the intro screen's "Created by" line needs, since the screen has
    /// the exercise in hand and the list it came from may be long gone. Kept
    /// beside the exercises rather than only on each feed, which is where the
    /// list rows read it from (see CommunityFeed.uploaderIDs).
    private var fetchedUploaderIDs: [UUID: String] = [:]
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
    private var difficulties: [UUID: Double] {
        get { counts.difficulties }
        set { counts.difficulties = newValue }
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

    /// Raw ids of the exercises this device has estimated a difficulty for, so
    /// none of them is ever estimated a second time on top of the first — see
    /// `seedDifficulty(for:)`.
    private var seededDifficultyIDs: Set<UUID> = []
    /// What each of those estimates says, by raw exercise id: the score the
    /// exercise's seed rows carry, so an edit can tell whether it changed the
    /// difficulty. Empty for ids seeded by a version that didn't record it.
    private var seededDifficultyScores: [UUID: Int] = [:]
    /// The seeded scores still owed to the server, by raw exercise id: filled
    /// when an estimate is made and emptied as the plays are posted, so one made
    /// offline goes up at the next launch instead of being lost.
    private var pendingDifficultySeeds: [UUID: Int] = [:]
    /// Whether `uploadDifficultySeeds` is on the wire, and whether it has been
    /// asked for again since it started. One pass at a time: every row is cleared
    /// and then written, and two passes interleaving those calls on the same
    /// exercise — an edit in the editor and another on the settings screen, a
    /// second or two apart — would have the server average both estimates into
    /// one row.
    private var isUploadingSeeds = false
    private var seedUploadRequested = false

    private weak var store: ExerciseStore?
    private var storeObservation: AnyCancellable?
    private let uploadTrigger = PassthroughSubject<Void, Never>()
    private var uploadDebounce: AnyCancellable?
    private var readyToUpload = false
    /// Body of the last accepted upload per exercise ID; identical re-encodes
    /// are skipped, so the store's frequent unrelated changes don't cause
    /// redundant POSTs.
    private var lastUploadedBodies: [String: Data] = [:]
    /// Same skip-if-unchanged guard for the PUBLIC_PROFILE document.
    private var lastUploadedProfile: Data?
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
        // PUBLIC_PROFILE fetch per uploader; they now come with the list.
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
        let stored = UserDefaults.standard.dictionary(forKey: Self.difficultiesKey) as? [String: Double] ?? [:]
        difficulties = stored.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) { result[id] = entry.value }
        }
        let dates = UserDefaults.standard.dictionary(forKey: Self.shareDatesKey) as? [String: Double] ?? [:]
        shareDates = dates.reduce(into: [:]) { result, entry in
            if let id = UUID(uuidString: entry.key) {
                result[id] = Date(timeIntervalSince1970: entry.value)
            }
        }
        let seeded = UserDefaults.standard.stringArray(forKey: Self.seededDifficultyIDsKey) ?? []
        seededDifficultyIDs = Set(seeded.compactMap(UUID.init(uuidString:)))
        seededDifficultyScores = Self.storedCounts(forKey: Self.seededDifficultyScoresKey)
        pendingDifficultySeeds = Self.storedCounts(forKey: Self.pendingDifficultySeedsKey)
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

        // The profile picture is the one published thing the private backup
        // doesn't carry — it is far too big for that document's budget — so a
        // reinstall takes it back off this user's own public profile. Waited on
        // before anything may upload: the public document goes up whole, so
        // posting one before the picture is back would overwrite it with nothing.
        // Costs nothing on the launches that already know (see `isResolved`).
        await ProfilePictureStore.shared.restoreIfNeeded()
        readyToUpload = true
        // One upload per launch so pattern edits (which bypass the store's
        // published properties) and changes made while offline catch up.
        scheduleUpload()
        // Alongside the list rather than after it: the Home tab's suggestions
        // are ranked on these, and it is the first tab the app opens on, while
        // the community list is a tab away.
        Task { await refreshRecommendationDifficulties() }
        // Estimates made while the server was out of reach. Nothing waits on
        // them either — the exercises they belong to already show their stars
        // from the cache.
        Task { await uploadDifficultySeeds() }
        await list.refresh()
    }

    /// Request an upload soon; safe to call from any change handler.
    func scheduleUpload() {
        guard readyToUpload else { return }
        uploadTrigger.send()
    }

    /// Holds every upload back until `resumeUploads()`, and drops whatever the
    /// debounce is sitting on.
    ///
    /// For the wipe in `DeleteEverything`: clearing the library and the settings
    /// is hundreds of changes, each of which asks for an upload, and the one that
    /// landed would republish the very records being deleted — or, worse, arrive
    /// after them. Rebuilding the pipeline rather than only lowering the flag is
    /// what throws away the request already in it, which would otherwise be
    /// delivered three seconds later to a resumed sync.
    func suspendUploads() {
        readyToUpload = false
        uploadDebounce?.cancel()
        uploadDebounce = uploadTrigger
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { Task { @MainActor in await CommunitySync.shared.upload() } }
    }

    /// Lets uploads through again. Only meaningful after `suspendUploads()` —
    /// before the first `start(with:)` there is nothing to resume, and this
    /// leaves it that way.
    func resumeUploads() {
        guard store != nil else { return }
        readyToUpload = true
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
    /// their profile — which is fetched by id. What a list row has to go on: it
    /// hands over the name it drew and nothing else.
    func uploaderID(named username: String, in feed: CommunityFeed) -> String? {
        guard !username.isEmpty else { return nil }
        for exercise in feed.exercises where exercise.uploaderName == username {
            if let id = feed.uploaderIDs[exercise.id] { return id }
        }
        return uploaderNames.first { $0.value == username }?.key
    }

    /// The public user id of whoever uploaded one exercise, from whichever list
    /// turned it up — what the screens pushed off a list ask, since they hold the
    /// exercise itself. Exact where the lookup by name above can only be a good
    /// guess: two uploaders are free to go by the same username.
    func uploaderID(of publicExerciseID: UUID) -> String? {
        fetchedUploaderIDs[publicExerciseID]
    }

    // MARK: - Upload

    /// Pushes both server documents: the shared exercises and the public
    /// profile. Each one is skipped when its body hasn't changed since the last
    /// accept.
    private func upload() async {
        await uploadSharedExercises()
        await uploadPublicProfile()
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
            if await deleteSharedExercise(publicExerciseID: PublicIdentifier.exerciseID(idString)) {
                lastUploadedBodies.removeValue(forKey: idString)
                onServer.remove(idString)
            }
        }
        defaults.set(onServer.sorted(), forKey: Self.uploadedExerciseIDsKey)
    }

    /// Takes one exercise off the server: the record itself and, with it, every
    /// like, download and play anyone ever posted against it.
    ///
    /// This is what an exercise made private or deleted goes through. It used to
    /// be an overwrite — a record with no exercise in it, which every client
    /// skips (see `decodeDocs`) but which stayed in the table and came down with
    /// every page fetched from then on. The row is now gone, and so is the reason
    /// for the tombstones; the decoding still skips them, since the ones older
    /// versions left behind are still up there.
    ///
    /// The tallies go with the record, so an exercise shared again starts from
    /// nothing: no likes, no downloads, and no community difficulty until
    /// somebody sings it. They are dropped here too rather than left to go stale
    /// — they counted a record that no longer exists. The cached difficulty is
    /// not: it is this device's own estimate of an exercise it still has (see
    /// `seedDifficulty(for:)`), and its stars have no business disappearing
    /// because it was made private.
    private func deleteSharedExercise(publicExerciseID: String) async -> Bool {
        guard await ServerDelete.storage(publicExerciseID, type: Self.sharedExerciseType)
        else { return false }
        guard let id = UUID(uuidString: publicExerciseID) else { return true }
        likeCounts.removeValue(forKey: id)
        downloadCounts.removeValue(forKey: id)
        playCounts.removeValue(forKey: id)
        persistCounts()
        if shareDates.removeValue(forKey: id) != nil { persistShareDates() }
        return true
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
        var components = URLComponents(
            string: "\(Self.baseURL)/persist/\(publicExerciseID)/\(Self.sharedExerciseType)")
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

    /// Re-posts this device's public profile, so a rename, a description edit or
    /// a new profile picture made while offline — or in a build that never got to
    /// post it — catches up. Skipped when the document hasn't changed since the
    /// last accepted post, so an unchanged profile costs nothing after the first
    /// upload of a session.
    ///
    /// The result is deliberately dropped: nothing on screen is waiting on it,
    /// and re-taking a name this user already holds is the ordinary case. A
    /// `.taken` here would mean somebody else has the name, which is a thing the
    /// profile screen reports when the rename is actually made.
    private func uploadPublicProfile() async {
        guard readyToUpload else { return }
        let username = UserProfile.load().username
        // Nothing to publish under. The persist endpoint keys this document on
        // the name and refuses an empty one, so a user who hasn't picked a
        // username yet has no public profile to post — and posting anyway would
        // be a guaranteed 412 on every launch. Their picture and description sit
        // on the device until the first name is accepted, which carries them up.
        guard !username.isEmpty else { return }
        await claimUsername(username)
    }

    /// POSTs this device's PUBLIC_PROFILE document — `username`, the profile
    /// description and, if the user made it public, the join date — and reports
    /// what the server made of the name. The name goes in the `customName` query
    /// parameter as well as in the document: that parameter is what the server
    /// resolves this user's id to on every shared exercise they have uploaded,
    /// and so what labels their rows in everyone's Community tab (see
    /// `PublicProfileDoc`).
    ///
    /// `customName` is unique across users, so this is also the only way to find
    /// out whether a name is free — hence the result, which the profile screen
    /// renames on (see `UsernameClaimResult`). Nothing is remembered locally for
    /// a post the server didn't take: `lastUploadedProfile` stays as it was, so
    /// the next upload asks again rather than assuming it went through.
    ///
    /// The uniqueness check exempts the record that already holds the name, so
    /// this is an ordinary write: re-posting a user's own document under their
    /// own unchanged name is accepted, and a 412 means the name belongs to
    /// somebody else. A `customName` is still required — posting with none is
    /// refused — which is why a user with no username yet publishes nothing.
    /// Every post carries the whole document, so a description edit or a new
    /// picture rides up with whichever post lands next.
    @discardableResult
    func claimUsername(_ username: String) async -> UsernameClaimResult {
        // The picture is part of this document and, on a fresh install, comes
        // back from the server rather than from the private backup. Publishing
        // before that has landed would post a document with no picture in it and
        // overwrite the one that is up there.
        guard ProfilePictureStore.shared.isResolved else { return .failed }
        let doc = Self.publicProfileDoc(username: username, in: UserProfile.load())
        guard let body = Self.encode(doc) else { return .failed }
        // The document the server last took is this one, name and all.
        guard body != lastUploadedProfile else { return .accepted }
        let result = await postPublicProfile(doc, body: body)
        if case .accepted = result { lastUploadedProfile = body }
        return result
    }

    /// The document this device publishes about its user: the name being claimed,
    /// plus everything else they have chosen to make public.
    ///
    /// The picture comes from `ProfilePictureStore` rather than from the profile
    /// file — it is far too big to keep in the file `ProfileSync` uploads, which
    /// spends most of its 60KB budget on the exercise library and pays for
    /// anything else out of the score histories.
    private static func publicProfileDoc(username: String,
                                         in stored: UserProfile) -> PublicProfileDoc {
        PublicProfileDoc(
            userID: PublicIdentifier.user,
            username: username,
            description: stored.profileDescription ?? "",
            joinedAt: stored.joinDatePublic == true ? stored.joinedAt : nil,
            picture: ProfilePictureStore.shared.document)
    }

    private static func encode(_ doc: PublicProfileDoc) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(doc)
    }

    /// POSTs one public profile document and reports what the server made of the
    /// name on it. The name goes in the `customName` query parameter as well as
    /// in the document itself: the parameter is what the server resolves this
    /// user's id to on every exercise they have shared, and the document is what
    /// a reader of the profile goes by.
    private func postPublicProfile(_ doc: PublicProfileDoc,
                                   body: Data) async -> UsernameClaimResult {
        let userID = PublicIdentifier.user
        // A document over the backend's TEXT-column ceiling answers 500, and one
        // oversized POST once took `fetch-private` down for every user until the
        // owner fixed the server. The picture is budgeted to keep well clear of
        // this (see `ProfilePictureCodec`), so this is a backstop that shouldn't
        // fire — but it is the kind of mistake worth being unable to make.
        guard body.count <= Self.maxProfileBytes else {
            print("CommunitySync: public profile of \(body.count) bytes not sent; over budget")
            return .failed
        }
        var components = URLComponents(string: "\(Self.baseURL)/persist/\(userID)/\(Self.publicProfileType)")
        components?.queryItems = [
            URLQueryItem(name: "customId1", value: userID),
            URLQueryItem(name: "customName", value: doc.username),
        ]
        guard let url = components?.url else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed }
            if (200...299).contains(http.statusCode) {
                // This device's own rename, straight into the names the list is
                // labelled from — otherwise the tab would keep showing the old
                // name on this user's own exercises until the next refresh
                // brought the records (and with them the names) back down.
                remember(ownName: doc.username, for: userID)
                return .accepted
            }
            if http.statusCode == 412 {
                return .taken(Self.rejectedName(in: data) ?? doc.username)
            }
            print("CommunitySync: public profile upload failed with status \(http.statusCode)")
        } catch {
            print("CommunitySync: public profile upload failed: \(error)")
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

    // MARK: - Delete

    /// Takes this user's public profile off the server: the username they
    /// claimed, the description they wrote and the picture they chose, which are
    /// all one record.
    ///
    /// The name goes back into circulation with it — the persist endpoint's
    /// uniqueness check has nothing left to refuse (see `claimUsername(_:)`), so
    /// somebody else can take it. Their exercises keep the name that was stamped
    /// on each record when it was shared; there is simply no profile behind it
    /// any more for a tap on it to open.
    ///
    /// `lastUploadedProfile` is cleared whatever the server says, so a failed
    /// delete can't leave this device believing the record it just tried to
    /// remove is still the one up there.
    @discardableResult
    func deletePublicProfile() async -> Bool {
        lastUploadedProfile = nil
        uploaderNames.removeValue(forKey: PublicIdentifier.user)
        return await ServerDelete.storage(PublicIdentifier.user, type: Self.publicProfileType)
    }

    /// Raw ids (uppercase UUID strings, as the store keys them) of the exercises
    /// this device has a live record on the server for. What "Delete Everything"
    /// takes down, and the list it holds on to while a wipe is still owed.
    var uploadedExerciseIDs: [String] {
        UserDefaults.standard.stringArray(forKey: Self.uploadedExerciseIDsKey) ?? []
    }

    /// Takes the named exercises off the server, each with the likes, downloads
    /// and plays that were counted against it, and answers with the ones the
    /// server wouldn't part with.
    ///
    /// Named rather than "every shared exercise" so that a wipe finished at a
    /// later launch deletes what was shared when the user asked for it, not
    /// whatever is shared by then: an exercise published in between is the user's
    /// own doing after the wipe, and deleting it would come as a surprise.
    ///
    /// The bookkeeping of what is on the server keeps whatever couldn't be
    /// deleted, so an ordinary upload has the same list to work from as before.
    /// The exercises themselves are untouched: they stay in the library, private;
    /// deleting them is the library's business, and the record is gone either way.
    @discardableResult
    func deleteSharedExercises(_ idStrings: [String]) async -> [String] {
        let defaults = UserDefaults.standard
        var onServer = Set(defaults.stringArray(forKey: Self.uploadedExerciseIDsKey) ?? [])
        var failed: [String] = []
        for idString in idStrings {
            if await deleteSharedExercise(publicExerciseID: PublicIdentifier.exerciseID(idString)) {
                lastUploadedBodies.removeValue(forKey: idString)
                onServer.remove(idString)
            } else {
                failed.append(idString)
            }
        }
        defaults.set(onServer.sorted(), forKey: Self.uploadedExerciseIDsKey)
        return failed
    }

    /// Deletes every event this user has posted anywhere — every like, every
    /// counted download and every score a finished run contributed to an
    /// exercise's difficulty — and forgets the local side of them.
    ///
    /// The tallies other people's events add up to are not this user's to
    /// remove, so the counts held here are dropped rather than zeroed: the next
    /// time an exercise is opened its summary comes back down and says what it
    /// is now.
    @discardableResult
    func deleteAllEvents() async -> Bool {
        let deleted = await ServerDelete.allEvents(of: PublicIdentifier.user)
        likedExerciseIDs = []
        downloadedExerciseIDs = []
        likeCounts = [:]
        downloadCounts = [:]
        playCounts = [:]
        persistCounts()
        saveProfileSets()
        return deleted
    }

    /// Forgets everything this device remembers about the community: the
    /// tallies, the difficulties, the share dates and the record of what has been
    /// uploaded and estimated. Local only — what is on the server is deleted by
    /// the calls above, and this is what stops the next upload from putting any
    /// of it back.
    func forgetLocalState() {
        likeCounts = [:]
        downloadCounts = [:]
        playCounts = [:]
        difficulties = [:]
        likedExerciseIDs = []
        downloadedExerciseIDs = []
        shareDates = [:]
        seededDifficultyIDs = []
        seededDifficultyScores = [:]
        pendingDifficultySeeds = [:]
        lastUploadedBodies = [:]
        lastUploadedProfile = nil
        uploaderNames = [:]
        persistCounts()
        persistDifficulties()
        persistShareDates()
        persistDifficultySeeds()
        UserDefaults.standard.removeObject(forKey: Self.uploadedExerciseIDsKey)
    }

    /// One uploader's published profile — their description and, if they made it
    /// public, their join date — for the screen that opens on their name. nil
    /// when they have published none, or when the call fails, and the screen
    /// simply shows what it has.
    ///
    /// `fetch-private` is the endpoint that answers for one id, which is what
    /// this needs; the paged `fetch-public` ignores both the id and the storage
    /// type in its path and hands back shared exercises (see `CommunityFeed`).
    /// Nothing private goes over it: the id is the derived public one, and the
    /// document holds only what its author chose to publish.
    func publicProfile(for userID: String) async -> PublicProfileDoc? {
        guard case .answered(let doc) = await fetchPublicProfile(for: userID) else { return nil }
        return doc
    }

    /// What asking the server for one user's published profile came to.
    ///
    /// A missing profile and a call that never got an answer are both "no
    /// profile" to a screen that only wants to draw one, which is what
    /// `publicProfile(for:)` hands back. They are not the same thing when the
    /// question is whether it is safe to publish over what is up there — an
    /// unanswered call must not be read as "there is nothing there" — so the
    /// difference is kept here.
    enum PublicProfileFetch {
        /// The server answered: this is what it holds, nil if it holds nothing.
        case answered(PublicProfileDoc?)
        /// No answer — offline, or any other status.
        case failed
    }

    func fetchPublicProfile(for userID: String) async -> PublicProfileFetch {
        guard let url = URL(string: "\(Self.baseURL)/fetch-private/\(userID)/\(Self.publicProfileType)")
        else { return .failed }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failed }
            guard (200...299).contains(http.statusCode) else {
                print("CommunitySync: profile fetch failed with status \(http.statusCode)")
                return .failed
            }
            guard let records = try? JSONDecoder().decode([PersistRecord].self, from: data)
            else { return .failed }
            // An id the server knows nothing about answers 200 with an empty
            // list; that is an answer, and it means there is no profile.
            guard let record = records.first(where: { $0.storageType == Self.publicProfileType })
            else { return .answered(nil) }
            return .answered(try? JSONDecoder().decode(PublicProfileDoc.self,
                                                       from: Data(record.jsonData.utf8)))
        } catch {
            print("CommunitySync: profile fetch failed: \(error)")
            return .failed
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

    /// Brings one exercise's difficulty up to date from the server, published on
    /// `counts` so the intro screen's stars follow it.
    ///
    /// The cached value stays up while this runs, which is the point of caching
    /// it: an exercise opened before shows its stars on the first frame and they
    /// only move if the server's average has shifted since. A call that fails,
    /// or one for an exercise nobody has finished, answers nil and leaves the
    /// cache alone — the same as `refreshSummary` above, and the reason an
    /// average is never dropped once known: the endpoint can't tell "no rating
    /// yet" apart from "couldn't ask", and blanking the stars every time the
    /// device is offline would be the worse of the two readings.
    func refreshDifficulty(for publicExerciseID: UUID) async {
        guard let value = await Self.fetchDifficulty(for: publicExerciseID),
              difficulties[publicExerciseID] != value else { return }
        difficulties[publicExerciseID] = value
        persistDifficulties()
        // The singer's level is worked out from these, and this exercise may be
        // one it counts.
        SkillLevelStore.shared.recompute()
    }

    /// Brings up to date the difficulties the Home tab's suggestions are ranked
    /// on: every whitelisted exercise, plus everything this device has a score
    /// for — between them the two the singer's skill level is worked out from
    /// (see SkillLevelStore).
    ///
    /// One call per exercise is all the endpoint offers (see `EventAverage`), so
    /// they go out `difficultyFetchWidth` at a time and the whole thing runs off
    /// to one side of the launch: nothing on screen waits for it, and what lands
    /// is persisted for the next launch to open with. The whitelist is the
    /// bundled exercises to begin with, so this is a couple of dozen calls once
    /// a launch — not the few hundred per refresh that ranking the whole
    /// Community list on the server's tallies would cost.
    func refreshRecommendationDifficulties() async {
        guard let store else { return }
        let scored = Set(ScoreHistory.all().keys.compactMap(UUID.init(uuidString:)))
        let wanted = store.exercises
            .filter { store.recommendationWhitelist.contains($0.id) || scored.contains($0.id) }
            .map { PublicIdentifier.exercise($0.id) }
        apply(fetched: await Self.fetchDifficulties(for: wanted))
        // Even when nothing moved: this is the first point in a launch at which
        // the whole picture is in, and the level and the hardness map are worked
        // out from all of it at once.
        SkillLevelStore.shared.recompute()
    }

    /// The same for a batch of community exercises, addressed by the public ids
    /// they are listed under: what the Home tab's "New for You" ranks the
    /// community's hottest exercises against the singer's level by (see
    /// NewForYouFeed). They land in the same cache as everything above, which is
    /// where the intro screen's stars read them from too.
    func refreshDifficulties(for publicExerciseIDs: [UUID]) async {
        guard !publicExerciseIDs.isEmpty else { return }
        // Only if something actually moved. Unlike the launch pass above this
        // runs against exercises the singer may never have sung, and recomputing
        // the level over an unchanged picture would only republish it.
        guard apply(fetched: await Self.fetchDifficulties(for: publicExerciseIDs)) else { return }
        SkillLevelStore.shared.recompute()
    }

    /// Puts fetched difficulties into the cache, persisting them if any of them
    /// moved, and says whether any did.
    @discardableResult
    private func apply(fetched: [UUID: Double]) -> Bool {
        var changed = false
        for (id, value) in fetched where difficulties[id] != value {
            difficulties[id] = value
            changed = true
        }
        if changed { persistDifficulties() }
        return changed
    }

    /// The server's difficulty for each of `ids`, `difficultyFetchWidth` calls at
    /// a time — one exercise apiece is all the endpoint offers — leaving out the
    /// ones it had no answer for. Off the main actor, so those calls genuinely
    /// overlap.
    private nonisolated static func fetchDifficulties(for ids: [UUID]) async -> [UUID: Double] {
        var wanted = ids.makeIterator()
        var fetched: [UUID: Double] = [:]
        await withTaskGroup(of: (UUID, Double?).self) { group in
            for _ in 0..<difficultyFetchWidth {
                guard let id = wanted.next() else { break }
                group.addTask { (id, await fetchDifficulty(for: id)) }
            }
            while let (id, value) = await group.next() {
                if let value { fetched[id] = value }
                if let next = wanted.next() {
                    group.addTask { (next, await fetchDifficulty(for: next)) }
                }
            }
        }
        return fetched
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
        let posted = liked
            ? await postEvent(.addLike, for: publicExerciseID)
            : await deleteLike(for: publicExerciseID)
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

    /// Takes this user's like off an exercise by deleting the event that made
    /// it, and reports whether the server took both calls.
    ///
    /// It used to post a REMOVE_LIKE, which is not a removal: the server counts
    /// events rather than keeping one row per user, so the like stayed and an
    /// opposing row was added beside it, and the pair only *summed* to nothing.
    /// A user who liked and unliked an exercise a few times left a row for every
    /// tap.
    ///
    /// The REMOVE_LIKE rows are deleted alongside the likes, and that pairing is
    /// the point of it: an older build's ADD/REMOVE pair on this exercise sums to
    /// nothing today, so deleting only the ADD would leave its REMOVE behind to
    /// count against everyone else's likes. Clearing both leaves this user with
    /// no events on the exercise at all, which is what "not liked" should mean
    /// however many times they changed their mind.
    private func deleteLike(for publicExerciseID: UUID) async -> Bool {
        let exerciseID = publicExerciseID.uuidString.lowercased()
        let userID = PublicIdentifier.user
        let likes = await ServerDelete.events(of: userID, on: exerciseID, type: .addLike)
        let removals = await ServerDelete.events(of: userID, on: exerciseID, type: .removeLike)
        return likes && removals
    }

    /// Deletes this user's finished runs of one exercise from the server: the
    /// ADD_PLAY events they posted, which carry the score each run earned and are
    /// what the exercise's community difficulty averages (see `EventAverage`).
    /// Called when their recorded scores are deleted, so a score forgotten here
    /// is forgotten there as well.
    ///
    /// Takes raw exercise ids, like the score history it goes with. Only this
    /// user's plays are touched: every other singer's scores stay in the average,
    /// and so does the estimate a new exercise was seeded with, which is posted
    /// under fixed ids of its own rather than under this user's (see
    /// `seedDifficulty(for:)`).
    ///
    /// A whole library's worth goes one after another in a single task rather
    /// than as a call apiece all at once: "Delete All Scores" can be hundreds of
    /// exercises, and nothing on screen is waiting for them.
    func deletePlayEvents(for exerciseIDs: [UUID]) {
        guard !exerciseIDs.isEmpty else { return }
        let publicIDs = exerciseIDs.map(PublicIdentifier.exercise)
        for id in publicIDs { playCounts.removeValue(forKey: id) }
        persistCounts()
        Task {
            let userID = PublicIdentifier.user
            for id in publicIDs {
                await ServerDelete.events(of: userID, on: id.uuidString.lowercased(),
                                          type: .addPlay)
            }
        }
    }

    /// One exercise's plays, for the row that deletes one exercise's scores.
    func deletePlayEvents(for exerciseID: UUID) {
        deletePlayEvents(for: [exerciseID])
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

    // MARK: - Estimated difficulty

    /// Gives a newly made exercise a difficulty of its own, worked out from its
    /// notes rather than waited for.
    ///
    /// The server's rating is the average of the scores everyone posts (see
    /// `EventAverage`), so until somebody sings an exercise all the way through
    /// it has none: no stars on its intro screen, and nothing for the Home tab's
    /// suggestions to place it by. `ExerciseDifficulty` reads one straight off
    /// the pattern instead, and this puts it in both places it has to be:
    ///
    /// * **Cached here**, so this device draws the stars immediately — including
    ///   offline, and including on the exercise its own maker never shares.
    /// * **Posted to the server**, as `seedUserIDs.count` plays scoring what a
    ///   singer of average ability would be expected to get on it, so that the
    ///   `event-average` call every device makes answers with the estimate
    ///   instead of `{}`. Real singers' scores land in the same average and pull
    ///   it towards what the exercise actually turns out to be, which is the
    ///   point: the estimate is a starting position, not a verdict.
    ///
    /// One estimate per exercise, kept in step with the exercise. Called again
    /// after an edit — leaving the MIDI editor, leaving the settings screen — it
    /// works the difficulty out afresh, and if the run now plays differently
    /// enough to be scored differently it takes the three rows it posted off the
    /// server and posts the new value in their place.
    ///
    /// Replaced rather than added to, which is the whole reason it can be done
    /// at all: the server keeps a running mean per user rather than a single
    /// value (a second play from the same id averages into the first), so posting
    /// over the old estimate would blend the two and leave the rating describing
    /// a pattern that is half gone. Deleting the rows first is what makes the
    /// value posted the value they hold — see ServerDelete, which is where this
    /// became possible.
    ///
    /// Real singers' scores are untouched by it. `delete-events` is scoped to one
    /// user, one exercise and one event type, so a correction takes down nothing
    /// but this app's own three estimate rows: the estimate keeps exactly the
    /// weight it always had in the average and only changes what it says. That is
    /// also why an average that real scores have already moved is no reason to
    /// leave a correction unmade — the alternative is three votes for a pattern
    /// the exercise no longer plays.
    ///
    /// An edit that leaves the estimate where it was posts nothing at all, so
    /// renaming an exercise or nudging a note within its beat costs no calls.
    ///
    /// Bundled exercises are left out. Their ids are the same on every install,
    /// so their ratings are shared by everyone who has the app, and a user who
    /// had edited their own copy of one would be posting their edit's difficulty
    /// as everybody's.
    ///
    /// An exercise the server had already rated when it was first seen here is
    /// never given a first estimate: real scores are the thing the estimate
    /// stands in for, and once they exist there is nothing to stand in for.
    ///
    /// An exercise with nothing to rate — every note taken out of it, or no
    /// tempo — keeps whatever it last posted. There is no estimate to correct it
    /// with, and an empty exercise is on its way somewhere rather than finished:
    /// the notes that come back are rated when they do.
    func seedDifficulty(for exerciseID: UUID) {
        guard let store,
              !ExerciseStore.bundledExerciseIDs.contains(exerciseID),
              let exercise = store.exercises.first(where: { $0.id == exerciseID }),
              let rating = ExerciseDifficulty.rating(for: exercise,
                                                     pattern: store.notes(for: exerciseID))
        else { return }
        let score = ExerciseDifficulty.expectedScore(forRating: rating)
        let publicExerciseID = PublicIdentifier.exercise(exerciseID)
        let estimated = seededDifficultyIDs.contains(exerciseID)
        // Estimated before: only an edit that moves the estimate is worth
        // posting. An estimate from a version that didn't record its score reads
        // as moved, so the first edit to one of those rewrites it either way.
        if estimated, seededDifficultyScores[exerciseID] == score { return }
        // Never estimated, and the server has a rating already.
        if !estimated, difficulties[publicExerciseID] != nil { return }

        let replaced = seededDifficultyScores[exerciseID].map(Double.init)
        seededDifficultyIDs.insert(exerciseID)
        seededDifficultyScores[exerciseID] = score
        pendingDifficultySeeds[exerciseID] = score
        persistDifficultySeeds()

        // The cache holds the server's side of the scale — what the exercise
        // tends to be scored — which is the estimate the other way round. A
        // correction writes it only while it still holds the estimate being
        // corrected: anything else in there is an average real scores have
        // moved, which the new estimate is one voice in rather than the whole of,
        // and the intro screen fetches that average when it opens (see
        // `refreshDifficulty(for:)`).
        let cached = difficulties[publicExerciseID]
        if cached == nil || cached == replaced {
            difficulties[publicExerciseID] = Double(score)
            persistDifficulties()
            SkillLevelStore.shared.recompute()
        }

        Task { await uploadDifficultySeeds() }
    }

    /// Posts the seeded scores that haven't reached the server yet, dropping
    /// each exercise from the pending list once all of its plays are in.
    ///
    /// An exercise made offline keeps its entry — and its local stars — until a
    /// launch that can post it, which is the other place this runs.
    ///
    /// Every row is deleted before it is written, whether or not there is
    /// anything there to delete. The server averages a play into the row it
    /// lands on rather than replacing it (see `seedDifficulty(for:)`), so
    /// clearing the row first is what makes the value posted the value it ends
    /// up holding — which is what an estimate corrected after an edit needs, and
    /// what lets a post that half landed be retried whole. A delete that matches
    /// nothing is answered 200 like any other and costs one round trip on a
    /// first estimate.
    private func uploadDifficultySeeds() async {
        // A pass already running goes round again once it is done, so whatever
        // was asked for meanwhile is posted after it rather than alongside it.
        seedUploadRequested = true
        guard !isUploadingSeeds else { return }
        isUploadingSeeds = true
        defer { isUploadingSeeds = false }
        while seedUploadRequested {
            seedUploadRequested = false
            for (exerciseID, score) in pendingDifficultySeeds {
                let publicExerciseID = PublicIdentifier.exercise(exerciseID)
                let entityID = publicExerciseID.uuidString.lowercased()
                var posted = true
                for userID in Self.seedUserIDs {
                    let cleared = await ServerDelete.events(of: userID, on: entityID, type: .addPlay)
                    let wrote = await postEvent(.addPlay, for: publicExerciseID,
                                                as: userID, customValue: score)
                    posted = posted && cleared && wrote
                }
                guard posted, pendingDifficultySeeds[exerciseID] == score else { continue }
                pendingDifficultySeeds.removeValue(forKey: exerciseID)
                persistDifficultySeeds()
            }
        }
    }

    /// Counts a finished run of an exercise, addressed by its public id, and
    /// posts the score it earned along with it.
    ///
    /// Called when a run plays through to its score screen — every replay counts
    /// again — and for every exercise, not only the ones opened from the
    /// Community tab: the difficulty the intro screen draws is the server's
    /// average of these scores, and the bundled exercises (whose ids are the same
    /// on every install) would never be rated if their runs didn't count. A run
    /// the singer walked out of never gets here, since it has no score to report.
    ///
    /// Unlike likes and downloads every play counts, so there is nothing to
    /// remember locally — bar a run that scored 0%. That is a silent or abandoned
    /// run rather than an attempt, which the score history leaves out for the same
    /// reason (see `ScoreHistory.record`), and posted it would pull the exercise's
    /// average — its difficulty — towards "nobody can sing this". It isn't counted
    /// as a play here either: the count mirrors the server's, which never hears of it.
    func registerPlay(for publicExerciseID: UUID, score: Int) {
        guard score > 0 else { return }
        playCounts[publicExerciseID] = (playCounts[publicExerciseID] ?? 0) + 1
        persistCounts()
        Task { await postEvent(.addPlay, for: publicExerciseID, customValue: score) }
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
    /// see PublicIdentifier for why. `as` overrides it, and only the seeded
    /// difficulty does that (see `seedDifficulty(for:)`).
    ///
    /// `customValue` is the number the event is worth: a play posts the score the
    /// run earned, which is what the server averages into the exercise's
    /// difficulty (see `EventAverage`). Likes and downloads have no such value
    /// and send none.
    @discardableResult
    private func postEvent(_ event: UserEventType, for publicExerciseID: UUID,
                           as userID: String = PublicIdentifier.user,
                           customValue: Int? = nil) async -> Bool {
        let exerciseID = publicExerciseID.uuidString.lowercased()
        var components = URLComponents(
            string: "\(Self.baseURL)/user-event/\(userID)/\(exerciseID)/\(event.rawValue)")
        if let customValue {
            components?.queryItems = [URLQueryItem(name: "customValue", value: String(customValue))]
        }
        guard let url = components?.url else { return false }
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

    private func persistDifficulties() {
        let stored = difficulties.reduce(into: [String: Double]()) { dict, entry in
            dict[entry.key.uuidString.lowercased()] = entry.value
        }
        UserDefaults.standard.set(stored, forKey: Self.difficultiesKey)
    }

    private func persistDifficultySeeds() {
        let defaults = UserDefaults.standard
        defaults.set(seededDifficultyIDs.map { $0.uuidString.lowercased() }.sorted(),
                     forKey: Self.seededDifficultyIDsKey)
        func store(_ scores: [UUID: Int], forKey key: String) {
            let stored = scores.reduce(into: [String: Int]()) { dict, entry in
                dict[entry.key.uuidString.lowercased()] = entry.value
            }
            defaults.set(stored, forKey: key)
        }
        store(seededDifficultyScores, forKey: Self.seededDifficultyScoresKey)
        store(pendingDifficultySeeds, forKey: Self.pendingDifficultySeedsKey)
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

    /// The server's difficulty for one exercise, addressed by its public id, or
    /// nil when it has no rating yet (nobody has finished it) or the call fails.
    /// What that nil means for the stars is `refreshDifficulty(for:)`'s business.
    ///
    /// Off the main actor, so the whitelist's worth of them can genuinely be
    /// asked for a few at a time — see `refreshRecommendationDifficulties`.
    private nonisolated static func fetchDifficulty(for publicExerciseID: UUID) async -> Double? {
        let id = publicExerciseID.uuidString.lowercased()
        guard let url = URL(string: "\(baseURL)/event-average/\(id)/EXERCISE_DIFFICULTY"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let average = try? JSONDecoder().decode(EventAverage.self, from: data)
        else { return nil }
        return average.calculatedValue
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
    /// relabelled with each uploader's current PUBLIC_PROFILE name where one is known —
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
            fetchedUploaderIDs[exercise.id] = doc.userID
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
