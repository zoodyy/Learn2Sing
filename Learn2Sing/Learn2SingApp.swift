import SwiftUI

@main
struct Learn2SingApp: App {
    @StateObject private var store = ExerciseStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
