//
//  BackupSelectionViews.swift
//  Learn2Sing
//
//  The two picking screens Settings ▸ Backup goes through: one chooses which
//  exercises an export file is made of before handing it to the share sheet, the
//  other chooses which of a file's exercises are taken into the library.
//

import SwiftUI
import UIKit

// MARK: - Shared screen

/// What both backup screens are built on: the categorized exercise list of the
/// Exercises tab with a tick circle on every row, and a bar along the bottom
/// carrying how much is ticked, a "Select All"/"Deselect All" button, and the
/// button that acts on the selection.
private struct BackupSelectionScreen: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    let title: String
    let sections: [ExerciseListSection]
    let selectedCount: Int
    let totalCount: Int
    /// A grey line at the top of the bottom bar, for a screen with something to
    /// say about what the button is about to do (the import screen's warning
    /// about the exercises the library already holds). nil leaves it out.
    var note: String? = nil
    let actionTitle: String
    let actionImage: String
    let actionHelp: String
    let onAction: () -> Void
    let onToggle: (UUID) -> Void
    let onToggleCollapse: (String) -> Void
    /// true ticks every exercise, false clears them all.
    let onSelectAll: (Bool) -> Void

    /// Nothing left to tick, so the button offers the other direction.
    private var isEverythingSelected: Bool { selectedCount == totalCount }

    /// How tall the bottom bar measures. Handed to the list as extra room under
    /// its last row: the list ignores the safe area, so the space `safeAreaInset`
    /// holds for the bar is space the list scrolls straight through — without
    /// this the last exercises can't be brought out from under it.
    @State private var barHeight: CGFloat = 0

    var body: some View {
        ExerciseCollectionList(
            sections: sections,
            onSelect: { id, _ in onToggle(id) },
            onToggleCollapse: onToggleCollapse,
            bottomContentInset: barHeight
        )
        // Span the full screen like a List so content scrolls under the
        // navigation and tab bars.
        .ignoresSafeArea()
        // An inset rather than an overlay, so the list scrolls clear of the bar
        // and its last row can be ticked like any other.
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .stableTopEdgeFade()
    }

    /// Select All sits down here beside the count rather than in the navigation
    /// bar, which is where a screen like this usually puts it: both words are
    /// long in most languages, and a trailing bar button leaves the title too
    /// little room to be shown in full ("Übungen expo…").
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack {
                Text(L("%1$d of %2$d selected", selectedCount, totalCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                // Nothing to tick or untick on an empty list, so the button is
                // left off it rather than offered with nothing to act on.
                if totalCount > 0 {
                    Button(isEverythingSelected ? L("Deselect All") : L("Select All")) {
                        onSelectAll(!isEverythingSelected)
                    }
                    .font(.footnote.weight(.semibold))
                    .explain(L("Ticks every exercise at once, or clears them all."))
                }
            }
            Button(action: onAction) {
                Label(actionTitle, systemImage: actionImage)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedCount == 0)
            // Outside `disabled`, so a press-and-hold still explains what the
            // greyed-out button is waiting for.
            .explain(actionHelp)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
    }
}

// MARK: - Export

