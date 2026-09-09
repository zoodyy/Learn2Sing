import SwiftUI

/// Replacement for the system's soft top scroll-edge effect (the fade applied to
/// list content scrolling under the navigation bar).
///
/// The system effect has an iOS 26 bug (FB21804922): during a TabView tab
/// switch it is torn down on the outgoing tab a few frames before the new tab
/// is shown, so faded rows flash to full opacity. This modifier hides the
/// system effect and draws an equivalent fade as an overlay that lives in the
/// tab's own view hierarchy, so it stays put through the transition.
///
/// Apply to the scrollable content of a screen, inside its NavigationStack, so
/// the fade renders below the navigation bar's title and buttons.
struct StableTopEdgeFade: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    let background = Color(uiColor: .systemGroupedBackground)
                    // Approximates the system soft edge: strong wash across the
                    // status bar and navigation bar, easing out below them.
                    LinearGradient(
                        stops: [
                            .init(color: background, location: 0),
                            .init(color: background.opacity(0.95), location: 0.55),
                            .init(color: background.opacity(0.55), location: 0.8),
                            .init(color: background.opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: geo.safeAreaInsets.top + 24)
                    .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    func stableTopEdgeFade() -> some View {
        modifier(StableTopEdgeFade())
    }
}
