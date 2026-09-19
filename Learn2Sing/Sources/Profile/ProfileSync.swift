//
//  ProfileSync.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 11.07.26.
//

import Foundation
import Combine
import UIKit

/// Keeps the user's profile (username, description, device ID, the whole
/// Exercises tab and the settings) mirrored on the server as a single JSON
/// document, keyed by the private device ID. Because that ID lives in the
/// Keychain it survives reinstalls, so a fresh install can fetch the profile
/// back and restore the library.
///
/// When the document goes up depends on what changed. An edit — anything added,
/// removed or changed — goes up `editDelay` after the last of a burst of them. A
/// rearrangement — a drag in the Exercises tab, its categories, the favourites,
/// the routines — waits until the order has been left alone for `reorderDelay`,
/// since dragging twenty rows into place is twenty changes and only the last
/// arrangement is worth sending. An edit arriving while one waits goes up as
/// usual and takes the new order with it. Whatever is still waiting when the app
/// goes to the background is sent there and then.
///
/// None of it holds the main actor up. All the main actor does is take a
/// snapshot of the state (`ProfileSnapshot`); building the document, writing
/// profile.json and the request itself all happen off it, one upload at a time,
/// with a newer snapshot taking the place of one still waiting its turn — so a
/// slow request can never land after a newer one and overwrite it.
@MainActor
final class ProfileSync {
    static let shared = ProfileSync()

    nonisolated private static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
    /// Set once a restore attempt has reached the server. Lives in UserDefaults,
    /// which is wiped on reinstall — exactly when a restore should run again.
    private static let restoredKey = "didAttemptProfileRestore"
    /// Storage type of the private per-device backup this class owns.
    nonisolated private static let profileType = "PROFILE"

    /// Ceiling on the uploaded document. The backend takes 4 GB, far past
    /// anything this app could build, so this is no longer a server constraint
    /// but the app's own backstop against a runaway document: a run of score
    /// history costs about 15 bytes, so this sits above a lifetime of them while
    /// still keeping a single edit from turning into a huge POST.
    nonisolated private static let maxUploadBytes = 4_000_000

    /// How long after the last of a burst of edits the document goes up, so that
    /// a name typed out or a slider dragged is one upload rather than dozens.
    private static let editDelay = 3
    /// How long a rearrangement waits for the next one before it goes up. Each
    /// further rearrangement starts the wait over.
    private static let reorderDelay: Duration = .seconds(120)

    private weak var store: ExerciseStore?
    /// The live template store, so a restored profile's visual templates land in it
    /// rather than only in UserDefaults, which it read once at launch.
    private weak var visualTemplates: VisualTemplateStore?
    private var storeObservation: AnyCancellable?
    private var settingsObservation: AnyCancellable?
    /// Uploads are held back until the initial restore attempt has finished so a
    /// fresh install can't overwrite the server profile with the seeded library.
    private var readyToUpload = false
    private let uploadTrigger = PassthroughSubject<Void, Never>()
    private var uploadDebounce: AnyCancellable?
    /// Whether something asked for an upload that no snapshot has taken in yet —
    /// what going to the background checks before it sends anything.
    private var changedSinceSnapshot = false

    /// The document the server last accepted, so a change that leaves the profile
    /// looking exactly the same doesn't cost a request. Both the store and
    /// UserDefaults change for plenty of reasons the profile doesn't record.
    private var lastUploaded: PreparedProfile?
    /// Whether the last request failed, so that coming back to the foreground or
    /// going to the background tries it again.
    private var lastUploadFailed = false

    /// The newest snapshot waiting for `worker`. A newer one replaces it: only
    /// the latest state is worth sending.
    private var pending: Job?
    /// A snapshot to take as the server's copy without sending it — see
    /// `resumeUploads()`. Dealt with before `pending`.
    private var pendingAdoption: ProfileSnapshot?
    /// The one task working through the above, so that no two uploads ever run
    /// at once. nil while there is nothing to do.
    private var worker: Task<Void, Never>?

    /// A rearrangement waiting out `reorderDelay`, already built, and the timer
    /// that marks it due.
    private var heldReorder: PreparedProfile?
    private var heldReorderIsDue = false
    private var reorderTimer: Task<Void, Never>?

