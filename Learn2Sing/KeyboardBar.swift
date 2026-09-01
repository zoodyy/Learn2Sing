//
//  KeyboardBar.swift
//  Learn2Sing
//

import SwiftUI

extension View {
    /// The bar every keyboard in the app puts above itself: the sign toggle at
    /// the far leading edge for the fields that take a negative value, and
    /// "Done" at the far trailing edge. One modifier for all of them, so the two
    /// buttons look the same and sit in the same place from keyboard to
    /// keyboard — a "Done" that moves inwards on the keyboards that also show
    /// the sign toggle reads as a different button.
    ///
    /// That moving is why the two live in separate `ToolbarItemGroup`s: iOS
    /// draws one group's contents as a single capsule sized to fit them, so a
    /// group holding both buttons ends up centred above the keyboard with the
    /// `Spacer()` between them shrunk to the gap inside it. Given a group each,
    /// they keep their own capsules, and the spacer sitting in front of "Done"
    /// pushes it to the trailing edge — which is where it already was on the
    /// keyboards that show it alone.
    ///
    /// Passing `onToggleSign: nil` (the default) leaves "Done" on its own.
    func keyboardBar(onToggleSign: (() -> Void)? = nil,
                     onDone: @escaping () -> Void) -> some View {
        toolbar {
            if let onToggleSign {
                ToolbarItemGroup(placement: .keyboard) {
                    // The number pad has no minus key, so this is what enters a
                    // negative value.
                    Button(action: onToggleSign) {
                        Image(systemName: "plus.forwardslash.minus")
                    }
                    .explain(L("Turns the number in the field from plus to minus and back, since the number pad has no minus key."))
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done", action: onDone)
            }
        }
    }
}
