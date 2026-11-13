import Foundation
import SwiftUI
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "HostSession")

@MainActor
struct MainWindowTerminalSessionController {
    struct SessionFocusResult: Equatable {
        let focusSessionID: UUID
        let syncedWorkspace: Workspace?
    }

    struct TabCreationResult {
        let focus: SessionFocusResult
        let navigationDestination: MainWindowNavigationDestination?
    }

    /// A visible repository overview can bootstrap its own first terminal. Other surfaces still
    /// need an existing session so Cmd-T cannot create an invisible terminal behind web content.
    func canCreateTab(hasSessions: Bool, selectedRepoForLanding: Repo?, isConnectingWorkspace: Bool) -> Bool {
        !isConnectingWorkspace && (hasSessions || selectedRepoForLanding != nil)
    }

    @discardableResult
    func ensureInitialHostSession(
        tileTreeStore: TileTreeStore,
        defaultHomeDirectory: URL,
        activateHostSession: (HostTerminalSessionKey, URL, String?) -> HostTerminalSession
    ) -> HostTerminalSession? {
        guard !tileTreeStore.hasSessions else { return nil }
        return activateHostSession(.defaultHome, defaultHomeDirectory, nil)
    }

    func createTabFromCurrentContext(
        tileTreeStore: TileTreeStore,
        defaultHomeDirectory: URL,
        selectedRepoForLanding: Repo?,
        repos: [Repo],
        normalizePath: (String) -> String,
        activateHostSession: (HostTerminalSessionKey, URL, String?) -> HostTerminalSession
    ) -> TabCreationResult? {
        if let selectedRepoForLanding {
            return createTabFromRepoOverview(
                selectedRepoForLanding,
                tileTreeStore: tileTreeStore,
                repos: repos,
                normalizePath: normalizePath,
                activateHostSession: activateHostSession
            )
        }

        ensureInitialHostSession(
            tileTreeStore: tileTreeStore,
            defaultHomeDirectory: defaultHomeDirectory,
            activateHostSession: activateHostSession
        )

        guard let session = tileTreeStore.createTab() else { return nil }
        return TabCreationResult(
            focus: focusResult(
                sessionID: session.id,
                tileTreeStore: tileTreeStore,
                repos: repos,
                normalizePath: normalizePath
            ),
            navigationDestination: nil
        )
    }

    private func createTabFromRepoOverview(
        _ repo: Repo,
        tileTreeStore: TileTreeStore,
        repos: [Repo],
        normalizePath: (String) -> String,
        activateHostSession: (HostTerminalSessionKey, URL, String?) -> HostTerminalSession
    ) -> TabCreationResult? {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()
        let scopeKey = HostTerminalSessionKey.repoPath(repoDirectory.path)
        let session: HostTerminalSession

        if let existingSession = tileTreeStore.activeSession(inScope: scopeKey) {
            guard tileTreeStore.activateExistingSession(sessionID: existingSession.id),
                let siblingSession = tileTreeStore.createTab(from: existingSession.id)
            else { return nil }
            session = siblingSession
        } else {
            let existingSessionIDs = Set(tileTreeStore.sessions.map(\.id))
            let activatedSession = activateHostSession(scopeKey, repoDirectory, nil)
            if existingSessionIDs.contains(activatedSession.id) {
                guard let siblingSession = tileTreeStore.createTab(from: activatedSession.id) else { return nil }
                session = siblingSession
            } else {
                session = activatedSession
            }
        }

        let navigationDestination =
            terminalNavigationDestination(for: session, repos: repos, normalizePath: normalizePath)
            ?? .repoTerminal(repo)
        return TabCreationResult(
            focus: focusResult(
                sessionID: session.id,
                tileTreeStore: tileTreeStore,
                repos: repos,
                normalizePath: normalizePath
            ),
            navigationDestination: navigationDestination
        )
    }

