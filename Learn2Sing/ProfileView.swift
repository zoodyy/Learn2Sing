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

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile.json")
    }

    /// Loads the stored profile (or a fresh one) and stamps in the device ID,
    /// a UUID kept in the Keychain so it survives reinstalls.
    static func load() -> UserProfile {
        var profile = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) }
            ?? UserProfile()
        profile.deviceID = DeviceIdentifier.uuidString
        return profile
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
    @EnvironmentObject private var store: ExerciseStore
    @State private var profile = UserProfile.load()

    /// The full profile as uploaded/shared: the stored fields plus a fresh
    /// snapshot of the exercise library.
    private var fullProfile: UserProfile {
        var full = profile
        full.exercises = store.exportBundle()
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
                    Text(profile.deviceID.isEmpty ? "Unavailable" : profile.deviceID)
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
            } footer: {
                Text("Saves your profile as a JSON file using the share sheet.")
            }
        }
        .navigationTitle("Profile")
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
