//
//  MainWindowWindowLifetime.swift
//  WorkspaceManager
//
//  One main window's liveness, as a reference the automation layer can read after the view value
//  is gone. Held in `@State` so it outlives a body evaluation and survives into teardown (#1375).
//

import Foundation

/// Whether the window a window-bound layer belongs to is still there.
///
/// The layer is a set of closures over view state, installed by an `async` configure that can
/// suspend on the automation listener. Nothing cancels that work when the window closes, so the
/// install can land after teardown. A flag the controller reads before running a verb is what
/// keeps a dead window's closures from being driven — the teardown event alone cannot, because
/// it may have already happened by the time the install arrives.
@MainActor
final class MainWindowWindowLifetime {
    private(set) var isTornDown = false

    func noteWindowAppeared() {
        isTornDown = false
    }

    func noteWindowTornDown() {
        isTornDown = true
    }
}
