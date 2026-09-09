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
//  The same bubble goes up unasked for exactly once, to point out something a
//  singer would otherwise have to stumble on: see `presentHint` and CategoryHint.
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

    /// The SwiftUI bubble is 260pt wide plus its padding; asking the hosting
    /// controller what that comes to keeps the two the same size.
    private static let bubbleWidth: CGFloat = 260 + 32

    static func present(_ text: String, from view: UIView) {
        // Presenting from a controller that already has something up throws,
        // so the bubble simply doesn't appear while it does.
        guard let presenter = view.owningViewController,
              presenter.presentedViewController == nil,
              presenter.view.window != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let host = bubbleController(text)
        if let popover = host.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = KeepAsPopover.shared
        }
        presenter.present(host, animated: true)
    }

    /// The bubble itself, sized and cleared of its own background, ready to be
    /// pointed at something.
    private static func bubbleController(_ text: String) -> UIViewController {
        let host = UIHostingController(rootView: SettingHelpText(text: text)
            .environment(\.locale, LanguageManager.shared.language.locale))
        host.modalPresentationStyle = .popover
        host.preferredContentSize = host.sizeThatFits(
            in: CGSize(width: bubbleWidth, height: .greatestFiniteMagnitude))
        // The bubble is read, not used: nothing in it is tappable, so a tap
        // anywhere puts it away like the SwiftUI one.
        host.view.backgroundColor = .clear
        return host
    }

    // MARK: One-off hint

    /// The hint that is up, holding the popover's delegate and the view that
    /// decides when it goes. A popover holds its delegate weakly, so something has
    /// to hold it, and only ever one hint is on screen at a time.
    fileprivate static var hint: HintBubble?

    /// The same bubble, put up by the app rather than by a press: the one-off hint
    /// the exercise list points at a category name (see CategoryHint). False when
    /// there was nothing to present from, so a hint that couldn't be given waits
    /// for a better moment instead of counting itself as given.
    ///
    /// How it goes away is the one thing that differs from a held-down explanation,
    /// because this one arrived unasked for. A popover leaves of its own accord as
    /// soon as anything outside it is touched, and the touch that begins a scroll is
    /// one of those: a singer who opened the tab and flicked the list on autopilot
    /// would have lost the hint without ever reading it. So everything under it is
    /// inert while it is up, and only a tap — a touch that ends where it began —
    /// puts it away.
    @discardableResult
    static func presentHint(_ text: String, from view: UIView) -> Bool {
        guard hint == nil, let presenter = view.owningViewController,
              let window = presenter.view.window
        else { return false }
        // Presenting from a controller whose ancestor already has something up
        // fails, and a hint that never appeared must not count as given — so the
        // whole chain is asked, not just the controller presenting it.
        var ancestor: UIViewController? = presenter
        while let controller = ancestor {
            guard controller.presentedViewController == nil else { return false }
            ancestor = controller.parent
        }

        let host = bubbleController(text)
        // Refuses the dismissal UIKit would do by itself on a touch outside, for
        // the moment between this and the catcher going up.
        host.isModalInPresentation = true
        guard let popover = host.popoverPresentationController else { return false }
        popover.sourceView = view
        popover.sourceRect = view.bounds
        popover.permittedArrowDirections = [.up, .down]

        let bubble = HintBubble(host: host)
        popover.delegate = bubble
        hint = bubble
        presenter.present(host, animated: true) { bubble.catchTouches(in: window) }
        return true
    }
}

/// The one-off hint's popover while it is up: the delegate that keeps it from
/// putting itself away, and the clear view over the window that does.
private final class HintBubble: NSObject, UIPopoverPresentationControllerDelegate {
    private weak var host: UIViewController?
    private weak var catcher: UIView?

    init(host: UIViewController) {
        self.host = host
    }

    /// A bubble on iPhone too, exactly as `KeepAsPopover` keeps the held-down one.
    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    /// Nothing puts the hint away but a tap on the catcher.
    func presentationControllerShouldDismiss(_ controller: UIPresentationController) -> Bool { false }

    /// Should it ever be dismissed from elsewhere all the same, let go of it as if
    /// it had been tapped away, so a later hint isn't blocked by one that has gone.
    func presentationControllerDidDismiss(_ controller: UIPresentationController) {
        catcher?.removeFromSuperview()
        SettingHelpBubble.hint = nil
    }

    /// Lay the catcher over the whole window — above the bubble, which is presented
    /// by now — so every touch on the screen is the hint's to answer.
    func catchTouches(in window: UIWindow) {
        let catcher = HintTouchCatcher(frame: window.bounds)
        catcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        catcher.onTap = { [weak self] in self?.dismiss() }
        window.addSubview(catcher)
        self.catcher = catcher
    }

    private func dismiss() {
        catcher?.removeFromSuperview()
        host?.dismiss(animated: true)
        SettingHelpBubble.hint = nil
    }
}

/// A clear view over everything while the hint is up. It takes every touch, so the
/// list underneath doesn't scroll, rearrange or open anything while the bubble is
/// being read, and it reports only the touches that are a tap: one that ends where
/// it began. A flick deliberately isn't one — the hint is answered by a tap, so it
/// can't be skipped by a scroll nobody meant as an answer to it.
private final class HintTouchCatcher: UIView {
    var onTap: (() -> Void)?

    /// Where the touch went down, or nil once it has travelled far enough to be a
    /// drag rather than a tap.
    private var origin: CGPoint?

    /// How far a finger may travel and still count as a tap: the same slop UIKit's
    /// own tap recognizer allows.
    private let allowedMovement: CGFloat = 10

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        origin = touches.first?.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let start = origin, let point = touches.first?.location(in: self) else { return }
        if hypot(point.x - start.x, point.y - start.y) > allowedMovement { origin = nil }
    }

    /// A press that ends without having moved, however long it was held. Held down
    /// counts: the hint asks to be tapped away, not to be tapped away quickly.
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let wasTap = origin != nil
        origin = nil
        if wasTap { onTap?() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        origin = nil
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
