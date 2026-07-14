//
//  CommunitySync.swift
//  Learn2Sing
//

import Foundation
import Combine

/// The document each user keeps on the server under their device ID: all of
/// their public exercises together with the MIDI patterns and text labels,
/// in the same per-uuid dictionary layout as ExerciseBundle.
struct SharedExercisesDoc: Codable {
    var deviceID: String
    var exercises: [Exercise]
    var midi: [String: [MIDINote]]
    var texts: [String: [MIDIText]]? = nil
}

/// Connects the Community tab to the server. Each device persists a single
/// SHARED_EXERCISE document holding its public exercises (re-uploaded whenever
/// the library changes, so making an exercise private removes it for everyone),
/// and the tab lists the documents of every other device via the public fetch
/// endpoint. Fetched patterns are cached under the standard `midi_<uuid>` /
/// `miditext_<uuid>` UserDefaults keys, so thumbnails, playback, and Download
/// treat community exercises exactly like local ones.
@MainActor
final class CommunitySync: ObservableObject {
    static let shared = CommunitySync()

    private static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
    /// The last fetched community list, kept so the tab has content offline
    /// and immediately at launch.
    private static let cachedListKey = "communityExercises"
    /// UUID strings whose midi/miditext keys were written by a fetch, so a later
    /// fetch can clean up patterns of exercises that left the community list.
    private static let cachedPatternIDsKey = "communityPatternIDs"

    /// Other users' public exercises, in the order the server returns them.
    /// The user's own public exercises are not in here — the Community tab
    /// shows the local copies, which are never stale.
    @Published private(set) var exercises: [Exercise] = []

    private weak var store: ExerciseStore?
    private var storeObservation: AnyCancellable?
    private let uploadTrigger = PassthroughSubject<Void, Never>()
    private var uploadDebounce: AnyCancellable?
    private var readyToUpload = false
    /// Body of the last accepted upload; identical re-encodes are skipped, so
    /// the store's frequent unrelated changes don't cause redundant POSTs.
    private var lastUploadedBody: Data?

    private init() {
        loadCachedList()
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

    /// Snapshots the public exercises with their patterns and POSTs them as this
    /// device's shared document.
    private func upload() async {
        guard readyToUpload, let store else { return }
        let publicExercises = store.exercises.filter { $0.visibility == .public }
        var midi: [String: [MIDINote]] = [:]
        var texts: [String: [MIDIText]] = [:]
        for exercise in publicExercises {
            midi[exercise.id.uuidString] = store.notes(for: exercise.id)
            let t = store.texts(for: exercise.id)
            if !t.isEmpty { texts[exercise.id.uuidString] = t }
        }
        let deviceID = DeviceIdentifier.uuidString
        let doc = SharedExercisesDoc(deviceID: deviceID,
                                     exercises: publicExercises,
                                     midi: midi,
                                     texts: texts.isEmpty ? nil : texts)
        // Compact and key-sorted: the server rejects documents past roughly
        // 64 KB, and a deterministic encoding makes the skip-if-unchanged
        // comparison below reliable.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(doc), body != lastUploadedBody,
              let url = URL(string: "\(Self.baseURL)/persist/\(deviceID)/SHARED_EXERCISE?customId1=\(deviceID)")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                lastUploadedBody = body
            } else if let http = response as? HTTPURLResponse {
                print("CommunitySync: upload failed with status \(http.statusCode)")
            }
        } catch {
            print("CommunitySync: upload failed: \(error)")
        }
    }

    // MARK: - Fetch

    /// A record as returned by the fetch endpoint: the stored document sits in
    /// `jsonData` as a JSON string.
    private struct PersistRecord: Decodable {
        var jsonData: String
    }

    /// Reloads the community list from the server. Called at launch and whenever
    /// the Community tab appears; a failure keeps the previous (cached) list.
    func refresh() async {
        guard let url = URL(string: "\(Self.baseURL)/fetch-public/SHARED_EXERCISE") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if let http = response as? HTTPURLResponse {
                    print("CommunitySync: fetch failed with status \(http.statusCode)")
                }
                return
            }
            apply(docs: Self.decodeDocs(from: data))
        } catch {
            print("CommunitySync: fetch failed: \(error)")
        }
    }

    /// The fetch endpoint answers with an array of records; documents that fail
    /// to decode (e.g. written by a newer app version) are skipped.
    private static func decodeDocs(from data: Data) -> [SharedExercisesDoc] {
        let decoder = JSONDecoder()
        guard let records = try? decoder.decode([PersistRecord].self, from: data) else { return [] }
        return records.compactMap {
            try? decoder.decode(SharedExercisesDoc.self, from: Data($0.jsonData.utf8))
        }
    }

    /// Publishes the fetched exercises and swaps their patterns into the
    /// UserDefaults cache, dropping patterns of exercises no longer shared.
    private func apply(docs: [SharedExercisesDoc]) {
        let ownDeviceID = DeviceIdentifier.uuidString
        let localIDs = Set(store?.exercises.map(\.id) ?? [])
        let defaults = UserDefaults.standard
        var seenDevices = Set<String>()
        var seenExercises = Set<UUID>()
        var remote: [Exercise] = []
        var cachedIDs: [String] = []
        for doc in docs where doc.deviceID != ownDeviceID && seenDevices.insert(doc.deviceID).inserted {
            for exercise in doc.exercises where exercise.visibility == .public {
                // Skip ids that exist locally so an exercise can never appear
                // twice; the local copy always wins.
                guard !localIDs.contains(exercise.id),
                      seenExercises.insert(exercise.id).inserted else { continue }
                remote.append(exercise)
                cachedIDs.append(exercise.id.uuidString)
                if let notes = doc.midi[exercise.id.uuidString],
                   let data = try? JSONEncoder().encode(notes) {
                    defaults.set(data, forKey: ExerciseStore.midiKey(exercise.id))
                }
                if let texts = doc.texts?[exercise.id.uuidString],
                   let data = try? JSONEncoder().encode(texts) {
                    defaults.set(data, forKey: ExerciseStore.midiTextKey(exercise.id))
                } else {
                    defaults.removeObject(forKey: ExerciseStore.midiTextKey(exercise.id))
                }
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
        exercises = remote
        saveCachedList()
    }

    // MARK: - Offline cache

    private func loadCachedList() {
        guard let data = UserDefaults.standard.data(forKey: Self.cachedListKey),
              let saved = try? JSONDecoder().decode([Exercise].self, from: data)
        else { return }
        exercises = saved
    }

    private func saveCachedList() {
        guard let data = try? JSONEncoder().encode(exercises) else { return }
        UserDefaults.standard.set(data, forKey: Self.cachedListKey)
    }
}
