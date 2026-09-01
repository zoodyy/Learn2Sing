//
//  SettingHelp.swift
//  Learn2Sing
//
//  Press-and-hold help. The short explanations that used to sit in section
//  footers are attached to the thing they describe with `.settingHelp(_:)` (a
//  settings row) or `.explain(_:)` (anything else — a toolbar button, a card, a
//  chart, a picture), and surface in a popover only while the user holds down on
//  it. The tutorial's last slide is what tells the user this is there.
//

import SwiftUI
import UIKit

extension View {
    /// Shows `text` in a popover when the row is long-pressed. Used across the
    /// settings screens (and the per-exercise settings) in place of the section
    /// footers that previously described each setting inline.
    func settingHelp(_ text: String) -> some View {
        modifier(SettingHelpModifier(text: text, fillsRow: true))
    }

    /// The same hold and the same bubble for everything that isn't a settings
    /// row: buttons in a toolbar, the Home tab's cards, a chart, a picture. The
    /// view keeps whatever size it had, since stretching one of those across the
    /// width it sits in would move it.
    func explain(_ text: String) -> some View {
        modifier(SettingHelpModifier(text: text, fillsRow: false))
    }
}

private struct SettingHelpModifier: ViewModifier {
    let text: String
    /// True for a settings row, which is held anywhere along its width; false
    /// for anything laid out beside something else, where filling the row would
    /// push its neighbours around.
    let fillsRow: Bool

    @State private var isShowing = false
    /// Bumped when a hold is recognised to give the row a new identity, which
    /// tears the control down and rebuilds it — cancelling the touch that's in
    /// flight so the release doesn't complete as a tap on it.
    @State private var resetToken = 0

    func body(content: Content) -> some View {
        target(content)
            // Hit-test the whole rectangle so the hold works anywhere on the
            // target, not just where it has drawn something.
            .contentShape(Rectangle())
            // Simultaneous so a quick tap still reaches the row's own control
            // (opening a picker, following a link, toggling a switch); the hold
            // is distinguished from a tap by the minimum duration.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    resetToken += 1
                    // A beat after the rebuild, not during it. A `Menu` opens on
                    // touch down, so by the time a hold on one is recognised its
                    // menu is already up and a popover asked for now is simply
                    // refused — the rebuild above is what puts that menu away,
                    // and the bubble can only be presented once it has gone.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isShowing = true
                    }
                }
            )
            .popover(isPresented: $isShowing) {
                SettingHelpText(text: text)
            }
            // Keep the explanation available to VoiceOver now that the visible
            // footer is gone.
            .accessibilityHint(text)
    }

    /// The view the hold is attached to. `fillsRow` never changes for a given
    /// call site, so the branch costs the content no identity.
    @ViewBuilder
    private func target(_ content: Content) -> some View {
        // New identity on each hold cancels the underlying control's active
        // touch; without it, releasing after the hold lands as a tap on the
        // control (e.g. flipping a Toggle).
        let base = content.id(resetToken)
        if fillsRow {
            // Fill the row so the hold works anywhere along it, not just on the
            // label at the leading edge.
            base.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            base
        }
    }
}

/// What the bubble holds. Its own view so the UIKit side below shows exactly the
/// same thing at exactly the same width.
private struct SettingHelpText: View {
    let text: String

    var body: some View {
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
}

// MARK: - UIKit

/// The same bubble for the controls that aren't SwiftUI: the + button in an
/// exercise list's section header, which lives in a UICollectionView (see
/// ExerciseCollectionList). Presented as a real popover anchored to the control,
/// the way `.popover` anchors to its row.
enum SettingHelpBubble {
    /// A popover adapts to a full-height sheet on iPhone unless something says
    /// otherwise; SwiftUI's `.presentationCompactAdaptation(.popover)` is what
    /// says it on the other side, and this is the UIKit spelling of it.
    private final class KeepAsPopover: NSObject, UIPopoverPresentationControllerDelegate {
        static let shared = KeepAsPopover()
        func adaptivePresentationStyle(for controller: UIPresentationController,
                                       traitCollection: UITraitCollection) -> UIModalPresentationStyle {
            .none
        }
    }

    static func present(_ text: String, from view: UIView) {
        // Presenting from a controller that already has something up throws,
        // so the bubble simply doesn't appear while it does.
        guard let presenter = view.owningViewController,
              presenter.presentedViewController == nil,
              presenter.view.window != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let host = UIHostingController(rootView: SettingHelpText(text: text)
            .environment(\.locale, LanguageManager.shared.language.locale))
        host.modalPresentationStyle = .popover
        // The SwiftUI bubble is 260pt wide plus its padding; asking the hosting
        // controller what that comes to keeps the two the same size.
        let bubbleWidth: CGFloat = 260 + 32
        host.preferredContentSize = host.sizeThatFits(
            in: CGSize(width: bubbleWidth, height: .greatestFiniteMagnitude))
        // The bubble is read, not used: nothing in it is tappable, so a tap
        // anywhere puts it away like the SwiftUI one.
        host.view.backgroundColor = .clear
        if let popover = host.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = KeepAsPopover.shared
        }
        presenter.present(host, animated: true)
    }
}

private extension UIView {
    /// The view controller this view is in, found by walking the responder
    /// chain — what a popover has to be presented from.
    var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController { return controller }
            responder = next
        }
        return nil
    }
}
