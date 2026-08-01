import SwiftUI
import Combine

/// Default toast symbol, used by every message that confirms something happened.
nonisolated let confirmationIcon = "checkmark.circle.fill"

/// App-wide "Saved!" confirmation HUD. Screens that autosave call `show(_:)`
/// when they're left; the overlay at the app root renders the message, so the
/// toast survives the screen that triggered it being popped off the stack.
@MainActor
final class ToastCenter: ObservableObject {
    @Published private(set) var message: String?
    /// Symbol shown beside the current message — a checkmark confirms, anything
    /// else is passed in by the caller.
    @Published private(set) var icon = confirmationIcon
    private var hideTask: Task<Void, Never>?
    private var isNextSuppressed = false

    /// How long a toast stays up. Overridable because UI-test queries only run
    /// once the app goes idle, which can outlast the default window.
    private let displayDuration = ProcessInfo.processInfo
        .environment["TOAST_SECONDS"].flatMap(Double.init) ?? 1.5

    func show(_ message: String, icon: String = confirmationIcon) {
        if isNextSuppressed {
            isNextSuppressed = false
            return
        }
        hideTask?.cancel()
        self.icon = icon
        self.message = message
        hideTask = Task {
            try? await Task.sleep(for: .seconds(displayDuration))
            guard !Task.isCancelled else { return }
            self.message = nil
        }
    }

    /// Swallows the next `show`. Called right before a dismissal whose pop
    /// would otherwise confirm a save — deleting an exercise from its settings
    /// screen — since the pop itself is only observable after the fact.
    func suppressNext() {
        isNextSuppressed = true
    }

    /// Watches a navigation path for pops of the screens that autosave. Called
    /// from the `onChange` of each tab's typed path; pushes (the path grew) do
    /// nothing. If several screens pop at once the outermost one wins.
    func routesPopped(from old: [ExerciseRoute], to new: [ExerciseRoute]) {
        guard new.count < old.count else { return }
        for route in old[new.count...] {
            switch route {
            case .settings:
                show(L("Exercise Saved!"))
                return
            case .edit:
                show(L("Midi Saved!"))
                return
            default:
                continue
            }
        }
    }
}

/// Small centered capsule showing the current toast message. Layered over the
/// whole app (see ContentView) and transparent to touches.
struct ToastOverlay: View {
    @ObservedObject var toasts: ToastCenter

    var body: some View {
        ZStack {
            if let message = toasts.message {
                Label(message, systemImage: toasts.icon)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toasts.message)
        .allowsHitTesting(false)
    }
}