    func selectTab(
        sessionID: UUID,
        tileTreeStore: TileTreeStore,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        guard tileTreeStore.activateExistingSession(sessionID: sessionID) else { return nil }
        return focusResult(
            sessionID: sessionID,
            tileTreeStore: tileTreeStore,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func selectAdjacentTab(
        offset: Int,
        tileTreeStore: TileTreeStore,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        guard let session = tileTreeStore.activateAdjacentTab(offset: offset) else { return nil }
        return focusResult(
            sessionID: session.id,
            tileTreeStore: tileTreeStore,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func closeActiveTab(
        tileTreeStore: TileTreeStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String,
        requestClose: (UUID) -> Bool
    ) -> SessionFocusResult? {
        guard let activeSessionID = tileTreeStore.activeSessionID else { return nil }
        return closeTabs(
            [activeSessionID],
            tileTreeStore: tileTreeStore,
            defaultHomeDirectory: defaultHomeDirectory,
            repos: repos,
            normalizePath: normalizePath,
            requestClose: requestClose
        ).last
    }

    func closeTabs(
        _ sessionIDs: [UUID],
        tileTreeStore: TileTreeStore,
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
                tileTreeStore: tileTreeStore,
                defaultHomeDirectory: defaultHomeDirectory,
                repos: repos,
                normalizePath: normalizePath
            )
        }
    }

    /// Raises the close confirmation for `sessionID`: the tile tree takes ownership of the
    /// close, and the returned sheet content refers to it.
    func raiseCloseConfirmation(
        sessionID: UUID,
        tileTreeStore: TileTreeStore
    ) -> TerminalCloseConfirmation {
        let context = tileTreeStore.raiseCloseConfirmation(for: sessionID)
        let session = tileTreeStore.allLiveSessions.first(where: { $0.id == sessionID })
        let title =
            session.map {
                tileTreeStore.tabTitleOverride(for: $0.id)
                    ?? tileTreeStore.surfaceStore.displayTitle(for: $0)
            }
            ?? "Terminal"

        return TerminalCloseConfirmation(
            context: context,
            title: title,
            keepsRunningInTmux: context.keepsTmuxRunning
        )
    }

    /// Whether the close sheet is up. Dismissing it by any route but Close, the framework's
    /// own dismissal included, cancels the close it showed.
    func closeConfirmationPresented(
        _ confirmation: Binding<TerminalCloseConfirmation?>,
        tileTreeStore: TileTreeStore
    ) -> Binding<Bool> {
        MainWindowPresentation.isPresented(
            confirmation.wrappedValue,
            onDismiss: { dismissCloseConfirmation(confirmation, tileTreeStore: tileTreeStore) }
        )
    }

    /// The person answered the sheet with Close: its confirmation completes the close.
    func completeCloseConfirmation(
        _ confirmation: TerminalCloseConfirmation,
        tileTreeStore: TileTreeStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        guard
            let focusSessionID = tileTreeStore.completeCloseConfirmationAndResolveFocusTarget(
                confirmation.context,
                defaultHomeDirectory: defaultHomeDirectory
            )
        else {
            return nil
        }
        return focusResult(
            sessionID: focusSessionID,
            tileTreeStore: tileTreeStore,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    /// Takes the sheet's confirmation down and cancels its close. A sheet already answered
    /// has nothing left to cancel.
    func dismissCloseConfirmation(
        _ confirmation: Binding<TerminalCloseConfirmation?>,
        tileTreeStore: TileTreeStore
    ) {
        guard let shown = MainWindowPresentation.consume(confirmation) else { return }
        tileTreeStore.cancelCloseConfirmation(shown.context)
    }

    /// The window's half of a process exit, after the store has closed the tile and recorded
    /// its row: where focus goes next.
    func focusAfterProcessExit(
        sessionID: UUID,
        tileTreeStore: TileTreeStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        log.info("[HostSession] Process exit closed session \(sessionID.uuidString, privacy: .public)")
        guard let focusSessionID = tileTreeStore.focusTargetAfterRemoval(defaultHomeDirectory: defaultHomeDirectory)
        else {
            return nil
        }

        return focusResult(
            sessionID: focusSessionID,
            tileTreeStore: tileTreeStore,
            repos: repos,
            normalizePath: normalizePath
        )
    }

    func forceCloseTab(
        sessionID: UUID,
        tileTreeStore: TileTreeStore,
        defaultHomeDirectory: URL,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult? {
        guard
            let focusSessionID = tileTreeStore.handleProcessExitAndResolveFocusTarget(
                for: sessionID,
                cause: .userClosed,
                defaultHomeDirectory: defaultHomeDirectory
            )
        else {
            return nil
        }

        return focusResult(
            sessionID: focusSessionID,
            tileTreeStore: tileTreeStore,
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
        tileTreeStore: TileTreeStore,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> SessionFocusResult {
        SessionFocusResult(
            focusSessionID: sessionID,
            syncedWorkspace: syncedWorkspaceSelection(
                activeHostSession: activeHostSession(in: tileTreeStore),
                repos: repos,
                normalizePath: normalizePath
            )
        )
    }

    private func activeHostSession(in tileTreeStore: TileTreeStore) -> HostTerminalSession? {
        guard let activeSessionID = tileTreeStore.activeSessionID else {
            return tileTreeStore.sessions.last
        }
        return tileTreeStore.sessions.first(where: { $0.id == activeSessionID })
            ?? tileTreeStore.sessions.last
    }
}
