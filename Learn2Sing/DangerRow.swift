import SwiftUI

extension View {
    /// Makes a destructive row read as one colour: red icon, red title.
    ///
    /// `Button(role: .destructive)` only turns the row's *title* red. A `Label`'s
    /// icon carries on taking the app's accent colour, so a delete row came out
    /// as a pink glyph next to red text. Setting the foreground style is what
    /// recolours the icon — the same way `SettingsHubRow` pulls its icons back
    /// to primary. (`.tint(.red)` does not: the icon keeps the accent colour.)
    ///
    /// Rows that are `.disabled()` when there's nothing to delete are left
    /// alone, since those aren't drawn in red to begin with.
    ///
    /// Only needed in a Form or List: in a Menu the destructive role already
    /// colours the whole item.
    func dangerRow() -> some View {
        modifier(DangerRow())
    }
}

private struct DangerRow: ViewModifier {
    /// Reads the `.disabled(…)` the counted Reset rows apply *outside* this
    /// modifier: the environment it sets reaches the content within.
    @Environment(\.isEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.foregroundStyle(.red)
        } else {
            content
        }
    }
}
