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
struct SharedExerciseDoc: Codable {
    /// The uploader's public user id (see PublicIdentifier) — never the raw
    /// device id. `exercise.id` likewise carries the public exercise id.
    var userID: String
    var exercise: Exercise? = nil
    var midi: [MIDINote] = []
    var texts: [MIDIText]? = nil
    /// How many users have liked this exercise. The whole document is rewritten
    /// on every like — by whoever tapped the heart, not just the uploader — so
    /// the uploader must carry the last known count forward on its own uploads
    /// (see `likeCounts`). Optional so documents written before likes existed
    /// still decode; treat nil as zero.
    var likes: Int? = nil
    /// How many users have downloaded this exercise into their own library.
    /// Written by the downloader in the same rewrite-the-whole-document way as
    /// `likes`, and likewise carried forward by the uploader. Optional so
    /// documents written before downloads were counted still decode; treat nil
    /// as zero.
    var downloads: Int? = nil
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
struct PublicNameDoc: Codable {
    /// The uploader's public user id (see PublicIdentifier), matching the
    /// `userID` stamped on their shared exercises.
    var userID: String
    var username: String
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

    private static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
    /// UUID strings whose midi/miditext keys were written by a fetch, so a later
    /// fetch can clean up patterns of exercises that left the community list.
    private static let cachedPatternIDsKey = "communityPatternIDs"
    /// UUID strings of this device's exercises that have a live record on the
    /// server; persisted so exercises unshared or deleted while offline (or in
    /// a previous session) still get their tombstone on the next upload.
    private static let uploadedExerciseIDsKey = "communityUploadedExerciseIDs"
    /// Last known like count per public exercise id, persisted so a launch whose
    /// fetch fails doesn't upload this device's exercises with the count zeroed.
    private static let likeCountsKey = "communityLikeCounts"
    /// Same, for the download count.
    private static let downloadCountsKey = "communityDownloadCounts"
    /// Share date (seconds since 1970) per public exercise id, so re-uploading an
    /// edited exercise keeps the date it was first shared.
    private static let shareDatesKey = "communityShareDates"

    /// Every device's public exercises as last fetched, in the order the server
    /// returns them. Empty until the first fetch of the session succeeds.
    @Published private(set) var exercises: [Exercise] = []
    /// true while a fetch is on the wire; drives the tab's initial spinner.
    @Published private(set) var isFetching = false
    /// Like count per public exercise id, as of the last fetch plus this
    /// session's own likes.
    @Published private(set) var likeCounts: [UUID: Int] = [:]
    /// Download count per public exercise id, as of the last fetch plus this
    /// session's own downloads.
    @Published private(set) var downloadCounts: [UUID: Int] = [:]
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
    /// The documents behind `exercises`, by public exercise id. A like rewrites
    /// the whole document — including exercises this device doesn't own — so the
    /// fetched body has to be kept around to post back with a new count.
    private var fetchedDocs: [UUID: SharedExerciseDoc] = [:]
    /// Whether a fetch has succeeded since launch; gates stamping share dates.
    private var hasFetched = false

    private init() {
        // An earlier version persisted the fetched list under this key.
        UserDefaults.standard.removeObject(forKey: "communityExercises")
        likeCounts = Self.storedCounts(forKey: Self.likeCountsKey)
        downloadCounts = Self.storedCounts(forKey: Self.downloadCountsKey)
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
                                        // Likes and downloads are written into
                                        // this same document by other users, so
                                        // carry the last known counts forward
                                        // instead of resetting them on every
                                        // edit.
                                        likes: likeCounts[shared.id] ?? 0,
                                        downloads: downloadCounts[shared.id] ?? 0,
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

    // MARK: - Likes & downloads

    /// Adds or removes this user's like on a community exercise, addressed by
    /// its public id. The heart and count update immediately; the new count is
    /// written into the exercise's shared document on the server and the liked
    /// set into the profile JSON (which ProfileSync uploads).
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
        Task { await postCounts(for: publicExerciseID) }
    }

    /// Counts a download of a community exercise, addressed by its public id.
    /// Only the user's first download of a given exercise counts — the set of
    /// downloaded ids rides along in the profile JSON, so downloading the same
    /// exercise again, on this or a reinstalled device, doesn't inflate it.
    func registerDownload(for publicExerciseID: UUID) {
        guard downloadedExerciseIDs.insert(publicExerciseID).inserted else { return }
        downloadCounts[publicExerciseID] = (downloadCounts[publicExerciseID] ?? 0) + 1
        persistCounts()
        saveProfileSets()
        Task { await postCounts(for: publicExerciseID) }
    }

