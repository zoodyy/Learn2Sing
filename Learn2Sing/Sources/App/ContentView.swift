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
    /// The tab on screen, and the screen another tab has asked for. Held out
    /// there so the selected tab outlasts the tab view being rebuilt when the
    /// layout direction changes (see below), and so a screen on one tab can
    /// send the user to a screen on another.
    @ObservedObject private var navigation = AppNavigation.shared

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView()
            }

            Tab("Exercises", systemImage: "music.mic", value: AppTab.exercises) {
                ExercisesView()
            }

            Tab("Community", systemImage: "person.3", value: AppTab.community) {
                CommunityView()
            }

            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsView()
            }
        }
        // Built again from scratch when the language changes to one read the other
        // way. Forms and lists that already exist don't survive a live change of
        // direction: going back from Arabic to English, every row's text was drawn
        // mirror-image. Only that switch pays for it, with the navigation inside the
        // tabs going back to their first screens; the selected tab stays.
        .id(languages.language.layoutDirection)
        .environmentObject(toasts)
        .environmentObject(languages)
        // Every `Text("…")` in the app resolves its key against this locale, so
        // changing it re-renders the screens that are already on screen — unlike
        // re-identifying the root, which would throw away navigation state.
        .environment(\.locale, languages.language.locale)
        // No `\.layoutDirection` here, although a right-to-left language mirrors the
        // app: that comes from the window scene's trait, which SwiftUI reads too.
        // See `LanguageManager.applyLayoutDirection`.
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
