import Foundation
import WorkspaceManagerCore

@MainActor
struct MainWindowTerminalSessionController {
    struct SessionFocusResult: Equatable {
        let focusSessionID: UUID
        let syncedWorkspace: Workspace?
    }

    @discardableResult
    func ensureInitialHostSession(
        hostTerminalState: HostTerminalStateStore,
        defaultHomeDirectory: URL,
        activateHostSession: (HostTerminalSessionKey, URL, String?) -> HostTerminalSession
    ) -> HostTerminalSession? {
        guard !hostTerminalState.hasSessions else { return nil }
        return activateHostSession(.defaultHome, defaultHomeDirectory, nil)
    }

    func createTabFromCurrentContext(
        hostTerminalState: HostTerminalStateStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String,
        activateHostSession: (HostTerminalSessionKey, URL, String?) -> HostTerminalSession
    ) -> SessionFocusResult? {
        ensureInitialHostSession(
            hostTerminalState: hostTerminalState,
            defaultHomeDirectory: defaultHomeDirectory,
            activateHostSession: activateHostSession
        )

        guard let session = hostTerminalState.createTab() else { return nil }
        return focusResult(
            sessionID: session.id,
            hostTerminalState: hostTerminalState,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func selectTab(
        sessionID: UUID,
        hostTerminalState: HostTerminalStateStore,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        guard hostTerminalState.activateExistingSession(sessionID: sessionID) else { return nil }
        return focusResult(
            sessionID: sessionID,
            hostTerminalState: hostTerminalState,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func selectAdjacentTab(
        offset: Int,
        hostTerminalState: HostTerminalStateStore,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        guard let session = hostTerminalState.activateAdjacentTab(offset: offset) else { return nil }
        return focusResult(
            sessionID: session.id,
            hostTerminalState: hostTerminalState,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func closeActiveTab(
        hostTerminalState: HostTerminalStateStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String,
        requestClose: (UUID) -> Bool
    ) -> SessionFocusResult? {
        guard let activeSessionID = hostTerminalState.activeSessionID else { return nil }
        return closeTabs(
            [activeSessionID],
            hostTerminalState: hostTerminalState,
            defaultHomeDirectory: defaultHomeDirectory,
            repos: repos,
            normalizePath: normalizePath,
            requestClose: requestClose
        ).last
    }

    func closeTabs(
        _ sessionIDs: [UUID],
        hostTerminalState: HostTerminalStateStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String,
        requestClose: (UUID) -> Bool
    ) -> [SessionFocusResult] {
        sessionIDs.compactMap { sessionID in
            if requestClose(sessionID) {
                return nil
            }
            return forceCloseTab(
                sessionID: sessionID,
                hostTerminalState: hostTerminalState,
                defaultHomeDirectory: defaultHomeDirectory,
                repos: repos,
                normalizePath: normalizePath
            )
        }
    }

    func closeConfirmation(
        sessionID: UUID,
        hostTerminalState: HostTerminalStateStore
    ) -> TerminalCloseConfirmation {
        let title =
            hostTerminalState.sessions.first(where: { $0.id == sessionID })
            .map {
                hostTerminalState.tabTitleOverride(for: $0.id)
                    ?? hostTerminalState.surfaceStore.displayTitle(for: $0)
            }
            ?? "Terminal"

        return TerminalCloseConfirmation(sessionID: sessionID, title: title)
    }

    func handleProcessExit(
        sessionID: UUID,
        hostTerminalState: HostTerminalStateStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        NSLog("[HostSession] Process exit detected for session %@", sessionID.uuidString)
        guard
            let focusSessionID = hostTerminalState.handleProcessExitAndResolveFocusTarget(
                for: sessionID,
                defaultHomeDirectory: defaultHomeDirectory
            )
        else {
            return nil
        }

        return focusResult(
            sessionID: focusSessionID,
            hostTerminalState: hostTerminalState,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func forceCloseTab(
        sessionID: UUID,
        hostTerminalState: HostTerminalStateStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        guard
            let focusSessionID = hostTerminalState.handleProcessExitAndResolveFocusTarget(
                for: sessionID,
                defaultHomeDirectory: defaultHomeDirectory
            )
        else {
            return nil
        }

        return focusResult(
            sessionID: focusSessionID,
            hostTerminalState: hostTerminalState,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func syncedWorkspaceSelection(
        activeHostSession: HostTerminalSession?,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> Workspace? {
        MainSelectionCoordinator().syncedWorkspaceSelection(
            for: activeHostSession,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func terminalNavigationDestination(
        for session: HostTerminalSession,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> MainWindowNavigationDestination? {
        if let workspace = syncedWorkspaceSelection(
            activeHostSession: session,
            repos: repos,
            normalizePath: normalizePath
        ) {
            return .workspaceTerminal(workspace)
        }

        guard case .repoPath(let repoPath) = session.key else { return nil }
        let normalizedRepoPath = normalizePath(repoPath)
        guard let repo = repos.first(where: { normalizePath($0.localPath) == normalizedRepoPath }) else {
            return nil
        }
        return .repoTerminal(repo)
    }

    private func focusResult(
        sessionID: UUID,
        hostTerminalState: HostTerminalStateStore,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult {
        SessionFocusResult(
            focusSessionID: sessionID,
            syncedWorkspace: syncedWorkspaceSelection(
                activeHostSession: activeHostSession(in: hostTerminalState),
                repos: repos,
                normalizePath: normalizePath
            )
        )
    }

    private func activeHostSession(in hostTerminalState: HostTerminalStateStore) -> HostTerminalSession? {
        guard let activeSessionID = hostTerminalState.activeSessionID else {
            return hostTerminalState.sessions.last
        }
        return hostTerminalState.sessions.first(where: { $0.id == activeSessionID })
            ?? hostTerminalState.sessions.last
    }
}
