import AppKit
import Foundation
import WorkspaceManagerCore

@MainActor
final class TerminalFocusCoordinator: ObservableObject {
    private var pendingRepoFocusMeasurementSessionID: UUID?

    func focusTerminal(sessionID: UUID, surfaceStore: HostTerminalSurfaceStore) {
        guard let terminal = surfaceStore.terminal(for: sessionID) else {
            NSLog("[SplitRouting] focus skipped: no terminal for session %@", sessionID.uuidString)
            return
        }
        TerminalFocusManager.shared.requestFocus(for: terminal)
    }

    func requestMainTerminalFocus(
        targetSessionID: UUID? = nil,
        activateApp: Bool = true,
        surfaceStore: HostTerminalSurfaceStore,
        activeSessionID: UUID?,
        onTargetFocused: (() -> Void)? = nil
    ) {
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
            window?.makeKeyAndOrderFront(nil)
        }

        if let targetSessionID,
            let terminal = surfaceStore.terminal(for: targetSessionID)
        {
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp,
                onFocused: onTargetFocused
            )
            return
        }

        if let activeSessionID,
            let terminal = surfaceStore.terminal(for: activeSessionID)
        {
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp
            )
            return
        }

        if let terminal = TerminalFocusManager.shared.focusedTerminal {
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp
            )
        }
    }

    func beginRepoClickMeasurement(sessionID: UUID, repoPath: String) {
        if let pendingSessionID = pendingRepoFocusMeasurementSessionID,
            pendingSessionID != sessionID
        {
            PerformanceSignposts.cancelRepoClickToFocusedInputIfNeeded(
                sessionID: pendingSessionID,
                reason: "replaced_by_new_repo_click"
            )
        }

        pendingRepoFocusMeasurementSessionID = sessionID
        PerformanceSignposts.beginRepoClickToFocusedInput(
            sessionID: sessionID,
            repoPath: repoPath
        )
    }

    func completeRepoClickMeasurement(sessionID: UUID, outcome: String) {
        guard pendingRepoFocusMeasurementSessionID == sessionID else { return }
        pendingRepoFocusMeasurementSessionID = nil
        PerformanceSignposts.endRepoClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            outcome: outcome
        )
    }

    func cancelPendingRepoClickMeasurement(reason: String) {
        guard let sessionID = pendingRepoFocusMeasurementSessionID else { return }
        pendingRepoFocusMeasurementSessionID = nil
        PerformanceSignposts.cancelRepoClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            reason: reason
        )
    }
}
