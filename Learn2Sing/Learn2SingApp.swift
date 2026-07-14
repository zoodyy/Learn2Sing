import SwiftUI

@main
struct Learn2SingApp: App {
    // Installs the UIKit app delegate that reports the orientation-lock mask.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ExerciseStore()
    // Created at launch so the bundled default template is seeded and applied before
    // any playback, making it the starting look rather than only after the visuals
    // settings screen is first opened.
    @StateObject private var visualTemplates = VisualTemplateStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(visualTemplates)
                // Restore the profile from the server on a fresh install, then
                // keep the server copy in sync as the user edits. Community
                // sync starts after the restore so a fresh install shares its
                // restored public exercises instead of an empty list.
                .task {
                    await ProfileSync.shared.start(with: store)
                    await CommunitySync.shared.start(with: store)
                }
        }
    }
}