    /// Bumped by `suspendUploads()`. Work begun before it finds a different
    /// number when it comes back, and drops what it built rather than send it.
    private var generation = 0

    private init() {}

    /// Call once at launch: restores the profile on a fresh install, then keeps
    /// the server copy up to date as the profile, exercises or settings change.
    func start(with store: ExerciseStore, templates: VisualTemplateStore) async {
        guard self.store == nil else { return }
        self.store = store
        self.visualTemplates = templates

        uploadDebounce = makeDebounce()
        storeObservation = store.objectWillChange
            .sink { [weak self] _ in self?.scheduleUpload() }
        // The settings live in UserDefaults rather than on the store, and every
        // settings screen writes them straight through @AppStorage — so one
        // observer covers the lot of them, and the MIDI editor's patterns, the
        // scores and the practice calendar besides. It hears far more than the
        // profile holds, but a snapshot that would send an unchanged document is
        // dropped before it costs a request.
        settingsObservation = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .sink { _ in Task { @MainActor in ProfileSync.shared.scheduleUpload() } }

        await restoreIfNeeded()
        stampJoinDateIfNeeded()
        readyToUpload = true
        // One upload per launch so the server copy exists even before the first
        // edit and catches up on changes made while offline.
        scheduleUpload()
    }

    /// Records when this user joined, the first time the app runs without a date
    /// on file. It is stamped once and carried forward unchanged from then on:
    /// nothing older is recorded anywhere, so an install that predates the field
    /// counts as joining now. Run after the restore, so a profile fetched back
    /// brings its own date rather than being given today's.
    ///
    /// Whether the date is ever published is the profile screen's toggle to
    /// decide — see `CommunitySync.uploadPublicProfile`.
    private func stampJoinDateIfNeeded() {
        var profile = UserProfile.load()
        guard profile.joinedAt == nil else { return }
        profile.joinedAt = Date().timeIntervalSince1970
        profile.save()
    }

    /// Request an upload soon; safe to call from any change handler. Whether it
    /// goes up in `editDelay` or waits out `reorderDelay` is worked out from what
    /// actually changed, so the caller needn't say.
    func scheduleUpload() {
        guard readyToUpload else { return }
        changedSinceSnapshot = true
        uploadTrigger.send()
    }

    /// Coalesces bursts of changes into one snapshot. Replacing it drops whatever
    /// the old one was sitting on.
    private func makeDebounce() -> AnyCancellable {
        uploadTrigger
            .debounce(for: .seconds(Self.editDelay), scheduler: DispatchQueue.main)
            .sink { Task { @MainActor in ProfileSync.shared.takeSnapshot() } }
    }

    // MARK: - App lifecycle

    /// The app is on its way to the background, where it can be suspended or
    /// ended without another word. Whatever is still waiting — a burst of edits
    /// inside its few seconds, a rearrangement inside its two minutes, a request
    /// that failed — goes up now, under a background task so the request gets to
    /// finish.
    func appDidEnterBackground() {
        guard readyToUpload,
              changedSinceSnapshot || heldReorder != nil || lastUploadFailed
                || pending != nil || worker != nil
        else { return }
        let assertion = BackgroundAssertion(name: "Profile backup")
        takeSnapshot(urgent: true)
        let worker = self.worker
        Task {
            await worker?.value
            assertion.end()
        }
    }

    /// Back in the foreground. A request that failed, most likely offline, is
    /// tried again rather than left until the next change.
    func appDidBecomeActive() {
        guard lastUploadFailed else { return }
        scheduleUpload()
    }

    // MARK: - Suspend & resume

    /// Holds every upload back until `resumeUploads()`, and drops whatever is
    /// waiting to go up. See `CommunitySync.suspendUploads()`, which this
    /// matches; it matters more here, since this sync also listens to
    /// UserDefaults and so hears every last thing a wipe clears.
    func suspendUploads() {
        readyToUpload = false
        uploadDebounce?.cancel()
        uploadDebounce = makeDebounce()
        generation += 1
        pending = nil
        pendingAdoption = nil
        changedSinceSnapshot = false
        dropHeldReorder()
    }

