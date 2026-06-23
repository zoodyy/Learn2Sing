import SwiftUI

struct EditingView: View {
    var exercise: Exercise? = nil

    var body: some View {
        Text(exercise?.name ?? "No exercise selected")
            .navigationTitle(exercise?.name ?? "Editing")
    }
}
