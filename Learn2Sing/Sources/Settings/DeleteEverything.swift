//
//  DeleteEverything.swift
//  Learn2Sing
//
//  What the "Delete Everything" button at the bottom of Settings ▸ Reset does:
//  puts the app back to what a new install finds, and takes down everything
//  this user has on the server, which nothing else in the app does.
//

import Foundation

/// Deletes the lot: everything the app keeps on this device — the library, the
/// scores, every setting, how the Home and Exercises tabs are arranged, the hints
/// and the introduction already seen — and on the server the profile backup a
/// reinstall would restore it all from, this user's public profile, every
/// exercise they shared, and every like, download and play they ever posted.
///
/// What is left afterwards is what a new install on a new device has after its
/// first launch, and the next launch opens on the introduction as that one did.
/// The exceptions are the things the app cannot or must not undo: the device id,
/// which lives in the Keychain and outlives even deleting the app; a block the
/// server has put on it; and the record of server deletions still owed. The id
/// is the key to the server backup, which is why deleting the backup is part of
/// this rather than something the next install could be left to sort out.
@MainActor
enum DeleteEverything {
    /// The parts of the server's side that are retried until they go through, so
    /// a wipe made offline finishes at a later launch instead of quietly leaving
    /// the records up. The backup isn't one of them: when it can't be deleted,
    /// the wiped profile is uploaded over it instead (see
    /// `ProfileSync.resumeUploads(backupDeleted:)`), and that upload is retried
    /// like any other.
    private enum ServerPart: String, CaseIterable {
        /// Every exercise this user shared. Sharing waits while it is owed (see
        /// `isTakingDownSharedExercises`).
        case sharedExercises
        /// Every like, download and play they posted.
        case events
        /// Their public profile: the name, the description, the join date and
        /// the picture. A new name taken since replaces it (see
        /// `publicProfileReplaced()`).
        case publicProfile
    }

    private static let pendingPartsKey = "pendingServerWipeParts"
    /// Where older builds wrote down that the server's side was owed, all of it
    /// at once; read as every part still owed.
    private static let legacyPendingKey = "pendingServerWipe"
    /// Where older builds wrote down, by raw id, the shared exercises a pending
    /// wipe still owed the server. Only cleared out now.
    private static let legacyPendingExercisesKey = "pendingServerWipeExercises"

