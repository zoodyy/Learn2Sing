//
//  ContentView.swift
//  Learn2Sing
//
//  Created by Artoem Liebert on 23.06.26.
//

import SwiftUI

struct ContentView: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            ExercisesView()
                .tabItem {
                    Label("Exercises", systemImage: "music.mic")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
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
