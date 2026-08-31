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
    /// Observed here so picking a language in Settings repaints the whole tree.
    @StateObject private var languages = LanguageManager.shared
    /// The introduction: it opens itself on the first launch, and the Settings row
    /// that replays it opens it from the other side of the tab view — so it is
    /// presented here, over every tab, rather than from any one of them.
    @ObservedObject private var tutorial = IntroTutorial.shared

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
        .environmentObject(languages)
        // Every `Text("…")` in the app resolves its key against this locale, so
        // changing it re-renders the screens that are already on screen — unlike
        // re-identifying the root, which would throw away navigation state.
        .environment(\.locale, languages.language.locale)
        .overlay { ToastOverlay(toasts: toasts) }
        // nil for "System" lets the device's light/dark setting through.
        .preferredColorScheme((AppTheme(rawValue: themeRaw) ?? .system).colorScheme)
        // Re-assert the stored orientation lock once the scene is live, so a lock
        // set in a previous run is enforced from launch.
        .onAppear { OrientationLockManager.apply(.current) }
        // Over every tab, and over the tab bar. It sets the language and the
        // appearance again for itself: neither the locale nor the colour scheme set
        // above reaches a presentation — see `IntroTutorialView.body`.
        .fullScreenCover(isPresented: $tutorial.isPresented) { IntroTutorialView() }
        // In a task rather than in `onAppear`, so the first launch's tutorial is
        // asked for after the first frame instead of during it.
        .task { tutorial.presentIfNeeded() }
    }
}


#Preview {
    ContentView()
}
