import AppKit
import Foundation
import WorkspaceManagerCore

@MainActor
final class TerminalFocusCoordinator: ObservableObject {
    private struct PendingFocusRequest {
        let sessionID: UUID
        let activateApp: Bool
        let activeSessionID: UUID?
        let onTargetFocused: (() -> Void)?
    }

    private weak var attachedSurfaceStore: HostTerminalSurfaceStore?
    private var pendingRepoFocusMeasurementSessionID: UUID?
    private var pendingFocusRequest: PendingFocusRequest?

    init() {
        TerminalFocusManager.shared.shouldSkipWindowFocusRestore = { [weak self] in
            self?.pendingFocusRequest != nil
        }
        TerminalFocusManager.shared.onWindowDidBecomeKey = { [weak self] in
            self?.retryPendingFocus(reason: "window_did_become_key")
        }
    }

    func attach(surfaceStore: HostTerminalSurfaceStore) {
        guard attachedSurfaceStore !== surfaceStore else { return }

        attachedSurfaceStore?.onSurfaceCreated = nil
        attachedSurfaceStore?.onSurfaceInvalidated = nil

        attachedSurfaceStore = surfaceStore
        surfaceStore.onSurfaceCreated = { [weak self] sessionID in
            self?.surfaceDidBecomeAvailable(sessionID: sessionID)
        }
        surfaceStore.onSurfaceInvalidated = { [weak self] sessionID in
            self?.surfaceDidInvalidate(sessionID: sessionID)
        }
    }

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
        attach(surfaceStore: surfaceStore)

        let focusFields = [
            "activate_app": activateApp ? "true" : "false",
            "target_session": targetSessionID?.uuidString ?? "none",
            "active_session": activeSessionID?.uuidString ?? "none",
        ]
        InvestigationDiagnostics.emitFocus(
            phase: "coordinator_request_started",
            fields: focusFields
        )

        if activateApp {
            InvestigationDiagnostics.emitFocus(
                phase: "coordinator_activate_requested",
                fields: focusFields
            )
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApp.windows.first(where: \.isVisible) ?? NSApp.windows.first
            window?.makeKeyAndOrderFront(nil)
        }

        guard let targetSessionID else {
            pendingFocusRequest = nil
            requestFallbackFocus(
                activateApp: activateApp,
                surfaceStore: surfaceStore,
                activeSessionID: activeSessionID
            )
            return
        }

        pendingFocusRequest = PendingFocusRequest(
            sessionID: targetSessionID,
            activateApp: activateApp,
            activeSessionID: activeSessionID,
            onTargetFocused: onTargetFocused
        )
        attemptPendingFocus(using: surfaceStore, reason: "request_started")
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

    func cancelPendingFocusRequest(reason: String) {
        guard let pendingFocusRequest else { return }
        self.pendingFocusRequest = nil
        InvestigationDiagnostics.emitFocus(
            phase: "coordinator_pending_request_cancelled",
            fields: [
                "reason": reason,
                "target_session": pendingFocusRequest.sessionID.uuidString,
            ]
        )
        if pendingRepoFocusMeasurementSessionID == pendingFocusRequest.sessionID {
            cancelPendingRepoClickMeasurement(reason: reason)
        }
    }

    private func attemptPendingFocus(using surfaceStore: HostTerminalSurfaceStore, reason: String) {
        guard let pendingFocusRequest else { return }

        let focusFields = [
            "activate_app": pendingFocusRequest.activateApp ? "true" : "false",
            "target_session": pendingFocusRequest.sessionID.uuidString,
            "active_session": pendingFocusRequest.activeSessionID?.uuidString ?? "none",
            "resolution_reason": reason,
        ]

        guard let terminal = surfaceStore.terminal(for: pendingFocusRequest.sessionID) else {
            InvestigationDiagnostics.emitFocus(
                phase: "coordinator_target_terminal_pending",
                fields: focusFields
            )
            return
        }

        InvestigationDiagnostics.emitFocus(
            phase: "coordinator_target_terminal_resolved",
            fields: focusFields
        )
        TerminalFocusManager.shared.requestFocus(
            for: terminal,
            activateApp: pendingFocusRequest.activateApp,
            onFocused: { [weak self] in
                guard let self else { return }
                guard self.pendingFocusRequest?.sessionID == pendingFocusRequest.sessionID else { return }
                self.pendingFocusRequest = nil
                InvestigationDiagnostics.emitFocus(
                    phase: "coordinator_target_focused",
                    fields: focusFields
                )
                pendingFocusRequest.onTargetFocused?()
            }
        )
    }

    private func requestFallbackFocus(
        activateApp: Bool,
        surfaceStore: HostTerminalSurfaceStore,
        activeSessionID: UUID?
    ) {
        let focusFields = [
            "activate_app": activateApp ? "true" : "false",
            "active_session": activeSessionID?.uuidString ?? "none",
        ]

        if let activeSessionID,
            let terminal = surfaceStore.terminal(for: activeSessionID)
        {
            InvestigationDiagnostics.emitFocus(
                phase: "coordinator_active_terminal_resolved",
                fields: focusFields
            )
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp
            )
            return
        }

        if let terminal = TerminalFocusManager.shared.focusedTerminal {
            InvestigationDiagnostics.emitFocus(
                phase: "coordinator_focused_terminal_fallback",
                fields: focusFields
            )
            TerminalFocusManager.shared.requestFocus(
                for: terminal,
                activateApp: activateApp
            )
            return
        }

        InvestigationDiagnostics.emitFocus(
            phase: "coordinator_no_terminal_available",
            fields: focusFields
        )
    }

    private func retryPendingFocus(reason: String) {
        guard let attachedSurfaceStore else { return }
        attemptPendingFocus(using: attachedSurfaceStore, reason: reason)
    }

    private func surfaceDidBecomeAvailable(sessionID: UUID) {
        guard pendingFocusRequest?.sessionID == sessionID else { return }
        retryPendingFocus(reason: "surface_created")
    }

    private func surfaceDidInvalidate(sessionID: UUID) {
        guard pendingFocusRequest?.sessionID == sessionID else { return }
        cancelPendingFocusRequest(reason: "surface_invalidated")
    }
}