    /// Lets uploads through again, with the profile as it stands taken as the one
    /// the server already has.
    ///
    /// That last part is what keeps "Delete Everything" deleted. Resuming with
    /// nothing remembered would have the next change — and after a wipe every
    /// last thing has just changed — post the emptied profile straight back into
    /// the record that was deleted a moment earlier, so the user would watch
    /// their backup reappear. Adopting the wiped document as the server's means
    /// nothing goes up until there is something new to say, and then it goes up
    /// as usual. The adoption is built by the worker like any upload, ahead of
    /// any snapshot that comes in after it.
    func resumeUploads() {
        guard let store else { return }
        pendingAdoption = ProfileSnapshot(store)
        readyToUpload = true
        startWorker()
    }

    // MARK: - Delete

    /// Deletes this device's profile backup from the server: the record under the
    /// Keychain device id that a reinstall restores the whole library, the
    /// scores, the routines and the settings from.
    ///
    /// Nothing else in the app takes it down, which is what makes it worth its
    /// own call — the restore is keyed on an id that outlives the app being
    /// deleted, so a user who wipes the app without this gets everything back on
    /// the next install (see `restoreIfNeeded`). The attempt flag is left set:
    /// this device has already asked, there is now nothing to ask for, and a
    /// relaunch should start empty rather than fetch the record again.
    ///
    /// An upload already on its way is let finish first, or it could land after
    /// the delete and put the record straight back. The caller has suspended
    /// uploads, so nothing new starts meanwhile.
    @discardableResult
    func deleteBackup() async -> Bool {
        lastUploaded = nil
        await worker?.value
        return await ServerDelete.storage(DeviceIdentifier.uuidString, type: Self.profileType)
    }

    // MARK: - Upload

    /// A snapshot on its way to the server.
    private struct Job {
        var snapshot: ProfileSnapshot
        /// Sent as soon as it is built, even if all it changes is the order: the
        /// app is going to the background and may not get another chance.
        var urgent: Bool
    }

    /// Takes a snapshot of the profile as it stands and hands it to the worker.
    /// The only part of an upload that runs on the main actor.
    private func takeSnapshot(urgent: Bool = false) {
        guard readyToUpload, let store else { return }
        changedSinceSnapshot = false
        // A background flush still waiting its turn stays urgent when a newer
        // snapshot takes its place.
        pending = Job(snapshot: ProfileSnapshot(store), urgent: urgent || pending?.urgent == true)
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task(priority: .utility) { await self.work() }
    }

    /// Works through whatever is waiting, one thing at a time, until nothing is.
    private func work() async {
        while true {
            if let snapshot = pendingAdoption {
                pendingAdoption = nil
                await adopt(snapshot)
            } else if let job = pending {
                pending = nil
                await process(job)
            } else if heldReorderIsDue, let held = heldReorder {
                dropHeldReorder()
                await upload(held)
            } else {
                break
            }
        }
        worker = nil
    }

    /// Builds the document from `job`'s snapshot and decides what it calls for:
    /// nothing, when the server already has it; the rearrangement wait, when all
    /// that differs from the server's copy is the order of things; an upload now
    /// for anything else.
    private func process(_ job: Job) async {
        let generation = self.generation
        guard let prepared = await Self.prepare(job.snapshot, writingFile: true),
              generation == self.generation
        else { return }
        if prepared.readStaleFile {
            // profile.json was written while this was being built, so the
            // username, likes and the rest it read from there may be out of
            // date. Built again, unless a newer snapshot is already waiting.
            if pending == nil { pending = job }
            return
        }
        // Nothing to say: the last document the server took is this one.
        if prepared.body == lastUploaded?.body {
            dropHeldReorder()
            return
        }
        if !job.urgent, let lastUploaded, prepared.content == lastUploaded.content {
            hold(prepared)
            return
        }
        // This carries whatever order the user has arrived at too.
        dropHeldReorder()
        await upload(prepared)
    }

