//
//  BlockedUsers.swift
//  Learn2Sing
//
//  The other users this user has blocked, from the report sheet (see
//  CommunityReport). A block is this device's own doing and nobody else's: the
//  server goes on listing the blocked user's exercises and profile, and the app
//  leaves them out wherever it shows what it fetched — the community lists (see
//  CommunityFeed), "New for You" (see NewForYouFeed) and the uploader profiles
//  (see `CommunitySync.publicProfile(for:)`).
//

import Foundation
import Combine

/// One blocked user: the public user id their exercises and profile are listed
/// under, which is what the block matches on, and the username they had when
/// they were blocked, which is only for Settings ▸ Profile to show them by. The
/// name is never looked up again: a blocked user's documents aren't read.
nonisolated struct BlockedUser: Codable, Hashable, Sendable {
    var id: String
    var name: String
}

/// Who this user has blocked, kept in the profile file so it rides along in the
/// private backup and a reinstall still hides the same people (see ProfileSync).
@MainActor
final class BlockedUsers: ObservableObject {
    static let shared = BlockedUsers()

    /// Everyone blocked, in the order they were blocked. The lists that hide
    /// them subscribe to this; @Published sends before the value changes, so
    /// they go by the array it hands them rather than reading `ids` back.
    @Published private(set) var users: [BlockedUser]

    /// The blocked public user ids, for matching against what a fetch returned.
    var ids: Set<String> { Self.ids(of: users) }

    static func ids(of users: [BlockedUser]) -> Set<String> {
        Set(users.map(\.id))
    }

    private init() {
        users = UserProfile.load().blockedUsers ?? []
    }

    /// Whether `userID` is blocked. nil is an uploader nobody has named, and
    /// there is nothing to match that against.
    func contains(_ userID: String?) -> Bool {
        guard let userID else { return false }
        return users.contains { $0.id == userID }
    }

    /// Whether the community exercise listed under `publicExerciseID` belongs to
    /// someone blocked, by the uploader the fetch named for it.
    func hides(exercise publicExerciseID: UUID) -> Bool {
        contains(CommunitySync.shared.uploaderID(of: publicExerciseID))
    }

    /// The report sheet's block, once the report has gone to the developer.
    func block(_ user: BlockedUser) {
        guard !user.id.isEmpty, !contains(user.id) else { return }
        users.append(user)
        save()
    }

    /// Settings ▸ Profile ▸ Blocked Users: everything of theirs shows again, from
    /// the lists' next look at what they already hold.
    func unblock(_ userID: String) {
        guard contains(userID) else { return }
        users.removeAll { $0.id == userID }
        save()
    }

    /// Adds the blocks a restored profile carried to this device's. Merged rather
    /// than replaced, like the Home tab's lists, so a block made here before the
    /// restore arrived stays.
    func merge(_ restored: [BlockedUser]?) {
        let missing = (restored ?? []).filter { !$0.id.isEmpty && !contains($0.id) }
        guard !missing.isEmpty else { return }
        users.append(contentsOf: missing)
        save()
    }

    /// "Delete Everything", after the profile file has gone: a fresh install has
    /// blocked nobody. Nothing is written, since there is no file left to write
    /// the empty list into and `UserProfile.load()` mints one without it.
    func forget() {
        guard !users.isEmpty else { return }
        users = []
    }

    /// Mirrors the list into the profile file and asks ProfileSync to send it on.
    private func save() {
        var profile = UserProfile.load()
        profile.blockedUsers = users.isEmpty ? nil : users
        profile.save()
        ProfileSync.shared.scheduleUpload()
    }
}
