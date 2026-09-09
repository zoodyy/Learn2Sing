import SwiftUI

@main
struct Learn2SingApp: App {
    // Installs the UIKit app delegate that reports the orientation-lock mask.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ExerciseStore()
    // Created at launch so the bundled templates are seeded, and the one matching the
    // app's appearance applied, before any playback — making it the starting look
    // rather than only after the visuals settings screen is first opened.
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
                    // Before either sync: a "Delete Everything" that ran out of
                    // network still owes the server four deletions, and an
                    // upload beating them there would put back the very record
                    // being deleted. Costs nothing when none is pending.
                    await DeleteEverything.finishPendingWipe()
                    await ProfileSync.shared.start(with: store, templates: visualTemplates)
                    // Between the two: the singer's level is worked out from the
                    // scores the restore brings back and the difficulties
                    // community sync fetches, so it reads what is already on the
                    // device here and is asked again once those land.
                    SkillLevelStore.shared.start(with: store)
                    await CommunitySync.shared.start(with: store)
                }
        }
    }
}