    private func upload(_ prepared: PreparedProfile) async {
        let generation = self.generation
        let accepted = await Self.send(prepared)
        guard generation == self.generation else { return }
        lastUploadFailed = !accepted
        if accepted { lastUploaded = prepared }
    }

    /// Takes the document a snapshot builds into as the server's copy.
    private func adopt(_ snapshot: ProfileSnapshot) async {
        let generation = self.generation
        guard let prepared = await Self.prepare(snapshot, writingFile: false),
              generation == self.generation
        else { return }
        lastUploaded = prepared
        lastUploadFailed = false
    }

    /// Keeps a rearrangement back until the order has been left alone for
    /// `reorderDelay`. A different arrangement starts the wait over; the same one
    /// built again — something unrelated asked for an upload — leaves it running,
    /// or it could be put off for ever.
    private func hold(_ prepared: PreparedProfile) {
        guard prepared.body != heldReorder?.body else { return }
        heldReorder = prepared
        heldReorderIsDue = false
        reorderTimer?.cancel()
        reorderTimer = Task { [weak self] in
            // An explicit tolerance: left to the system, a sleep this long may
            // run over by a tenth of itself.
            try? await Task.sleep(for: Self.reorderDelay, tolerance: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.heldReorderIsDue = true
            self.startWorker()
        }
    }

    private func dropHeldReorder() {
        heldReorder = nil
        heldReorderIsDue = false
        reorderTimer?.cancel()
        reorderTimer = nil
    }

    // MARK: - Off the main actor

    /// A document built from a snapshot, ready to send.
    nonisolated private struct PreparedProfile: Sendable {
        /// What is POSTed — see `uploadBody(for:)`.
        var body: Data
        /// The document with every order the user arranges by hand taken out —
        /// see `arrangementFree(_:)`. Two documents with the same `content` and
        /// a different `body` differ in nothing but how things are arranged.
        var content: Data
        var deviceID: String
        /// Set when profile.json was written by someone else while this was being
        /// built, which left this copy unwritten and possibly out of date.
        var readStaleFile = false
    }

    /// Builds the full profile JSON (username + device ID + exercise library +
    /// the Home tab's routines and favourites + every exercise's scores + the
    /// practice calendar + the settings + the singer's skill level) out of a
    /// snapshot and what profile.json holds, and saves it locally. The costly
    /// part of an upload, so it never runs on the main actor.
    ///
    /// profile.json is written only if nothing else wrote it since it was read
    /// here: the profile screen and the Community tab edit its fields from the
    /// main actor meanwhile, and this copy must not land over theirs.
    @concurrent
    nonisolated private static func prepare(_ snapshot: ProfileSnapshot,
                                            writingFile: Bool) async -> PreparedProfile? {
        let (stored, writes) = UserProfile.loadCountingWrites()
        var profile = stored
        profile.fill(from: snapshot)
        let wrote = !writingFile || profile.save(unlessWrittenSince: writes)
        guard let body = uploadBody(for: profile),
              let content = arrangementFree(profile)
        else { return nil }
        return PreparedProfile(body: body, content: content, deviceID: profile.deviceID,
                               readStaleFile: !wrote)
    }

    /// POSTs the document; true when the server took it.
    @concurrent
    nonisolated private static func send(_ prepared: PreparedProfile) async -> Bool {
        // `customId1` is what `fetch-private` matches on, not the id in the path
        // (a server change around 2026-09-18), so a POST without it leaves
        // `restoreIfNeeded` reading back nothing. Every persist rewrites the
        // custom ids, so it has to ride along on each one.
        var components = URLComponents(string: "\(baseURL)/persist/\(prepared.deviceID)/\(profileType)")
        components?.queryItems = [URLQueryItem(name: "customId1", value: prepared.deviceID)]
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = prepared.body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("ProfileSync: upload failed with status \(http.statusCode)")
                return false
            }
            return true
        } catch {
            print("ProfileSync: upload failed: \(error)")
            return false
        }
    }

    /// One recorded run together with the exercise it belongs to, so the trimming
    /// below can rank every exercise's runs against each other.
    nonisolated private struct DatedRun {
        let exerciseID: String
        let entry: ScoreEntry
    }

    /// The encoder both the body and the arrangement-free copy are written with.
    nonisolated private static func documentEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Sorted keys so an unchanged profile encodes byte for byte the same way
        // twice, which is what lets an unchanged one be recognised.
        encoder.outputFormatting = [.sortedKeys]
        // The library is most of this document and the ids of its notes and text
        // labels were most of the library — 36 characters apiece for something
        // no stored data refers to and a restore can mint again. Leaving them out
        // is worth thousands of runs of score history in the room it frees.
        encoder.userInfo[.omitPatternIDs] = true
        return encoder
    }

    /// The profile encoded for upload, in compact JSON — unlike the
    /// pretty-printed local file — with as much score history as fits.
    ///
    /// Everything else in the document is bounded by what a user can plausibly
    /// build by hand, but scores grow with every run, so they are what gives way
    /// if the document ever reaches `maxUploadBytes`: the newest runs are kept
    /// and older ones left out. Only the upload is trimmed — the device keeps the
    /// full history and the chart still draws it. Since that ceiling stopped
    /// tracking the server's, no realistic profile should reach it and every run
    /// ought to make the trip; the trimming stays as the backstop it now is. nil
    /// when even a score-less profile is too big to send, since an oversized POST
    /// is what once took the endpoint down for everyone.
    nonisolated private static func uploadBody(for profile: UserProfile) -> Data? {
        var profile = profile
        let encoder = documentEncoder()
        // Newest first, so trimming takes off the end.
        var runs = (profile.scores ?? [:])
            .flatMap { id, doc in doc.entries.map { DatedRun(exerciseID: id, entry: $0) } }
            .sorted { $0.entry.date > $1.entry.date }

        // What the document costs with no scores in it at all — the floor the
        // histories have to fit above.
        profile.scores = nil
        guard let base = try? encoder.encode(profile) else { return nil }
        let budget = maxUploadBytes - base.count
        guard budget > 0 else {
            print("ProfileSync: profile is \(base.count) bytes before its scores, too large to upload")
            return nil
        }

        while true {
            let kept = Dictionary(grouping: runs, by: \.exerciseID)
                .mapValues { ScoreHistoryDoc($0.map(\.entry)) }
            profile.scores = kept.isEmpty ? nil : kept
            guard let body = try? encoder.encode(profile) else { return nil }
            let cost = body.count - base.count
            if cost <= budget { return body }
            // Scale the run count back by what this pass's runs actually cost.
            // Measuring beats assuming a size per run: it lands within a few runs
            // of the budget however long the histories are, and dropping at least
            // one run per pass closes the rest from there.
            let fitting = runs.count * budget / cost
            runs.removeLast(runs.count - min(fitting, runs.count - 1))
        }
    }

    /// The profile encoded with everything the user arranges by hand put into a
    /// fixed order: the exercises (and which category each was dragged into),
    /// the categories, the favourites, the routines and the exercises within
    /// each. Two profiles that encode the same way here differ at most in how
    /// they are arranged — which is what decides between an upload now and the
    /// rearrangement wait.
    ///
    /// An exercise's category counts as arrangement because the Exercises tab
    /// moves exercises between categories by dragging them, and a drag is a drag
    /// whichever section it ends in. Categories themselves being added, renamed
    /// or deleted still show here, since the set of them changes.
    nonisolated private static func arrangementFree(_ profile: UserProfile) -> Data? {
        var profile = profile
        if var bundle = profile.exercises {
            bundle.exercises = bundle.exercises
                .map { exercise in
                    var placeless = exercise
                    placeless.category = ""
                    return placeless
                }
                .sorted { $0.id.uuidString < $1.id.uuidString }
            bundle.categories = bundle.categories?.sorted()
            profile.exercises = bundle
        }
        profile.favourites = profile.favourites?.sorted { $0.uuidString < $1.uuidString }
        profile.routines = profile.routines?
            .map { routine in
                var unordered = routine
                unordered.exerciseIDs.sort { $0.uuidString < $1.uuidString }
                return unordered
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return try? documentEncoder().encode(profile)
    }

    // MARK: - Restore

    /// On the first launch after an (re)install, fetches the profile stored under
    /// this device's private ID and merges it back in. A server error leaves the
    /// attempt flag unset so the next launch retries.
    private func restoreIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.restoredKey), let store else { return }
        guard let url = URL(string: "\(Self.baseURL)/fetch-private/\(DeviceIdentifier.uuidString)/\(Self.profileType)")
        else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200...299:
                // Nothing stored for this ID (an empty record list) just means a
                // genuinely new user; the attempt still counts.
                if let remote = Self.decodeProfile(from: data) {
                    apply(remote, to: store)
                }
                UserDefaults.standard.set(true, forKey: Self.restoredKey)
            case 404:
                UserDefaults.standard.set(true, forKey: Self.restoredKey)
            default:
                print("ProfileSync: restore failed with status \(http.statusCode)")
            }
        } catch {
            print("ProfileSync: restore failed: \(error)")
        }
    }

    /// A record as returned by the fetch endpoint: the stored document sits in
    /// `jsonData` as a JSON string.
    private struct PersistRecord: Decodable {
        var jsonData: String
    }

    /// The fetch endpoint answers with an array of records (empty when nothing
    /// is stored). Accept the bare document too, in case the format changes.
    private static func decodeProfile(from data: Data) -> UserProfile? {
        let decoder = JSONDecoder()
        if let records = try? decoder.decode([PersistRecord].self, from: data),
           let record = records.first {
            return try? decoder.decode(UserProfile.self, from: Data(record.jsonData.utf8))
        }
        return try? decoder.decode(UserProfile.self, from: data)
    }

    private func apply(_ remote: UserProfile, to store: ExerciseStore) {
        // The Home tab's category order and hidden categories are never brought
        // back, even from a profile written by a version that still carried
        // them: a reinstall starts the tab over (see HomeCategories).
        var profile = UserProfile.load()
        if profile.username.isEmpty {
            profile.username = remote.username
        }
        // The profile screen's own fields, kept if this device already has them:
        // a restore the server failed on is retried on a later launch, and what
        // the user wrote in between is theirs.
        if profile.profileDescription == nil {
            profile.profileDescription = remote.profileDescription
        }
        if profile.joinDatePublic == nil {
            profile.joinDatePublic = remote.joinDatePublic
        }
        if profile.joinedAt == nil {
            profile.joinedAt = remote.joinedAt
        }
        profile.exercises = remote.exercises
        // CommunitySync reads this back when it starts, right after the restore.
        profile.likedExercises = remote.likedExercises
        profile.save()
        // A block the server told this user about before the reinstall. After the
        // save above, since picking it up clears the profile the save wrote.
        if let blockedUntil = remote.blockedUntil {
            AccountBlock.shared.restore(until: blockedUntil)
        }
        // The users this user blocked, merged into any blocked since the install.
        // After the save above, which wrote a copy of the file read before it.
        BlockedUsers.shared.merge(remote.blockedUsers)
        if let bundle = remote.exercises {
            // Not stamped as just added: these are the exercises the profile
            // already had, and their dates come down with them.
            store.importBundle(bundle, recordsDates: false)
        }
        if let dates = remote.exerciseDates {
            ExerciseDates.merge(dates)
        }
        // The Home tab's own lists and the score chart's data. Merged rather than
        // replaced: a restore the server failed on is retried on a later launch,
        // and whatever the user set up in between should survive it.
        if let routines = remote.routines {
            store.mergeRoutines(routines)
        }
        if let favourites = remote.favourites {
            store.mergeFavourites(favourites)
        }
        if let finishedLessons = remote.finishedLessons {
            BookLessonProgress.shared.merge(finishedLessons)
        }
        if let scores = remote.scores {
            ScoreHistory.merge(scores.mapValues(\.entries))
        }
        if let practice = remote.practice {
            PracticeLog.merge(doc: practice)
        }
        // The level the restored scores add up to is worked out again as soon as
        // the difficulties have been fetched; until then this is what the Home
        // tab's suggestions are pitched at, rather than a beginner's.
        if let skillLevel = remote.skillLevel {
            SkillLevelStore.shared.adopt(restored: skillLevel)
        }
        // The settings, last: they are the one part that replaces rather than
        // merges — a setting has a single value, and the restored one is it. The
        // app's language isn't among them; it stays as this device has it.
        if let settings = remote.settings, let visualTemplates {
            settings.apply(store: store, templates: visualTemplates)
        }
    }
}

