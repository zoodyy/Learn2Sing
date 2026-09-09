//
//  ServerDelete.swift
//  Learn2Sing
//

import Foundation

/// The backend's delete endpoints — the counterpart to `persist` and
/// `user-event`, and the only way anything this app has published actually
/// leaves the server.
///
/// Until they existed a delete here was an overwrite: a record carrying an empty
/// document posted over the one being taken down (the tombstones
/// `CommunitySync.uploadSharedExercises` used to leave behind), and an
/// offsetting REMOVE_LIKE event posted over a like. Both left the row where it
/// was and only made it read as nothing; these take the row away.
///
/// What each path segment is matched against is not obvious from the persist
/// side, so it was measured against the live backend on 2026-09-09, with
/// throwaway ids:
///
/// * **The `userId` of a storage row is the `entityId` it was persisted under**
///   — the first path segment of `persist/<entityId>/<STORAGE_TYPE>`. That is
///   the user themselves for PROFILE and PUBLIC_PROFILE, which this app
///   persists under the device id and the public user id; for SHARED_EXERCISE
///   it is the exercise's public id, so one call takes down one exercise.
///   Nothing matches `customId1`, which is where a shared exercise carries its
///   uploader.
/// * **Deleting a storage row deletes that entity's user events with it** — the
///   likes, downloads and plays posted against the same id, whoever posted
///   them. So unsharing an exercise now costs it its tally and its community
///   difficulty for good, where a tombstone used to leave both waiting for it.
/// * **`delete-events` matches the ids the event was posted under** and is
///   scoped to the one user: another user's events on the same exercise stay.
/// * **The four-segment `delete-storage/<userId>/<TYPE>/<entityId>` matches
///   nothing.** It answers 200 and leaves the row where it is, for every
///   combination of a row's own ids that was tried. Its job is done by the
///   three-segment form anyway — the entityId *is* the key — so nothing here
///   calls it.
///
/// Every one of these answers 200 whether or not it matched a row, so what the
/// results below report is that the server took the request, not that anything
/// was there to delete.
enum ServerDelete {
    /// Deletes the record persisted under `entityID` for `storageType`, and with
    /// it every user event posted against that same id.
    @discardableResult
    static func storage(_ entityID: String, type storageType: String) async -> Bool {
        await send("delete-storage/\(entityID)/\(storageType)",
                   describedAs: "\(storageType) record \(entityID)")
    }

    /// Deletes one user's events of one type on one entity, leaving both their
    /// other events on it and everybody else's alone.
    @discardableResult
    static func events(of userID: String, on entityID: String,
                       type: UserEventType) async -> Bool {
        await send("delete-events/\(userID)/\(entityID)/\(type.rawValue)",
                   describedAs: "\(type.rawValue) events of \(userID) on \(entityID)")
    }

    /// Deletes every event this user has ever posted, on every entity: their
    /// likes, their downloads and the scores their finished runs contributed to
    /// each exercise's difficulty.
    @discardableResult
    static func allEvents(of userID: String) async -> Bool {
        await send("delete-events/\(userID)", describedAs: "all events of \(userID)")
    }

    /// One DELETE, reporting whether the server took it. `description` is what a
    /// failure is logged as, since the path itself is a wall of UUIDs.
    private static func send(_ path: String, describedAs description: String) async -> Bool {
        guard let url = URL(string: "\(CommunitySync.baseURL)/\(path)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("ServerDelete: \(description) failed with status \(http.statusCode)")
                return false
            }
            return true
        } catch {
            print("ServerDelete: \(description) failed: \(error)")
            return false
        }
    }
}
