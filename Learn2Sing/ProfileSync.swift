//
//  ProfileSync.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 11.07.26.
//

import Foundation
import Combine

/// Keeps the user's profile (username, description, device ID, the whole
/// Exercises tab and the settings) mirrored on the server as a single JSON
/// document, keyed by the private device ID. Because that ID lives in the
/// Keychain it survives reinstalls, so a fresh install can fetch the profile
/// back and restore the library.
@MainActor
final class ProfileSync {
    static let shared = ProfileSync()

    private static let baseURL = "https://echolex.api.phrase-by-phrase.com/api/v1/learn2Sing"
    /// Set once a restore attempt has reached the server. Lives in UserDefaults,
    /// which is wiped on reinstall — exactly when a restore should run again.
    private static let restoredKey = "didAttemptProfileRestore"

    /// Ceiling on the uploaded document. The server stores it in a TEXT column
    /// and answers 500 past roughly 64 KB, so aim short of that rather than at it.
    private static let maxUploadBytes = 60_000

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
    /// The document the server last accepted, so a change that leaves the profile
    /// looking exactly the same doesn't cost a request. Both the store and
    /// UserDefaults change for plenty of reasons the profile doesn't record.
    private var lastUploadedBody: Data?

    private init() {}

    /// Call once at launch: restores the profile on a fresh install, then keeps
    /// the server copy up to date as the profile, exercises or settings change.
    func start(with store: ExerciseStore, templates: VisualTemplateStore) async {
        guard self.store == nil else { return }
        self.store = store
        self.visualTemplates = templates

        // Coalesce bursts of edits into one upload.
        uploadDebounce = uploadTrigger
            .debounce(for: .seconds(3), scheduler: DispatchQueue.main)
            .sink { Task { @MainActor in await ProfileSync.shared.upload() } }
        storeObservation = store.objectWillChange
            .sink { [weak self] _ in self?.scheduleUpload() }
        // The settings live in UserDefaults rather than on the store, and every
        // settings screen writes them straight through @AppStorage — so one
        // observer covers the lot of them. It hears far more than the settings,
        // but an upload that would send an unchanged document is dropped below.
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

    /// Request an upload soon; safe to call from any change handler.
    func scheduleUpload() {
        guard readyToUpload else { return }
        uploadTrigger.send()
    }

    // MARK: - Upload

    /// Builds the full profile JSON (username + device ID + exercise library +
    /// the Home tab's routines and favourites + every exercise's scores + the
    /// practice calendar + the settings), saves it locally, and POSTs it to the
    /// server.
    private func upload() async {
        guard readyToUpload, let store else { return }
        var profile = UserProfile.load()
        profile.snapshot(store)
        profile.save()
        guard let body = Self.uploadBody(for: profile),
              let url = URL(string: "\(Self.baseURL)/persist/\(profile.deviceID)/PROFILE")
        else { return }
        // Nothing to say: the last document the server took is this one.
        guard body != lastUploadedBody else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("ProfileSync: upload failed with status \(http.statusCode)")
                return
            }
            lastUploadedBody = body
        } catch {
            print("ProfileSync: upload failed: \(error)")
        }
    }

    /// One recorded run together with the exercise it belongs to, so the trimming
    /// below can rank every exercise's runs against each other.
    private struct DatedRun {
        let exerciseID: String
        let entry: ScoreEntry
    }

    /// The profile encoded for upload, in compact JSON — unlike the
    /// pretty-printed local file — with as much score history as fits.
    ///
    /// Everything else in the document is bounded by what a user can plausibly
    /// build by hand, but scores grow with every run, so they are what gives way
    /// as the document nears the server's size limit: the newest runs are kept
    /// and older ones left out. Only the upload is trimmed — the device keeps the
    /// full history and the chart still draws it. nil when even a score-less
    /// profile is too big to send, since an oversized POST is what once took the
    /// endpoint down for everyone.
    private static func uploadBody(for profile: UserProfile) -> Data? {
        var profile = profile
        let encoder = JSONEncoder()
        // Sorted keys so an unchanged profile encodes byte for byte the same way
        // twice, which is what lets `upload()` recognise it as unchanged.
        encoder.outputFormatting = [.sortedKeys]
        // The library is most of this document and the ids of its notes and text
        // labels were most of the library — 36 characters apiece for something
        // no stored data refers to and a restore can mint again. Leaving them out
        // is worth thousands of runs of score history in the room it frees.
        encoder.userInfo[.omitPatternIDs] = true
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
        // Restore the Home category order first: it lives in UserDefaults (wiped
        // on reinstall), and `load()` reads it back out from there.
        if let order = remote.homeCategoryOrder {
            HomeCategories.stored = order
        }
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
        if let bundle = remote.exercises {
            store.importBundle(bundle)
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
        if let scores = remote.scores {
            ScoreHistory.merge(scores.mapValues(\.entries))
        }
        if let practice = remote.practice {
            PracticeLog.merge(doc: practice)
        }
        // The settings, last: they are the one part that replaces rather than
        // merges — a setting has a single value, and the restored one is it. The
        // app's language isn't among them; it stays as this device has it.
        if let settings = remote.settings, let visualTemplates {
            settings.apply(store: store, templates: visualTemplates)
        }
    }
}
