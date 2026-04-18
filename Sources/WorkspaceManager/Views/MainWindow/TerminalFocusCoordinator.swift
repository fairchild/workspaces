import AppKit
import Foundation
import WorkspaceManagerCore

/// Single entry point for all terminal focus restoration flows.
///
/// All focus restoration — startup, selection-driven, window-did-become-key, and
/// app-did-become-active — routes through this coordinator. App activation
/// (NSApp.activate) lives here exclusively; TerminalFocusManager handles only
/// the low-level makeFirstResponder mechanics.
@MainActor
final class TerminalFocusCoordinator: ObservableObject, TerminalFocusWindowDelegate {
    private struct PendingFocusRequest {
        let sessionID: UUID
        let activateApp: Bool
        let activeSessionID: UUID?
        let onTargetFocused: (() -> Void)?
        let requestedAtUptime: TimeInterval
        var surfaceResolvedAtUptime: TimeInterval?
    }

    private weak var attachedSurfaceStore: HostTerminalSurfaceStore?
    private weak var window: NSWindow?
    private var pendingRepoFocusMeasurementSessionID: UUID?
    private var pendingWorkspaceFocusMeasurementSessionID: UUID?
    private var pendingFocusRequest: PendingFocusRequest?

    init() {}

    deinit {
        MainActor.assumeIsolated {
            attachedSurfaceStore?.onSurfaceCreated = nil
            attachedSurfaceStore?.onSurfaceInvalidated = nil
            if let window {
                TerminalFocusManager.shared.unbindDelegate(from: window)
            }
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

    func bind(window: NSWindow) {
        guard self.window !== window else { return }

        if let previousWindow = self.window {
            TerminalFocusManager.shared.unbindDelegate(from: previousWindow)
        }

        self.window = window
        TerminalFocusManager.shared.bindDelegate(self, to: window)
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
                surfaceStore: surfaceStore,
                activeSessionID: activeSessionID
            )
            return
        }

        pendingFocusRequest = PendingFocusRequest(
            sessionID: targetSessionID,
            activateApp: activateApp,
            activeSessionID: activeSessionID,
            onTargetFocused: onTargetFocused,
            requestedAtUptime: ProcessInfo.processInfo.systemUptime,
            surfaceResolvedAtUptime: nil
        )
        attemptPendingFocus(using: surfaceStore, reason: "request_started")
    }

    /// Restore focus for the currently tracked terminal when the app becomes active.
    /// Called from AppDelegate.applicationDidBecomeActive instead of going directly
    /// through TerminalFocusManager.
    func restoreFocusOnAppActivation() {
        guard let window else { return }
        guard window.isVisible || window.isKeyWindow || window.isMainWindow else { return }
        if pendingFocusRequest != nil {
            // Coordinator already has a pending request — let it drive.
            return
        }
        guard let terminal = TerminalFocusManager.shared.focusedTerminal else { return }
        TerminalFocusManager.shared.requestFocus(for: terminal)
    }

    func shouldSkipWindowFocusRestore(for window: NSWindow) -> Bool {
        guard self.window === window else { return false }
        return pendingFocusRequest != nil
    }

    func windowDidBecomeKey(_ window: NSWindow) {
        guard self.window === window else { return }
        retryPendingFocus(reason: "window_did_become_key")
    }