// MARK: - Snapshot

/// What the profile document is built from that lives with the main actor — the
/// Exercises tab, the Home tab's lists, the settings, the skill level and the
/// book lessons — taken as plain values so the document can be built somewhere
/// else. Kept cheap on purpose, since taking it is the one part of an upload
/// that runs on the main actor: what lives in UserDefaults alone — the MIDI
/// patterns and text labels, the scores, the practice calendar, the exercise
/// dates — is read where the document is built instead (see
/// `UserProfile.fill(from:)`). Read a moment later than the rest, it can only be
/// newer, and whatever changes after the snapshot asks for an upload of its own.
nonisolated struct ProfileSnapshot: Sendable {
    /// The library in list order, as `ExerciseStore.exportBundle` has it.
    var exercises: [Exercise]
    var categories: [String]
    var routines: [Routine]
    var favourites: [UUID]
    var settings: UserSettings
    var skillLevel: Double
    var finishedLessons: [String]

    @MainActor
    init(_ store: ExerciseStore) {
        let library = store.orderedLibrary()
        exercises = library.exercises
        categories = library.categories
        routines = store.routines
        favourites = store.favourites
        settings = UserSettings.capturingCurrent(store: store)
        skillLevel = SkillLevelStore.shared.level
        finishedLessons = BookLessonProgress.shared.finished
    }
}