    private static var owed: Set<ServerPart> {
        get {
            let defaults = UserDefaults.standard
            if let parts = defaults.stringArray(forKey: pendingPartsKey) {
                return Set(parts.compactMap(ServerPart.init(rawValue:)))
            }
            return defaults.bool(forKey: legacyPendingKey) ? Set(ServerPart.allCases) : []
        }
        set {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: legacyPendingKey)
            defaults.removeObject(forKey: legacyPendingExercisesKey)
            if newValue.isEmpty {
                defaults.removeObject(forKey: pendingPartsKey)
            } else {
                defaults.set(newValue.map(\.rawValue).sorted(), forKey: pendingPartsKey)
            }
        }
    }

    /// Whether a wipe still owes the server the exercises this user shared.
    /// Community sync holds its exercise uploads back meanwhile (see
    /// `CommunitySync.uploadSharedExercises`).
    static var isTakingDownSharedExercises: Bool {
        owed.contains(.sharedExercises)
    }

    /// A public profile posted since the wipe, under the same id, has replaced
    /// the one it couldn't take down, so there is nothing left of that one to
    /// delete — and deleting it later would take the new one with it.
    static func publicProfileReplaced() {
        guard owed.contains(.publicProfile) else { return }
        owed.remove(.publicProfile)
    }

    /// Wipes everything, server first. What the server side can't get through —
    /// the whole of it, offline — is left marked, and `finishPendingWipe()`
    /// picks it up at the next launch.
    ///
    /// Uploads are held back across the whole thing. Clearing a library and a
    /// screen's worth of settings is hundreds of changes, every one of which asks
    /// both syncs for an upload, and one landing mid-wipe would put back the very
    /// records being deleted.
    static func run(store: ExerciseStore, templates: VisualTemplateStore) async {
        ProfileSync.shared.suspendUploads()
        CommunitySync.shared.suspendUploads()
        owed = Set(ServerPart.allCases)

        // First: the record a reinstall would otherwise restore the whole library
        // from, and so the one whose loss the user is really asking for.
        let backupDeleted = await ProfileSync.shared.deleteBackup()
        await takeDownOwedParts()
        wipeDevice(store: store, templates: templates)

        ProfileSync.shared.resumeUploads(backupDeleted: backupDeleted)
        CommunitySync.shared.resumeUploads()
        CommunitySync.shared.refreshAfterWipe()
    }

    /// Finishes a wipe whose server calls didn't get through, at the launches
    /// after the one that made it. Costs nothing when there is nothing pending,
    /// which is every ordinary launch.
    ///
    /// Runs before either sync starts — an upload beating it to the server would
    /// re-create a record it is here to delete.
    static func finishPendingWipe() async {
        guard !owed.isEmpty else { return }
        await takeDownOwedParts()
    }

    /// Asks the server for each part still owed, and crosses off the ones it
    /// took. Each is asked on its own rather than short-circuited, since a call
    /// that fails is no reason to leave the other records up; and a part already
    /// gone costs a request and changes nothing, so a retry simply asks again.
    private static func takeDownOwedParts() async {
        for part in ServerPart.allCases where owed.contains(part) {
            let done: Bool
            switch part {
            case .sharedExercises: done = await CommunitySync.shared.deleteAllSharedExercises()
            case .events: done = await CommunitySync.shared.deleteAllEvents()
            case .publicProfile: done = await CommunitySync.shared.deletePublicProfile()
            }
            if done { owed.remove(part) }
        }
    }

    /// Everything the device holds, gone and then set up again the way a first
    /// launch sets it up.
    ///
    /// Not key by key: whatever is stored and not on the short list in `survives`
    /// goes, so a setting, a hint or a list added later is wiped without anyone
    /// having to remember to add it here. What is held in memory is put back
    /// first, by the objects that hold it — some of them write as they go, and
    /// the sweep takes that with everything else — and the library and the
    /// playback look are then built up again by the very steps a first launch
    /// takes.
    private static func wipeDevice(store: ExerciseStore, templates: VisualTemplateStore) {
        templates.deselect()
        LanguageManager.shared.language = .english
        RecommendationQueue.shared.forget()
        BookLessonProgress.shared.clear()
        BlockedUsers.shared.forget()
        ProfilePictureStore.shared.removePicture()
        CommunitySync.shared.forgetLocalState()
        ReviewPrompt.shared.forget()
        MicrophoneNotice.wasShownThisLaunch = false

        removeStoredState()

        // The theme and the language are gone by now, so the library and the look
        // come back for the appearance the device is in.
        store.resetToFirstLaunch()
        templates.resetToFirstLaunch()
        OrientationLockManager.apply(.none)
        AppUsageTime.restart()
        SkillLevelStore.shared.forget()
        // Bar a block, which is the server's doing rather than the user's data:
        // wiping the device doesn't end it.
        AccountBlock.shared.rewrite()
    }

    /// Everything stored on the device but what `survives`: every key in the
    /// app's UserDefaults, every file in its documents (the profile, the picture)
    /// and temporary folders, and the network cache.
    private static func removeStoredState() {
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier,
           let stored = defaults.persistentDomain(forName: domain) {
            let cachedPatterns = CommunitySync.shared.cachedPatternKeys
            for key in stored.keys where !survives(key) && !cachedPatterns.contains(key) {
                defaults.removeObject(forKey: key)
            }
        }
        // Through its owner first, which also drops what it has cached of it.
        UserProfile.deleteFile()
        let files = FileManager.default
        for folder in [files.urls(for: .documentDirectory, in: .userDomainMask)[0],
                       files.temporaryDirectory] {
            for item in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? files.removeItem(at: item)
            }
        }
        URLCache.shared.removeAllCachedResponses()
    }

    /// What a wipe leaves in UserDefaults besides the community's cached patterns
    /// (see `CommunitySync.cachedPatternKeys`). Each is either the wipe's own
    /// business or something a new install's first launch has set by the time
    /// it is over:
    /// - the server deletions still owed, so they get finished;
    /// - that the profile backup and the profile picture have been looked for on
    ///   the server. A first launch looks and sets both; cleared, the next launch
    ///   would look again, and could bring back the very backup or picture whose
    ///   deletion hasn't got through yet.
    private static func survives(_ key: String) -> Bool {
        [pendingPartsKey, legacyPendingKey, legacyPendingExercisesKey,
         ProfileSync.restoredKey, ProfilePictureStore.restoreCheckedKey].contains(key)
    }
}