    func appDidBecomeActive(for window: NSWindow) {
        guard self.window === window else { return }
        restoreFocusOnAppActivation()
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

    func beginWorkspaceClickMeasurement(sessionID: UUID, workspacePath: String) {
        if let pendingSessionID = pendingWorkspaceFocusMeasurementSessionID,
            pendingSessionID != sessionID
        {
            PerformanceSignposts.cancelWorkspaceClickToFocusedInputIfNeeded(
                sessionID: pendingSessionID,
                reason: "replaced_by_new_workspace_click"
            )
        }

        pendingWorkspaceFocusMeasurementSessionID = sessionID
        PerformanceSignposts.beginWorkspaceClickToFocusedInput(
            sessionID: sessionID,
            workspacePath: workspacePath
        )
    }

    func completeWorkspaceClickMeasurement(sessionID: UUID, outcome: String) {
        guard pendingWorkspaceFocusMeasurementSessionID == sessionID else { return }
        pendingWorkspaceFocusMeasurementSessionID = nil
        PerformanceSignposts.endWorkspaceClickToFocusedInputIfNeeded(
            sessionID: sessionID,
            outcome: outcome
        )
    }

    func cancelPendingWorkspaceClickMeasurement(reason: String) {
        guard let sessionID = pendingWorkspaceFocusMeasurementSessionID else { return }
        pendingWorkspaceFocusMeasurementSessionID = nil
        PerformanceSignposts.cancelWorkspaceClickToFocusedInputIfNeeded(
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
        if pendingWorkspaceFocusMeasurementSessionID == pendingFocusRequest.sessionID {
            cancelPendingWorkspaceClickMeasurement(reason: reason)
        }
    }

    private func attemptPendingFocus(using surfaceStore: HostTerminalSurfaceStore, reason: String) {
        guard var pendingFocusRequest else { return }

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

        let surfaceResolvedAtUptime = ProcessInfo.processInfo.systemUptime
        let resolutionDurationMs = max(
            0,
            (surfaceResolvedAtUptime - pendingFocusRequest.requestedAtUptime) * 1000
        )
        pendingFocusRequest.surfaceResolvedAtUptime = surfaceResolvedAtUptime
        self.pendingFocusRequest = pendingFocusRequest

        InvestigationDiagnostics.emitFocus(
            phase: "focus_surface_resolution",
            fields: focusFields.merging([
                "duration_ms": String(format: "%.2f", resolutionDurationMs),
                "status": "completed",
                "sub_span": "focus_surface_resolution",
            ]) { _, new in new }
        )
        InvestigationDiagnostics.emitFocus(
            phase: "coordinator_target_terminal_resolved",
            fields: focusFields
        )
        InvestigationDiagnostics.emitFocus(
            phase: "focus_request_to_first_responder",
            fields: focusFields.merging([
                "sub_span": "focus_request_to_first_responder",
                "status": "started",
            ]) { _, new in new }
        )
        TerminalFocusManager.shared.requestFocus(
            for: terminal,
            onFocused: { [weak self] in
                guard let self else { return }
                guard let pendingRequest = self.pendingFocusRequest,
                    pendingRequest.sessionID == pendingFocusRequest.sessionID
                else { return }
                self.pendingFocusRequest = nil
                let focusCompletedAtUptime = ProcessInfo.processInfo.systemUptime
                let firstResponderDurationMs = max(
                    0,
                    (focusCompletedAtUptime
                        - (pendingRequest.surfaceResolvedAtUptime ?? pendingRequest.requestedAtUptime))
                        * 1000
                )
                let totalFocusDurationMs = max(
                    0,
                    (focusCompletedAtUptime - pendingRequest.requestedAtUptime) * 1000
                )
                InvestigationDiagnostics.emitFocus(
                    phase: "focus_request_to_first_responder",
                    fields: focusFields.merging([
                        "duration_ms": String(format: "%.2f", firstResponderDurationMs),
                        "sub_span": "focus_request_to_first_responder",
                        "status": "completed",
                    ]) { _, new in new }
                )
                InvestigationDiagnostics.emitFocus(
                    phase: "coordinator_target_focused",
                    fields: focusFields.merging([
                        "duration_ms": String(format: "%.2f", totalFocusDurationMs)
                    ]) { _, new in new }
                )
                pendingFocusRequest.onTargetFocused?()
            }
        )
    }

    private func requestFallbackFocus(
        surfaceStore: HostTerminalSurfaceStore,
        activeSessionID: UUID?
    ) {
        let focusFields = [
            "active_session": activeSessionID?.uuidString ?? "none"
        ]

        if let activeSessionID,
            let terminal = surfaceStore.terminal(for: activeSessionID)
        {
            InvestigationDiagnostics.emitFocus(
                phase: "coordinator_active_terminal_resolved",
                fields: focusFields
            )
            TerminalFocusManager.shared.requestFocus(for: terminal)
            return
        }

        if let terminal = TerminalFocusManager.shared.focusedTerminal {
            InvestigationDiagnostics.emitFocus(
                phase: "coordinator_focused_terminal_fallback",
                fields: focusFields
            )
            TerminalFocusManager.shared.requestFocus(for: terminal)
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