nonisolated extension UserProfile {
    /// Fills in the parts of the profile that live outside the profile file: the
    /// exercise library, the Home tab's routines and favourites, every exercise's
    /// score history, the practice calendar, the settings, the singer's skill
    /// level, when each exercise was added and last edited, and the book lessons
    /// finished this round. Not the Home tab's category order or hidden
    /// categories: those stay on the device (see `HomeCategories`).
    ///
    /// Reads and decodes every pattern and every score, so it belongs off the
    /// main actor — the snapshot is what makes that possible.
    mutating func fill(from snapshot: ProfileSnapshot) {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        var midi: [String: [MIDINote]] = [:]
        var texts: [String: [MIDIText]] = [:]
        for exercise in snapshot.exercises {
            let key = exercise.id.uuidString
            // Read as `ExerciseStore.notes(for:)` and `texts(for:)` read them: a
            // pattern that is missing or won't decode is an empty one, and only
            // exercises with labels carry any.
            midi[key] = defaults.data(forKey: ExerciseStore.midiKey(exercise.id))
                .flatMap { try? decoder.decode([MIDINote].self, from: $0) } ?? []
            if let labels = defaults.data(forKey: ExerciseStore.midiTextKey(exercise.id))
                .flatMap({ try? decoder.decode([MIDIText].self, from: $0) }), !labels.isEmpty {
                texts[key] = labels
            }
        }
        exercises = ExerciseBundle(exercises: snapshot.exercises, categories: snapshot.categories,
                                   midi: midi, texts: texts.isEmpty ? nil : texts)
        routines = snapshot.routines
        favourites = snapshot.favourites
        let histories = ScoreHistory.all().mapValues(ScoreHistoryDoc.init)
        scores = histories.isEmpty ? nil : histories
        practice = PracticeLog.doc()
        settings = snapshot.settings
        skillLevel = snapshot.skillLevel
        finishedLessons = snapshot.finishedLessons.isEmpty ? nil : snapshot.finishedLessons
        // Only the library's own, so dates a restore brought for exercises that
        // aren't here don't travel on.
        let libraryIDs = Set(snapshot.exercises.map(\.id.uuidString))
        let dates = ExerciseDates.all().filter { libraryIDs.contains($0.key) }
        exerciseDates = dates.isEmpty ? nil : dates
    }
}

/// A background task held while an upload finishes, so iOS doesn't suspend the
/// app halfway through the request.
@MainActor
private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of time: iOS suspends the app either way, request or not.
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
