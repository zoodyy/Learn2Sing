//
//  SettingHelp.swift
//  Learn2Sing
//
//  Press-and-hold help for settings rows. The short explanations that used to sit
//  in section footers are attached to their row with `.settingHelp(_:)` instead,
//  and surface in a popover only while the user holds down on that row.
//

import SwiftUI
import UIKit

extension View {
    /// Shows `text` in a popover when the row is long-pressed. Used across the
    /// settings screens (and the per-exercise settings) in place of the section
    /// footers that previously described each setting inline.
    func settingHelp(_ text: String) -> some View {
        modifier(SettingHelpModifier(text: text))
    }
}

private struct SettingHelpModifier: ViewModifier {
    let text: String
    @State private var isShowing = false
    /// Bumped when a hold is recognised to give the row a new identity, which
    /// tears the control down and rebuilds it — cancelling the touch that's in
    /// flight so the release doesn't complete as a tap on it.
    @State private var resetToken = 0

    func body(content: Content) -> some View {
        content
            // New identity on each hold cancels the underlying control's active
            // touch; without it, releasing after the hold lands as a tap on the
            // control (e.g. flipping a Toggle).
            .id(resetToken)
            // Fill the row and hit-test the whole rectangle so the hold works
            // anywhere on the row, not just on the label at the leading edge.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Simultaneous so a quick tap still reaches the row's own control
            // (opening a picker, following a link, toggling a switch); the hold
            // is distinguished from a tap by the minimum duration.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isShowing = true
                    resetToken += 1
                }
            )
            .popover(isPresented: $isShowing) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260)
                    .padding()
                    // `.fitted` sizes the popover to its content's height; without
                    // it the compact-adaptation popover keeps a fixed height and
                    // clips long text at the top and bottom.
                    .presentationSizing(.fitted)
                    .presentationCompactAdaptation(.popover)
            }
            // Keep the explanation available to VoiceOver now that the visible
            // footer is gone.
            .accessibilityHint(text)
    }
}
