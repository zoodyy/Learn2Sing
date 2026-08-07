//
//  ProfileView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 05.07.26.
//

import SwiftUI
import UniformTypeIdentifiers

/// The user's profile, persisted as JSON in the app's documents directory.
/// The same JSON (with the exercise library embedded) is what ProfileSync
/// uploads to and restores from the server.
struct UserProfile: Codable {
    var username: String = ""
    var deviceID: String = ""
    /// Snapshot of the Exercises tab (exercises, categories, MIDI patterns,
    /// text labels). Optional so profiles written before sync existed decode.
    var exercises: ExerciseBundle? = nil
    /// The Home tab's category display order. Optional so profiles written
    /// before the order was synced still decode.
    var homeCategoryOrder: [String]? = nil
    /// Public ids (lowercase UUID strings) of the Community exercises this user
    /// has liked, so the hearts stay filled across launches and reinstalls.
    /// Owned by CommunitySync; optional so older profiles still decode.
    var likedExercises: [String]? = nil
    /// Public ids (lowercase UUID strings) of the Community exercises this user
    /// has downloaded, so a second download — including after a reinstall —
    /// doesn't count towards the exercise's download total again. Owned by
    /// CommunitySync; optional so older profiles still decode.
    var downloadedExercises: [String]? = nil
    /// The Home tab's "Routines" category: the user's routines in display order.
    /// Optional so profiles written before routines were synced still decode.
    var routines: [Routine]? = nil
    /// The Home tab's "Favourites" category: the favourited exercise ids in
    /// display order. Optional so profiles written before favourites were synced
    /// still decode.
    var favourites: [UUID]? = nil
    /// Every exercise's recorded scores — what the score chart draws — keyed by
    /// exercise UUID string. Optional so profiles written before scores were
    /// synced still decode.
    var scores: [String: ScoreHistoryDoc]? = nil
    /// The Settings tab's settings, bar the language. Optional so profiles written
    /// before settings were synced still decode.
    var settings: UserSettings? = nil

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile.json")
    }

    /// Loads the stored profile (or a fresh one) and stamps in the device ID,
    /// a UUID kept in the Keychain so it survives reinstalls, plus the live
    /// Home category order, which lives in UserDefaults.
    static func load() -> UserProfile {
        var profile = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) }
            ?? UserProfile()
        profile.deviceID = DeviceIdentifier.uuidString
        profile.homeCategoryOrder = HomeCategories.stored
        return profile
    }

    /// Fills in the parts of the profile that live outside the profile file: the
    /// exercise library, the Home tab's category order, routines and favourites,
    /// every exercise's score history, and the settings. Used for both the copy
    /// ProfileSync uploads and the file the profile screen shares.
    mutating func snapshot(_ store: ExerciseStore) {
        exercises = store.exportBundle()
        homeCategoryOrder = HomeCategories.stored
        routines = store.routines
        favourites = store.favourites
        let histories = ScoreHistory.all().mapValues(ScoreHistoryDoc.init)
        scores = histories.isEmpty ? nil : histories
        settings = UserSettings.capturingCurrent(store: store)
    }

    func jsonData() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(self)
    }

    func save() {
        try? jsonData()?.write(to: Self.fileURL, options: .atomic)
    }
}

/// Wraps the profile JSON so the share sheet offers it as a named file.
struct ProfileFile: Transferable {
    var data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("Learn2Sing Profile.json")
    }
}

struct ProfileView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @State private var profile = UserProfile.load()

    /// The full profile as uploaded/shared: the stored fields plus a fresh
    /// snapshot of the exercise library, the Home tab's lists and the scores.
    private var fullProfile: UserProfile {
        var full = profile
        full.snapshot(store)
        return full
    }

    var body: some View {
        Form {
            Section("Username") {
                TextField("Username", text: $profile.username)
                    .autocorrectionDisabled()
            }

            Section("Device") {
                LabeledContent("Device ID") {
                    Text(profile.deviceID.isEmpty ? L("Unavailable") : profile.deviceID)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                ShareLink(
                    item: ProfileFile(data: fullProfile.jsonData() ?? Data()),
                    preview: SharePreview("Learn2Sing Profile")
                ) {
                    Label("Download Profile", systemImage: "square.and.arrow.up")
                }
                .settingHelp(L("Saves your profile as a JSON file using the share sheet."))
            }
        }
        .navigationTitle(L("Profile"))
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
        .onAppear { profile.save() }
        .onChange(of: profile.username) {
            profile.save()
            ProfileSync.shared.scheduleUpload()
            // Also push the new name to the PUBLIC_NAME document the Community
            // tab labels exercises with.
            CommunitySync.shared.scheduleUpload()
        }
    }
}
