//
//  ContentView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

struct ContentView: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    /// Renders "Saved!" confirmations above every tab, so they outlive the
    /// screen (settings / MIDI editor) whose pop triggered them.
    @StateObject private var toasts = ToastCenter()

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView()
            }

            Tab("Exercises", systemImage: "music.mic") {
                ExercisesView()
            }

            Tab("Community", systemImage: "person.3") {
                CommunityView()
            }

            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .environmentObject(toasts)
        .overlay { ToastOverlay(toasts: toasts) }
        // nil for "System" lets the device's light/dark setting through.
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
        // Re-assert the stored orientation lock once the scene is live, so a lock
        // set in a previous run is enforced from launch.
        .onAppear { OrientationLockManager.apply(.current) }
    }
}


#Preview {
    ContentView()
}
