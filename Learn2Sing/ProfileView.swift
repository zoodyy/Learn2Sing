//
//  ProfileView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 05.07.26.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The user's profile, persisted as JSON in the app's documents directory.
struct UserProfile: Codable {
    var username: String = ""
    var deviceID: String = ""

    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("profile.json")
    }

    /// Loads the stored profile (or a fresh one) and stamps in the current
    /// device ID, which can change when the app is reinstalled.
    static func load() -> UserProfile {
        var profile = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) }
            ?? UserProfile()
        if let vendorID = UIDevice.current.identifierForVendor?.uuidString {
            profile.deviceID = vendorID
        }
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
    @State private var profile = UserProfile.load()

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
                    item: ProfileFile(data: profile.jsonData() ?? Data()),
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
        .onChange(of: profile.username) { profile.save() }
    }
}
