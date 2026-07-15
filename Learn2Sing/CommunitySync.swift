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
    var deviceID: String
    var exercise: Exercise? = nil
    var midi: [MIDINote] = []
    var texts: [MIDIText]? = nil
}

/// The document each user keeps on the server under PUBLIC_NAME: their current
/// profile username. Fetched per device on refresh, so renaming yourself in the
/// profile updates the label on your exercises for everyone.
struct PublicNameDoc: Codable {
    var deviceID: String
    var username: String
}

/// Connects the Community tab to the server. Each device persists one
/// SHARED_EXERCISE document per public exercise, keyed by the exercise's ID
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

    /// Every device's public exercises as last fetched, in the order the server
    /// returns them. Empty until the first fetch of the session succeeds.
    @Published private(set) var exercises: [Exercise] = []
    /// true while a fetch is on the wire; drives the tab's initial spinner.
    @Published private(set) var isFetching = false

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

    private init() {
        // An earlier version persisted the fetched list under this key.
        UserDefaults.standard.removeObject(forKey: "communityExercises")
    }

    /// Call once at launch, after ProfileSync has restored the library (so a
    /// fresh install can't overwrite the server document with an empty list):
    /// fetches the community list and keeps the server copy of this device's
    /// public exercises up to date.
    func start(with store: ExerciseStore) async {
        guard self.store == nil else { return }
        self.store = store

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
        let deviceID = DeviceIdentifier.uuidString
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
            let doc = SharedExerciseDoc(deviceID: deviceID,
                                        exercise: exercise,
                                        midi: store.notes(for: exercise.id),
                                        texts: t.isEmpty ? nil : t)
            guard let body = try? encoder.encode(doc) else { continue }
            if body == lastUploadedBodies[idString] {
                onServer.insert(idString)
                continue
            }
            if await post(body: body, exerciseID: idString, exerciseName: exercise.name) {
                lastUploadedBodies[idString] = body
                onServer.insert(idString)
            }
        }

        let publicIDs = Set(publicExercises.map { $0.id.uuidString })
        for idString in onServer.subtracting(publicIDs) {
            guard let body = try? encoder.encode(SharedExerciseDoc(deviceID: deviceID)) else { continue }
            if await post(body: body, exerciseID: idString, exerciseName: "") {
                lastUploadedBodies.removeValue(forKey: idString)
                onServer.remove(idString)
            }
        }
        defaults.set(onServer.sorted(), forKey: Self.uploadedExerciseIDsKey)
    }

    /// POSTs one per-exercise document to the persist endpoint; returns whether
    /// the server accepted it.
    private func post(body: Data, exerciseID: String, exerciseName: String) async -> Bool {
        var components = URLComponents(string: "\(Self.baseURL)/persist/\(exerciseID)/SHARED_EXERCISE")
        components?.queryItems = [
            URLQueryItem(name: "customId1", value: DeviceIdentifier.uuidString),
            URLQueryItem(name: "customName", value: exerciseName),
            URLQueryItem(name: "customId2", value: exerciseID),
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
                print("CommunitySync: upload of \(exerciseID) failed with status \(http.statusCode)")
            }
        } catch {
            print("CommunitySync: upload of \(exerciseID) failed: \(error)")
        }
        return false
    }

    /// POSTs the profile username as this device's PUBLIC_NAME document.
    private func uploadPublicName() async {
        guard readyToUpload else { return }
        let deviceID = DeviceIdentifier.uuidString
        let doc = PublicNameDoc(deviceID: deviceID, username: UserProfile.load().username)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(doc), body != lastUploadedName,
              let url = URL(string: "\(Self.baseURL)/persist/\(deviceID)/PUBLIC_NAME?customId1=\(deviceID)")
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
            let names = await Self.fetchPublicNames(for: Set(docs.map(\.deviceID)))
            apply(docs: docs, names: names)
        } catch {
            print("CommunitySync: fetch failed: \(error)")
        }
    }

    /// Fetches every uploader's PUBLIC_NAME document in parallel and returns the
    /// non-empty usernames by device ID. Devices whose fetch fails are simply
    /// absent, so their exercises keep the name stamped at publish time.
    private static func fetchPublicNames(for deviceIDs: Set<String>) async -> [String: String] {
        await withTaskGroup(of: (String, String)?.self) { group in
            for deviceID in deviceIDs {
                group.addTask {
                    guard let url = URL(string: "\(baseURL)/fetch-public/PUBLIC_NAME?customId1=\(deviceID)"),
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
                    return (deviceID, doc.username)
                }
            }
            var names: [String: String] = [:]
            for await pair in group {
                if let (deviceID, username) = pair { names[deviceID] = username }
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
        let localIDs = Set(store?.exercises.map(\.id) ?? [])
        let defaults = UserDefaults.standard
        var seenExercises = Set<UUID>()
        var fetched: [Exercise] = []
        var cachedIDs: [String] = []
        for doc in docs {
            guard var exercise = doc.exercise, exercise.visibility == .public,
                  seenExercises.insert(exercise.id).inserted else { continue }
            if let name = names[doc.deviceID] { exercise.uploaderName = name }
            fetched.append(exercise)
            // Exercises that live in the local store (this device's own
            // uploads) already have their pattern under these keys; never
            // overwrite it with the server copy, which may lag behind.
            guard !localIDs.contains(exercise.id) else { continue }
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
            guard let id = UUID(uuidString: idString), !localIDs.contains(id) else { continue }
            defaults.removeObject(forKey: ExerciseStore.midiKey(id))
            defaults.removeObject(forKey: ExerciseStore.midiTextKey(id))
        }
        defaults.set(cachedIDs, forKey: Self.cachedPatternIDsKey)
        exercises = fetched
    }
}
