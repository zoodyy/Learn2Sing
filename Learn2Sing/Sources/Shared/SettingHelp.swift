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

    /// The same hold for a toolbar button whose label is a `Label`. Goes on the
    /// screen, not on the button: SwiftUI turns such a button into a native bar
    /// button and drops the modifiers on it, `explain` with its hold, so this hold
    /// is UIKit's and finds its button by title. `title` is the `Label`'s title as it
    /// shows, `L("See Score")` for `Label("See Score", …)`.
    ///
    /// A bare `Image` or `Text` label would take `explain` itself, but it would be
    /// hosted as a custom view that answers only on the label and not across its
    /// glass (see ToolbarHitArea), which a native button does.
    func explainBarButton(_ title: String, _ text: String) -> some View {
        background(BarButtonHelpAnchor(title: title, text: text))
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
        present(text, presenter: view.owningViewController) { popover in
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
    }

    /// The bubble pointing at a native bar button, which has no view of its own
    /// to present from; `bar` is the bar it sits in.
    static func present(_ text: String, from item: UIBarButtonItem, in bar: UIView) {
        present(text, presenter: bar.owningViewController) { $0.sourceItem = item }
    }

    private static func present(_ text: String, presenter: UIViewController?,
                                anchor: (UIPopoverPresentationController) -> Void) {
        // Presenting from a controller that already has something up throws,
        // so the bubble simply doesn't appear while it does.
        guard let presenter,
              presenter.presentedViewController == nil,
              presenter.view.window != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let host = bubbleController(text)
        if let popover = host.popoverPresentationController {
            anchor(popover)
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

// MARK: - Native bar buttons

/// Where `explainBarButton` puts its text: an empty view behind the screen, which
/// is how the hold on the navigation bar finds out what the screen showing now
/// has to say about its buttons.
private struct BarButtonHelpAnchor: UIViewRepresentable {
    let title: String
    let text: String

    func makeUIView(context: Context) -> BarButtonHelpAnchorView {
        let view = BarButtonHelpAnchorView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BarButtonHelpAnchorView, context: Context) {
        view.title = title
        view.text = text
    }
}

private final class BarButtonHelpAnchorView: UIView {
    var title = ""
    var text = ""

    /// Every anchor in a window. Weak, so a screen that goes away takes its
    /// explanations with it.
    static let onScreen = NSHashTable<BarButtonHelpAnchorView>.weakObjects()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            Self.onScreen.remove(self)
            return
        }
        Self.onScreen.add(self)
        guard let bar = owningViewController?.navigationController?.navigationBar,
              !(bar.gestureRecognizers ?? []).contains(where: { $0 is BarButtonHelpGesture })
        else { return }
        bar.addGestureRecognizer(BarButtonHelpGesture())
    }

    /// Whether this anchor is on the screen that `item` is the bar's item for.
    /// The toolbar lands on the controller hosting the screen, but a parent is
    /// asked too rather than relying on that.
    func explains(_ item: UINavigationItem) -> Bool {
        guard let controller = owningViewController else { return false }
        return sequence(first: controller, next: \.parent).contains { $0.navigationItem === item }
    }
}

/// The hold on a navigation bar, one per bar, answering only for the native
/// buttons a screen has explained. A touch anywhere else is never even seen, so
/// the bar's other buttons, and the SwiftUI-hosted ones with their own hold,
/// behave as before.
///
/// Recognising takes the touch away from the button, as UIKit does for any
/// gesture that wins, so the release isn't also a tap on it.
private final class BarButtonHelpGesture: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
    /// The button under the touch being watched, and what to say about it.
    private var pending: (item: UIBarButtonItem, text: String)?

    init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(recognized))
        // The same hold as `explain`'s LongPressGesture.
        minimumPressDuration = 0.4
        delegate = self
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        pending = nil
        guard let bar = view as? UINavigationBar, let navigationItem = bar.topItem,
              let item = Self.button(under: touch, of: navigationItem, in: bar),
              let title = item.title,
              let anchor = BarButtonHelpAnchorView.onScreen.allObjects
                .first(where: { $0.title == title && $0.explains(navigationItem) })
        else { return false }
        pending = (item, anchor.text)
        return true
    }

    /// The native button a touch landed on. UIKit's own hit test has already
    /// picked the button's view, which takes touches across its whole glass and
    /// not only inside the box it reports, so the item is the one whose box that
    /// view sits in.
    private static func button(under touch: UITouch, of navigationItem: UINavigationItem,
                               in bar: UIView) -> UIBarButtonItem? {
        var view = touch.view
        while let candidate = view, !(candidate is UIControl) {
            guard candidate !== bar else { return nil }
            view = candidate.superview
        }
        guard let control = view else { return nil }
        let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: bar)
        let groups = navigationItem.leadingItemGroups + navigationItem.trailingItemGroups
        let items = groups.flatMap(\.barButtonItems)
            + (navigationItem.leftBarButtonItems ?? []) + (navigationItem.rightBarButtonItems ?? [])
        return items.first { item in
            item.customView == nil && item.frame(in: bar)?.contains(center) == true
        }
    }

    @objc private func recognized() {
        guard state == .began, let pending, let bar = view else { return }
        SettingHelpBubble.present(pending.text, from: pending.item, in: bar)
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
