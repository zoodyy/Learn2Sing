//
//  DeleteEverything.swift
//  Learn2Sing
//
//  What the "Delete Everything" button at the bottom of Settings ▸ Reset does:
//  the four Reset screens' worth of local wiping, plus everything this user has
//  on the server, which nothing else in the app takes down.
//

import Foundation

/// Deletes the lot: the library, the scores, the settings and the Home tab's
/// lists on this device, and on the server the profile backup a reinstall would
/// restore them all from, this user's public profile, every exercise they
/// shared, and every like, download and play they ever posted.
///
/// What is left afterwards is what a first launch finds — an untouched library,
/// default settings, no username — with the one exception the app cannot change:
/// the device id, which lives in the Keychain and outlives even deleting the app.
/// That id is the key to the server backup, which is why deleting the backup is
/// part of this rather than something the next install could be left to sort out.
@MainActor
enum DeleteEverything {
    /// Set while a wipe still owes the server something, so a wipe made offline
    /// finishes at the next launch instead of quietly leaving the records up.
    private static let pendingKey = "pendingServerWipe"
    /// The shared exercises that wipe hasn't managed to delete yet, by raw id.
    /// Written down when the user asks rather than looked up again later: an
    /// exercise shared *after* the wipe is theirs to keep, and a retry that went
    /// by what is shared now would take it with the rest.
    private static let pendingExercisesKey = "pendingServerWipeExercises"

    /// Wipes everything, server first.
    ///
    /// The server side goes first because the local side is what says where to
    /// look: which exercises have a record on the server is bookkeeping that the
    /// wipe itself clears. What it can't get through — the whole of it, offline —
    /// is left marked, and `finishPendingWipe()` picks it up at the next launch.
    ///
    /// Uploads are held back across the whole thing. Clearing a library and a
    /// screen's worth of settings is hundreds of changes, every one of which asks
    /// both syncs for an upload, and one landing mid-wipe would put back the very
    /// records being deleted.
    static func run(store: ExerciseStore, templates: VisualTemplateStore) async {
        ProfileSync.shared.suspendUploads()
        CommunitySync.shared.suspendUploads()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: pendingKey)
        defaults.set(CommunitySync.shared.uploadedExerciseIDs, forKey: pendingExercisesKey)

        await deleteFromServer()
        wipeDevice(store: store, templates: templates)

        ProfileSync.shared.resumeUploads()
        CommunitySync.shared.resumeUploads()
    }

    /// Finishes a wipe whose server calls didn't get through, at the launch after
    /// the one that made it. Costs nothing when there is nothing pending, which
    /// is every ordinary launch.
    ///
    /// Runs before either sync starts — an upload beating it to the server would
    /// re-create the profile record it is here to delete.
    static func finishPendingWipe() async {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return }
        await deleteFromServer()
    }

    /// Everything this user has on the server. The pending marks are cleared only
    /// when every call reports the server took it, so a wipe that ran out of
    /// network halfway is finished rather than forgotten. Deleting a record that
    /// is already gone costs a request and changes nothing, so a retry can simply
    /// ask for the lot again.
    private static func deleteFromServer() async {
        let defaults = UserDefaults.standard
        // First: the record a reinstall would otherwise restore the whole library
        // from, and so the one whose loss the user is really asking for. Each of
        // these is awaited on its own rather than short-circuited, since a call
        // that fails is no reason to leave the other records up.
        let backup = await ProfileSync.shared.deleteBackup()
        let owed = defaults.stringArray(forKey: pendingExercisesKey) ?? []
        let failed = await CommunitySync.shared.deleteSharedExercises(owed)
        let events = await CommunitySync.shared.deleteAllEvents()
        let profile = await CommunitySync.shared.deletePublicProfile()
        if failed.isEmpty {
            defaults.removeObject(forKey: pendingExercisesKey)
        } else {
            defaults.set(failed, forKey: pendingExercisesKey)
        }
        if backup && events && profile && failed.isEmpty {
            defaults.removeObject(forKey: pendingKey)
        }
    }

    /// Everything the device holds. In the same order the Reset screens do it, so
    /// that what this button leaves behind is exactly what pressing every one of
    /// them would.
    private static func wipeDevice(store: ExerciseStore, templates: VisualTemplateStore) {
        // Reset ▸ Exercises, both halves: the exercises the user brought in go,
        // and the ones that shipped with the app come back as they shipped.
        store.deleteOwnExercises()
        store.deleteDownloadedExercises()
        store.revertAllBundled()

        // Reset ▸ Scores and Reset ▸ Home. The scores' server side went with the
        // events above, so this is only what the device recorded.
        ScoreHistory.deleteAll()
        PracticeLog.deleteAll()
        store.clearFavourites()
        store.clearRoutines()
        store.clearPlayHistory()

        // Reset ▸ Settings, every category — which includes putting the visual
        // templates back to the two the app ships and clearing the username.
        for category in ResettableSettings.allCases {
            category.reset(store: store, templates: templates)
        }
        // Instruments the user uploaded, which the Audio category deliberately
        // keeps: a reset puts settings back, this deletes things.
        CustomInstrumentStore.shared.deleteAll()

        // The profile file itself, rather than field by field: a fresh install
        // has none, and `UserProfile.load()` mints an empty one on demand. Takes
        // the description, the join date and the liked and downloaded sets with
        // it — the parts the Profile category's reset leaves alone because a
        // reset of the *settings* has no business deleting them.
        try? FileManager.default.removeItem(at: UserProfile.fileURL)
        ProfilePictureStore.shared.removePicture()
        CommunitySync.shared.forgetLocalState()
        SkillLevelStore.shared.recompute()
    }
}
