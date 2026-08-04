//
//  MainWindowPresentation.swift
//  WorkspaceManager
//
//  Bridges between the main window's "pending item" state and the bindings SwiftUI's alert and
//  sheet modifiers want. Every confirmation in the window is driven by an optional — non-nil
//  presents, dismissal clears — and every confirming button has to take that value before it
//  acts. Both rules were previously re-implemented inline at each call site.
//

import SwiftUI

enum MainWindowPresentation {
    /// `true` while `item` is non-nil.
    ///
    /// Only a dismissal clears the source. A `true` write is deliberately ignored: SwiftUI can
    /// re-assert presentation, and inventing an item to satisfy it is not this binding's job —
    /// the item is what decides, not the flag.
    static func isPresented<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { item.wrappedValue = nil }
            }
        )
    }

    /// As above, but dismissal runs `onDismiss` rather than assigning `nil`, for sources that own
    /// their own teardown — a coordinator that has to cancel pending work, not merely forget a
    /// value it was holding.
    static func isPresented<Item>(
        _ item: @escaping @autoclosure () -> Item?,
        onDismiss: @escaping () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { item() != nil },
            set: { isPresented in
                if !isPresented { onDismiss() }
            }
        )
    }

    /// An `item:` binding whose dismissal runs `onDismiss`. Same rule as above, for the `sheet(item:)`
    /// form that hands the item to its content builder.
    static func item<Item>(
        _ item: @escaping @autoclosure () -> Item?,
        onDismiss: @escaping () -> Void
    ) -> Binding<Item?> {
        Binding(
            get: item,
            set: { newValue in
                if newValue == nil { onDismiss() }
            }
        )
    }

    /// An `item:` binding that ignores dismissal entirely: the sheet closes when its owner
    /// finishes the work, never because the user waved it away. Pair with
    /// `interactiveDismissDisabled(true)` so the two agree.
    static func undismissableItem<Item>(
        _ item: @escaping @autoclosure () -> Item?
    ) -> Binding<Item?> {
        Binding(get: item, set: { _ in })
    }

    /// Takes the pending value and clears it in one step.
    ///
    /// Confirming buttons must consume *before* they act. The action can present again — a
    /// cleanup that rescans, a close that raises a new confirmation — and a source still holding
    /// the answered value would re-show the alert the user just dismissed. Returns `nil` when
    /// there is nothing pending, which is the guard SwiftUI needs because a button action can
    /// still arrive after the state cleared.
    @discardableResult
    static func consume<Item>(_ item: Binding<Item?>) -> Item? {
        guard let value = item.wrappedValue else { return nil }
        item.wrappedValue = nil
        return value
    }
}
