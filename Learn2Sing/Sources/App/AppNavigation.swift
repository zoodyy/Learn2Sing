//
//  AppNavigation.swift
//  Learn2Sing
//

import Foundation
import Combine

/// The app's tabs, by the value each is selected with.
enum AppTab: Hashable {
    case home
    case exercises
    case community
    case settings
}

/// Which tab is on screen, and where one tab sends the user when what they need
/// is on another one.
///
/// Each tab keeps its own navigation stack, so a screen can only push onto the
/// stack it is already on: the exercise settings screen asking for Settings ▸
/// Profile — which is what a publish with no username does — is a tab switch
/// *and* a push. The switch is made here, where `ContentView` reads the selected
/// tab from; the screen is left waiting for `SettingsView`, which owns the stack
/// it goes on and may not even have been built yet (a tab never opened has no
/// stack to push onto).
///
/// The selected tab lives here rather than in `ContentView` for the same reason
/// it used to live in a `@State` of its own: the tab view is built again from
/// scratch when the layout direction changes, and the tab the user was on
/// outlasts it.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()

    /// The tab on screen, which the tab view binds to.
    @Published var selectedTab: AppTab = .home

    /// The Settings screen another tab has asked for, cleared by the Settings
    /// tab once it has pushed it.
    @Published var pendingSettingsScreen: SettingsScreen?

    private init() {}

    /// Sends the user to `screen` on the Settings tab, wherever they are now.
    func openSettings(_ screen: SettingsScreen) {
        pendingSettingsScreen = screen
        selectedTab = .settings
    }
}