/// The screen "Export Exercises" opens: the whole library, every exercise ticked,
/// so the file is all of it unless something is unticked. The button writes the
/// file and puts the system share sheet over it — from where it can be sent,
/// copied, or saved to Files.
struct ExerciseExportSelectionView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore

    /// The *un*ticked exercises rather than the ticked ones, so the screen opens
    /// with everything ticked without having to seed state from a store that
    /// isn't reachable until the view is on screen.
    @State private var excluded: Set<UUID> = []
    /// Categories the user has collapsed. Their exercises are hidden and the
    /// header shows the exercise count in parentheses instead — they stay ticked
    /// while out of sight.
    @State private var collapsedCategories: Set<String> = []
    /// Set when the file couldn't be written, and shown in an alert.
    @State private var failure: String?

    private var selectedIDs: Set<UUID> {
        Set(store.exercises.map(\.id)).subtracting(excluded)
    }

    /// Exercises with no category, or whose category was deleted, shown in an
    /// unlabelled section like on the Exercises tab.
    private var uncategorized: [Exercise] {
        store.exercises.filter { $0.category.isEmpty || !store.categories.contains($0.category) }
    }

    private var sections: [ExerciseListSection] {
        func rows(_ exercises: [Exercise]) -> [ExerciseListRow] {
            exercises.map {
                ExerciseListRow(exercise: $0, pattern: store.notes(for: $0.id),
                                isSelected: !excluded.contains($0.id))
            }
        }
        var result: [ExerciseListSection] = []
        for category in store.categories {
            let items = store.exercises.filter { $0.category == category }
            let isCollapsed = collapsedCategories.contains(category)
            result.append(ExerciseListSection(category: category,
                                              isCollapsed: isCollapsed,
                                              totalCount: items.count,
                                              items: isCollapsed ? [] : rows(items)))
        }
        let uncategorized = self.uncategorized
        if !uncategorized.isEmpty {
            result.append(ExerciseListSection(category: "",
                                              isCollapsed: false,
                                              totalCount: uncategorized.count,
                                              items: rows(uncategorized)))
        }
        return result
    }

    var body: some View {
        BackupSelectionScreen(
            title: L("Export Exercises"),
            sections: sections,
            selectedCount: selectedIDs.count,
            totalCount: store.exercises.count,
            actionTitle: L("Export"),
            actionImage: "square.and.arrow.up",
            actionHelp: L("Writes the ticked exercises to a file and opens the share sheet, where you can send it, copy it, or save it to Files."),
            onAction: share,
            onToggle: { id in
                if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
            },
            onToggleCollapse: { category in
                if collapsedCategories.contains(category) {
                    collapsedCategories.remove(category)
                } else {
                    collapsedCategories.insert(category)
                }
            },
            onSelectAll: { all in
                excluded = all ? [] : Set(store.exercises.map(\.id))
            }
        )
        .alert("Exercises", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    /// Write the ticked exercises to a file in the temporary directory and put
    /// the system share sheet up over it.
    private func share() {
        guard let data = store.exportData(ids: selectedIDs) else {
            failure = L("Could not prepare the export file.")
            return
        }
        // The name the share sheet offers, and the one "Save to Files" lands
        // under — the same one the file dialog used to suggest.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(L("Learn2Sing Exercises"))
            .appendingPathExtension("json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            failure = L("Export failed: %@", error.localizedDescription)
            return
        }
        ShareSheet.present(url)
    }
}

// MARK: - Import

/// The screen a chosen import file opens: its exercises in two groups — the ones
/// the library has no copy of, and the ones it already holds, which importing
/// updates to what the file says. Everything starts ticked, so importing without
/// touching anything is the whole file.
struct ExerciseImportSelectionView: View {
    /// Re-renders this screen when the language is changed in Settings; the
    /// strings are resolved when the body runs, so SwiftUI needs telling.
    @ObservedObject private var appLanguage = LanguageManager.shared

    @EnvironmentObject private var store: ExerciseStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss

    /// What the chosen file decoded to.
    let bundle: ExerciseBundle

    /// The *un*ticked exercises — see `ExerciseExportSelectionView.excluded`.
    @State private var excluded: Set<UUID> = []
    @State private var collapsedCategories: Set<String> = []

    /// Section identifiers. They are only ever the diffable list's names for the
    /// two groups; what the headers read is passed as their `displayName`.
    private static let newSection = "new"
    private static let knownSection = "known"

    private var libraryIDs: Set<UUID> { Set(store.exercises.map(\.id)) }

    /// The file's exercises the library has no copy of: importing adds them.
    private var newExercises: [Exercise] {
        let known = libraryIDs
        return bundle.exercises.filter { !known.contains($0.id) }
    }

    /// The file's exercises the library already holds, matched by id — so a
    /// renamed exercise is still recognised as the one it came from. Importing
    /// overwrites the library's copy with the file's.
    private var knownExercises: [Exercise] {
        let known = libraryIDs
        return bundle.exercises.filter { known.contains($0.id) }
    }

    private var selectedIDs: Set<UUID> {
        Set(bundle.exercises.map(\.id)).subtracting(excluded)
    }

    private var sections: [ExerciseListSection] {
        var result: [ExerciseListSection] = []
        let new = newExercises
        if !new.isEmpty {
            result.append(section(id: Self.newSection, name: L("New Exercises"), exercises: new))
        }
        let known = knownExercises
        if !known.isEmpty {
            result.append(section(id: Self.knownSection,
                                  name: L("Already in Your Library"), exercises: known))
        }
        return result
    }

    private func section(id: String, name: String, exercises: [Exercise]) -> ExerciseListSection {
        let isCollapsed = collapsedCategories.contains(id)
        return ExerciseListSection(
            category: id,
            isCollapsed: isCollapsed,
            totalCount: exercises.count,
            items: isCollapsed ? [] : exercises.map { exercise in
                ExerciseListRow(
                    exercise: exercise,
                    // Straight out of the file rather than the library, so the
                    // thumbnail is the pattern that would be imported — looked
                    // up exactly as `ExerciseStore.importBundle` does.
                    pattern: bundle.midi[exercise.id.uuidString] ?? [],
                    isSelected: !excluded.contains(exercise.id))
            },
            displayName: name)
    }

    var body: some View {
        BackupSelectionScreen(
            title: L("Import Exercises"),
            sections: sections,
            selectedCount: selectedIDs.count,
            totalCount: bundle.exercises.count,
            // Only worth saying when the file actually overlaps the library.
            note: knownExercises.isEmpty
                ? nil
                : L("Ticked exercises you already have are replaced by the version in this file."),
            actionTitle: L("Import"),
            actionImage: "square.and.arrow.down",
            actionHelp: L("Adds the ticked new exercises to your library and updates the ticked ones it already has. Everything left unticked is ignored."),
            onAction: runImport,
            onToggle: { id in
                if excluded.contains(id) { excluded.remove(id) } else { excluded.insert(id) }
            },
            onToggleCollapse: { section in
                if collapsedCategories.contains(section) {
                    collapsedCategories.remove(section)
                } else {
                    collapsedCategories.insert(section)
                }
            },
            onSelectAll: { all in
                excluded = all ? [] : Set(bundle.exercises.map(\.id))
            }
        )
    }

    /// Merge the ticked exercises into the library and go back to the Backup
    /// screen. The confirmation is a toast rather than an alert because it
    /// outlives this screen being popped (see `ToastCenter`).
    private func runImport() {
        let selected = selectedIDs
        guard !selected.isEmpty else { return }
        store.importBundle(bundle.filtered(to: selected))
        toasts.show(L("Exercises Imported!"))
        dismiss()
    }
}

// MARK: - Share sheet

/// The system share sheet, put up over whatever is on screen. `ShareLink` would
/// want the file to exist before the button is drawn, and the export builds it
/// from the ticked exercises when the button is pressed — so it is presented by
/// hand instead.
enum ShareSheet {
    static func present(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
            let root = scene.keyWindow?.rootViewController
        else { return }
        // Anything already presented (an alert, a sheet) owns the screen; the
        // share sheet has to come up over that rather than over the root.
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // On iPad this is a popover, which is refused without something to point
        // at: the bottom of the screen, where the button that opened it sits.
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60,
                                        width: 0, height: 0)
            popover.permittedArrowDirections = .down
        }
        top.present(controller, animated: true)
    }
}
