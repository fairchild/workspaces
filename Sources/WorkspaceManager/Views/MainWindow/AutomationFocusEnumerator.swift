//
//  AutomationFocusEnumerator.swift
//  WorkspaceManager
//
//  Projects the app's live focus state into the `AutomationFocusState` the operator-scope
//  `GET /v1/focus` route returns: NSApp activity, the key window (by the same AppKit window
//  number `window.read` lists), the terminal surface owning the first responder, and — the
//  unavailable-is-not-zero marker — whether the activation policy permits focus at all.
//

import AppKit
import WorkspaceManagerCore

enum AutomationFocusEnumerator {
    @MainActor
    static func state(
        windows: [NSWindow]? = nil,
        appIsActive: Bool? = nil,
        activationAllowed: Bool? = nil,
        tileTreeStore: TileTreeStore?
    ) -> AutomationFocusState {
        let appWindows = windows ?? NSApp.windows
        // Same realized-window rule as the window enumerator: windowNumber <= 0 is an
        // off-screen/deferred window with no listable identity.
        let keyWindow = appWindows.first { $0.isKeyWindow && $0.windowNumber > 0 }
        return AutomationFocusState(
            appIsActive: appIsActive ?? NSApp.isActive,
            keyWindowID: keyWindow.map { String($0.windowNumber) },
            firstResponderSurfaceID: keyWindow.flatMap { window in
                terminalSurfaceID(owningFirstResponderOf: window, tileTreeStore: tileTreeStore)
            },
            focusPossible: activationAllowed ?? AppActivationPolicy.shared.allowsActivation
        )
    }

    /// The terminal surface whose view is (or contains) the window's first responder, matched
    /// against the live tile tree — nil when focus rests outside any terminal surface.
    @MainActor
    private static func terminalSurfaceID(
        owningFirstResponderOf window: NSWindow,
        tileTreeStore: TileTreeStore?
    ) -> String? {
        guard let tileTreeStore, let responderView = window.firstResponder as? NSView else { return nil }
        var sessions = tileTreeStore.sessions
        for primary in tileTreeStore.sessions {
            sessions.append(contentsOf: tileTreeStore.splitSessions(forPrimarySessionID: primary.id))
        }
        for session in sessions {
            guard let terminal = tileTreeStore.surfaceStore.terminal(for: session.id) else { continue }
            if responderView === terminal || responderView.isDescendant(of: terminal) {
                return session.id.uuidString
            }
        }
        return nil
    }
}
