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

    func body(content: Content) -> some View {
        content
            // Simultaneous so the hold doesn't swallow the row's own tap
            // (opening a picker, following a link, toggling a switch).
            .simultaneousGesture(
                LongPressGesture().onEnded { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isShowing = true
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
