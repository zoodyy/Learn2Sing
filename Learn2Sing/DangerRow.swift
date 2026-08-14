import SwiftUI

extension View {
    /// Makes a destructive row read as one colour: red icon, red title — or one
    /// grey when the row is disabled.
    ///
    /// `Button(role: .destructive)` only turns the row's *title* red. A `Label`'s
    /// icon carries on taking the app's accent colour, so a delete row came out
    /// as a pink glyph next to red text. Setting the foreground style is what
    /// recolours the icon — the same way `SettingsHubRow` pulls its icons back
    /// to primary. (`.tint(.red)` does not: the icon keeps the accent colour.)
    ///
    /// A row that's `.disabled()` because there's nothing to delete drops the
    /// destructive red on its own, but the icon still takes the accent colour
    /// and the title the primary one — so the row a user *can't* use came out
    /// looking brighter than the ones they can. Greying the whole row is what
    /// says it's unavailable, and puts it in the same grey as the count on its
    /// trailing edge.
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

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
    }
}
