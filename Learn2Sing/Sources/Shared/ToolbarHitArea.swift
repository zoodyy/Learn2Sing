//
//  ToolbarHitArea.swift
//  Learn2Sing
//
//  Toolbar buttons that answer wherever their glass lights up.
//
//  A toolbar button that carries modifiers of its own (`.explain`, above all)
//  isn't made into a native bar button. UIKit hosts the SwiftUI label in a box
//  and draws the glass around that box, and the glass lights up wherever it is
//  pressed. The button only fires where the label itself is, though, and a bare
//  symbol is about 20 pt wide in a 44 pt circle. A press beside the symbol
//  shows the button being tapped and then does nothing.
//
//  Which of the two fixes below a label takes depends on how it is hosted, and
//  both were measured on iOS 26.2:
//
//  - A symbol with a circle of its own is hosted at the label's own size, so
//    nothing outside the label can be hit and the label has to grow. The circle
//    is 44 pt until the label is wider than 32 pt, so it can grow that far
//    without the circle changing.
//  - A symbol sharing a capsule with others, a word, or a row of tools sits in
//    a box wider than itself, and the box does take touches. The label keeps its
//    size and a clear background reaches out to the box's edges. UIKit cuts the
//    background off at the box, so it never reaches a neighbour's box.
//
//  Neither reaches the outer 4 pt of the glass, which lies outside every box.
//  A button whose label is a `Label` stays a native bar button even with
//  `.explain` on it, and answers across its whole glass without either. A
//  `Text` label doesn't. SwiftUI drops the `.explain` there, hold and all, so
//  such a button gets its hold from `explainBarButton` (see SettingHelp).
//

import SwiftUI

extension View {
    /// Grows a toolbar symbol with a circle of its own to fill the circle's box.
    /// Goes on the label, inside the `Button` or `Menu`.
    ///
    /// `minWidth` is the widest the label can be before its glass grows: 32 pt in
    /// a navigation bar, and 36 pt above the keyboard, whose circle is wider.
    func toolbarSymbolHitArea(minWidth: CGFloat = 32) -> some View {
        frame(minWidth: minWidth, minHeight: 36)
            .contentShape(Rectangle())
    }

    /// Lets a toolbar label that sits in a wider box take touches in the space
    /// around it, without changing its size. Goes on the label, inside the
    /// `Button` or `Menu`.
    ///
    /// `reach` is how far past the label touches count on each side. The default
    /// is more than any box leaves, since UIKit cuts it off at the box anyway;
    /// pass less on a side that faces another button inside the same box.
    func toolbarHitArea(reach: EdgeInsets = EdgeInsets(top: 16, leading: 16,
                                                       bottom: 16, trailing: 16)) -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .padding(EdgeInsets(top: -reach.top, leading: -reach.leading,
                                    bottom: -reach.bottom, trailing: -reach.trailing))
        }
    }
}
