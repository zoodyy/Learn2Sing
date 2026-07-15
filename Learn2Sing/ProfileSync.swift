//
//  ProfileSync.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 11.07.26.
//

import Foundation
import Combine

/// Keeps the user's profile (username, device ID, and the whole Exercises tab)
/// mirrored on the server as a single JSON document, keyed by the private
/// device ID shown in the profile settings. Because that ID lives in the
/// Keychain it survives reinstalls, so a fresh install can fetch the profile
/// back and restore the library.
@MainActor
final class ProfileSync {
    static let shared = ProfileSync()

    private static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
    /// Set once a restore attempt has reached the server. Lives in UserDefaults,
    /// which is wiped on reinstall — exactly when a restore should run again.
    private static let restoredKey = "didAttemptProfileRestore"

    private weak var store: ExerciseStore?
    private var storeObservation: AnyCancellable?
    /// Uploads are held back until the initial restore attempt has finished so a
    /// fresh install can't overwrite the server profile with the seeded library.
    private var readyToUpload = false
    private let uploadTrigger = PassthroughSubject<Void, Never>()
    private var uploadDebounce: AnyCancellable?

    private init() {}

    /// Call once at launch: restores the profile on a fresh install, then keeps
    /// the server copy up to date as the profile or exercises change.
    func start(with store: ExerciseStore) async {
        guard self.store == nil else { return }
        self.store = store

        // Coalesce bursts of edits into one upload.
        uploadDebounce = uploadTrigger
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { Task { @MainActor in await ProfileSync.shared.upload() } }
        storeObservation = store.objectWillChange
            .sink { [weak self] _ in self?.scheduleUpload() }

        await restoreIfNeeded()
        readyToUpload = true
        // One upload per launch so the server copy exists even before the first
        // edit and catches up on changes made while offline.
        scheduleUpload()
    }

    /// Request an upload soon; safe to call from any change handler.
    func scheduleUpload() {
        guard readyToUpload else { return }
        uploadTrigger.send()
    }

    // MARK: - Upload

    /// Builds the full profile JSON (username + device ID + exercise library),
    /// saves it locally, and POSTs it to the server.
    private func upload() async {
        guard readyToUpload, let store else { return }
        var profile = UserProfile.load()
        profile.exercises = store.exportBundle()
        profile.save()
        // Compact encoding (unlike the pretty-printed local file): the server
        // rejects documents past roughly 64 KB, so every byte counts.
        guard let body = try? JSONEncoder().encode(profile),
              let url = URL(string: "\(Self.baseURL)/persist/\(profile.deviceID)/PROFILE")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("ProfileSync: upload failed with status \(http.statusCode)")
            }
        } catch {
            print("ProfileSync: upload failed: \(error)")
        }
    }

    // MARK: - Restore

    /// On the first launch after an (re)install, fetches the profile stored under
    /// this device's private ID and merges it back in. A server error leaves the
    /// attempt flag unset so the next launch retries.
    private func restoreIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.restoredKey), let store else { return }
        guard let url = URL(string: "\(Self.baseURL)/fetch-private/\(DeviceIdentifier.uuidString)/PROFILE")
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
        var profile = UserProfile.load()
        if profile.username.isEmpty {
            profile.username = remote.username
        }
        profile.exercises = remote.exercises
        profile.save()
        if let bundle = remote.exercises {
            store.importBundle(bundle)
        }
    }
}