    /// Rewrites the exercise's shared document with the current like and download
    /// counts, leaving the rest of it exactly as fetched. The backend has no
    /// atomic increment, so two devices liking or downloading within the same
    /// fetch cycle can lose one of the two; the next fetch makes every device
    /// agree again on whatever landed.
    private func postCounts(for publicExerciseID: UUID) async {
        guard var doc = fetchedDocs[publicExerciseID] else { return }
        doc.likes = likeCounts[publicExerciseID] ?? 0
        doc.downloads = downloadCounts[publicExerciseID] ?? 0
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(doc) else { return }
        _ = await post(body: body,
                       publicExerciseID: publicExerciseID.uuidString.lowercased(),
                       userID: doc.userID,
                       exerciseName: doc.exercise?.name ?? "")
        fetchedDocs[publicExerciseID] = doc
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
    /// `jsonData` as a JSON string.
    private struct PersistRecord: Decodable {
        var jsonData: String
    }

    /// Reloads the community list from the server. Called at launch, whenever
    /// the Community tab appears, and on pull-to-refresh; a failure keeps the
    /// list from the last successful fetch of this session.
    func refresh() async {
        guard let url = URL(string: "\(Self.baseURL)/fetch-public/SHARED_EXERCISE") else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse {
                    print("CommunitySync: fetch failed with status \(http.statusCode)")
                }
                return
            }
            let docs = Self.decodeDocs(from: data)
            let names = await Self.fetchPublicNames(for: Set(docs.map(\.userID)))
            apply(docs: docs, names: names)
        } catch {
            print("CommunitySync: fetch failed: \(error)")
        }
    }

    /// Fetches every uploader's PUBLIC_NAME document in parallel and returns the
    /// non-empty usernames by public user id. Users whose fetch fails are simply
    /// absent, so their exercises keep the name stamped at publish time.
    private static func fetchPublicNames(for userIDs: Set<String>) async -> [String: String] {
        await withTaskGroup(of: (String, String)?.self) { group in
            for userID in userIDs {
                group.addTask {
                    guard let url = URL(string: "\(baseURL)/fetch-public/PUBLIC_NAME?customId1=\(userID)"),
                          let (data, response) = try? await URLSession.shared.data(from: url),
                          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode)
                    else { return nil }
                    let decoder = JSONDecoder()
                    // The endpoint keeps one latest record per id, so the first
                    // record is the current name.
                    guard let record = (try? decoder.decode([PersistRecord].self, from: data))?.first,
                          let doc = try? decoder.decode(PublicNameDoc.self, from: Data(record.jsonData.utf8)),
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

    /// The fetch endpoint answers with an array of records, one per exercise;
    /// tombstones and documents that fail to decode (e.g. the pre-split
    /// whole-library documents, or ones written by a newer app version) are
    /// skipped.
    private static func decodeDocs(from data: Data) -> [SharedExerciseDoc] {
        let decoder = JSONDecoder()
        guard let records = try? decoder.decode([PersistRecord].self, from: data) else { return [] }
        return records.compactMap {
            try? decoder.decode(SharedExerciseDoc.self, from: Data($0.jsonData.utf8))
        }
    }

    /// Publishes the fetched exercises — relabelled with each uploader's current
    /// PUBLIC_NAME where one was fetched — and swaps their patterns into the
    /// UserDefaults cache, dropping patterns of exercises no longer shared.
    private func apply(docs: [SharedExerciseDoc], names: [String: String]) {
        let defaults = UserDefaults.standard
        var seenExercises = Set<UUID>()
        var fetched: [Exercise] = []
        var cachedIDs: [String] = []
        var counts: [UUID: Int] = [:]
        var downloads: [UUID: Int] = [:]
        var dates: [UUID: Date] = [:]
        var latestDocs: [UUID: SharedExerciseDoc] = [:]
        for doc in docs {
            guard var exercise = doc.exercise, exercise.visibility == .public,
                  seenExercises.insert(exercise.id).inserted else { continue }
            if let name = names[doc.userID] { exercise.uploaderName = name }
            fetched.append(exercise)
            counts[exercise.id] = doc.likes ?? 0
            downloads[exercise.id] = doc.downloads ?? 0
            if let createdAt = doc.createdAt {
                dates[exercise.id] = Date(timeIntervalSince1970: createdAt)
            }
            latestDocs[exercise.id] = doc
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
        likeCounts = counts
        downloadCounts = downloads
        // Dates this device stamped but hasn't uploaded yet (or whose upload the
        // server hasn't handed back yet) are kept, so an exercise doesn't lose
        // its date between the stamp and the next fetch.
        shareDates = shareDates.merging(dates) { _, fetched in fetched }
        fetchedDocs = latestDocs
        hasFetched = true
        persistCounts()
        persistShareDates()
    }

    // MARK: - Sorting

    /// The community exercises in the order the given sort asks for. Exercises
    /// with no recorded share date (shared before dates existed) count as the
    /// oldest, and ties break by name so the order never jitters between fetches.
    func sorted(_ exercises: [Exercise], by sort: CommunitySort) -> [Exercise] {
        func byName(_ a: Exercise, _ b: Exercise) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func date(_ exercise: Exercise) -> Date {
            shareDates[exercise.id] ?? .distantPast
        }
        return exercises.sorted { a, b in
            switch sort {
            case .mostLiked:
                let (x, y) = (likeCounts[a.id] ?? 0, likeCounts[b.id] ?? 0)
                return x == y ? byName(a, b) : x > y
            case .mostDownloaded:
                let (x, y) = (downloadCounts[a.id] ?? 0, downloadCounts[b.id] ?? 0)
                return x == y ? byName(a, b) : x > y
            case .newest:
                let (x, y) = (date(a), date(b))
                return x == y ? byName(a, b) : x > y
            case .oldest:
                let (x, y) = (date(a), date(b))
                return x == y ? byName(a, b) : x < y
            case .alphabetical:
                return byName(a, b)
            }
        }
    }
}
