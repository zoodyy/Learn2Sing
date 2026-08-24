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
    /// How long was practised on each day — what the Home tab's calendar draws —
    /// as day number and seconds interleaved, `[d₀, s₀, d₁, s₁, …]`. Optional so
    /// profiles written before the calendar existed still decode.
    var practice: [Int]? = nil
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
    /// every exercise's score history, the practice calendar, and the settings.
    /// Used for both the copy ProfileSync uploads and the file the profile
    /// screen shares.
    mutating func snapshot(_ store: ExerciseStore) {
        exercises = store.exportBundle()
        homeCategoryOrder = HomeCategories.stored
        routines = store.routines
        favourites = store.favourites
        let histories = ScoreHistory.all().mapValues(ScoreHistoryDoc.init)
        scores = histories.isEmpty ? nil : histories
        practice = PracticeLog.doc()
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
    @State private var profile: UserProfile
    /// What the username field shows, which is not the same thing as the name
    /// this user has: a typed name only moves into the profile once the server
    /// has taken it (see `commitUsername`).
    @State private var typedUsername: String
    /// A rename the server refused, if any. The message is shown only while the
    /// field still holds that name, so editing it away clears the message and
    /// typing it back brings it up again without another call.
    @State private var refusedUsername: RefusedUsername?
    /// The name currently on the wire, so one rename isn't posted twice: leaving
    /// the screen resigns the field's focus *and* dismisses the view, and either
    /// on its own is reason enough to commit.
    @State private var claimingUsername: String?
    @FocusState private var isEditingUsername: Bool

    /// A refused rename: the name as typed, so the message can follow the field,
    /// and the name the server named in its error, which is what it shows. The
    /// two differ if the server ever matches names less strictly than byte for
    /// byte — the taken name it reports is the one worth naming.
    private struct RefusedUsername {
        var typed: String
        var reported: String
    }

    init() {
        let profile = UserProfile.load()
        _profile = State(initialValue: profile)
        _typedUsername = State(initialValue: profile.username)
    }

    /// The full profile as uploaded/shared: the stored fields plus a fresh
    /// snapshot of the exercise library, the Home tab's lists and the scores.
    private var fullProfile: UserProfile {
        var full = profile
        full.snapshot(store)
        return full
    }

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $typedUsername)
                    .autocorrectionDisabled()
                    .focused($isEditingUsername)
                    .onSubmit { commitUsername() }
            } header: {
                Text("Username")
            } footer: {
                if let refused = refusedUsername, refused.typed == typedUsername {
                    Text(L("Username \"%@\" is not available", refused.reported))
                        .foregroundStyle(.red)
                }
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
        // Swiping down over the keyboard puts it away, like everywhere else.
        .scrollDismissesKeyboard(.interactively)
        .onAppear { profile.save() }
        // A rename is checked when it is finished rather than per keystroke: a
        // name passes through other people's names while being typed, and the
        // check is a POST that takes the name it asks about.
        .onChange(of: isEditingUsername) { _, editing in
            if !editing { commitUsername() }
        }
        // Leaving with the keyboard still up finishes the rename too.
        .onDisappear { commitUsername() }
    }

    /// Offers the typed name to the server, which is what decides whether it is
    /// free — there is no separate check, the POST that claims a name is the
    /// same one that finds out (see `CommunitySync.claimUsername(_:)`). Only a
    /// name the server takes is saved, so one somebody else already has never
    /// becomes this user's: the field goes on showing it, with the message
    /// underneath, until it is edited into a name that is free.
    private func commitUsername() {
        let name = typedUsername
        guard name != profile.username else {
            refusedUsername = nil
            return
        }
        // Already asked about this one: it is either on the wire or known taken.
        guard name != claimingUsername, name != refusedUsername?.typed else { return }
        claimingUsername = name
        Task {
            let result = await CommunitySync.shared.claimUsername(name)
            // A later edit asked about a different name while this one was on
            // the wire; that one owns the field and the message now.
            guard claimingUsername == name else { return }
            claimingUsername = nil
            switch result {
            case .accepted:
                refusedUsername = nil
                save(username: name)
            case .taken(let taken):
                refusedUsername = RefusedUsername(typed: name, reported: taken)
            case .failed:
                // No answer either way, so nothing to hold against the name:
                // renaming offline works as it always did, and the name is
                // re-posted on the next upload and every launch until it lands.
                refusedUsername = nil
                save(username: name)
            }
        }
    }

    /// Puts an accepted name in the profile file and sends it on to the server's
    /// copy of the profile. Written onto a freshly loaded profile rather than
    /// this screen's snapshot, which the Community tab may have added a like or
    /// a download to since it was taken.
    private func save(username: String) {
        var stored = UserProfile.load()
        stored.username = username
        stored.save()
        profile.username = username
        ProfileSync.shared.scheduleUpload()
    }
}
