import SwiftData
import SwiftUI
import WorkspaceManagerCore

/// Builds the gesture-verb layer backing the automation API's workspace mutations. Every verb
/// enters the same UI path a click does — `performSelection` writes the selection binding whose
/// setter attaches the terminal and requests focus — and then reads back what the gesture
/// actually did. The layer holds closures over the live view state and no backend handle, so a
/// verb cannot reach past the UI to a service or a SwiftData write.
@MainActor
struct MainWindowAutomationGestureVerbs {
    struct Dependencies {
        let repos: @MainActor () -> [Repo]
        let selectedWorkspace: Binding<Workspace?>
        let selectedWorkspaceID: @MainActor () -> UUID?
        let tileTreeStore: TileTreeStore
        let focusCoordinator: any MainWindowTerminalFocusRequesting
        let smokeDriver: SmokeScenarioDriver
        let createBridge: AutomationWorkspaceCreateGestureBridge
        let modelContext: ModelContext
        let workspaceService: any WorkspaceServiceProtocol
        let providerRegistry: WorkspaceProviderRegistry
        let retireTerminalSessions: @MainActor (HostTerminalSessionKey) async throws -> Void
        let makeTeardownController: @MainActor () -> WorkspaceTerminalTeardownController
        let attachWorkspaceSessionWithoutSelection: @MainActor (Workspace) -> UUID?
        let selectRepoTerminal: @MainActor (Repo) -> Void
    }

    let dependencies: Dependencies

    func makeVerbs() -> AutomationGestureVerbs {
        AutomationGestureVerbs(
            resolveWorkspace: { workspaceID in resolveWorkspaceTarget(workspaceID) },
            performSelection: { target in performSelection(target) },
            resolveRepo: { repoID in resolveRepoTarget(repoID) },
            performCreation: { _, command in await performCreation(command) },
            performArchive: { target, command in await performArchive(target, command) },
            performNote: { target, note in performNote(target, note: note) },
            performRepoTerminal: { target in performRepoTerminal(target) }
        )
    }

    /// Enters the same path a sidebar repo row's terminal takes, then reads back the surface the
    /// gesture actually attached — the observable proof, not an assumption that it worked.
    private func performRepoTerminal(
        _ target: AutomationGestureVerbs.RepoTarget
    ) -> AutomationRepoTerminalEffect {
        guard let repo = dependencies.repos().first(where: { $0.id == target.repoID }) else {
            return AutomationRepoTerminalEffect(
                attachedSurfaceID: nil,
                attachedTerminal: false,
                directoryPath: target.path
            )
        }

        dependencies.selectRepoTerminal(repo)

        // Built through the key's own normalizer, the way the selection path builds it, so the
        // comparison cannot fail on two spellings of the same directory.
        let repoScopeKey = HostTerminalSessionKey.repoPath(repo.localURL.path).normalized()
        let repoDirectory = MainWindowPathResolution.normalize(repo.localURL.path)
        let attachedSurfaceID = dependencies.tileTreeStore.activeSessionID
        let attachedSession = dependencies.tileTreeStore.sessions.first { $0.id == attachedSurfaceID }
        // The gesture is only "attached" when the active session is the one this repo's scope
        // owns; a selection that landed elsewhere reports no surface rather than the wrong one.
        let attached = attachedSession?.key == repoScopeKey
        return AutomationRepoTerminalEffect(
            attachedSurfaceID: attached ? attachedSurfaceID : nil,
            attachedTerminal: attached,
            directoryPath: attachedSession.map(\.directoryPath) ?? repoDirectory
        )
    }

    private func workspace(with id: UUID) -> Workspace? {
        dependencies.repos().flatMap(\.workspaces).first { $0.id == id }
    }

    private func resolveWorkspaceTarget(_ workspaceID: UUID) -> AutomationGestureVerbs.WorkspaceTarget? {
        guard let workspace = workspace(with: workspaceID) else { return nil }
        return AutomationGestureVerbs.WorkspaceTarget(
            workspaceID: workspace.id,
            name: workspace.name,
            isArchived: workspace.status == .archived
        )
    }

    /// Enters the same setter the row's "Edit Note…" item writes through — normalization
    /// included, so a note set over the socket renders exactly as a typed one.
    private func performNote(
        _ target: AutomationGestureVerbs.WorkspaceTarget,
        note: String?
    ) -> AutomationWorkspaceNoteOutcome {
        guard let workspace = workspace(with: target.workspaceID) else {
            return .notFound
        }
        let normalized = WorkspaceNote.normalized(note)
        let changed = workspace.note != normalized
        workspace.note = normalized
        try? dependencies.modelContext.save()
        return .completed(note: normalized, changed: changed, workspaceName: workspace.name)
    }

    private func resolveRepoTarget(_ repoID: UUID) -> AutomationGestureVerbs.RepoTarget? {
        guard let repo = dependencies.repos().first(where: { $0.id == repoID }) else { return nil }
        return AutomationGestureVerbs.RepoTarget(
            repoID: repo.id,
            name: repo.name,
            path: repo.localPath
        )
    }

    private func performSelection(
        _ target: AutomationGestureVerbs.WorkspaceTarget
    ) -> AutomationWorkspaceSelectEffect {
        guard let workspace = workspace(with: target.workspaceID) else {
            return AutomationWorkspaceSelectEffect(
                selectedWorkspaceID: nil,
                attachedSurfaceID: nil,
                attachedTerminal: false
            )
        }
        // Enter the real selection path: write the binding whose setter runs the workspace
        // selection (terminal attach + focus request), exactly as a click does.
        dependencies.selectedWorkspace.wrappedValue = workspace
        // Read back what the gesture did. Selection landing on the target workspace (not the
        // archived → repo-overview branch) with a live active session is the terminal attach;
        // that active session is the surface a following input would land in — the wrong-PTY
        // guard, observable rather than assumed.
        let selectedID = dependencies.selectedWorkspaceID()
        let activeSessionID = dependencies.tileTreeStore.activeSessionID
        let attached = selectedID == workspace.id && activeSessionID != nil
        return AutomationWorkspaceSelectEffect(
            selectedWorkspaceID: selectedID,
            attachedSurfaceID: attached ? activeSessionID : nil,
            attachedTerminal: attached
        )
    }

    private func performCreation(
        _ command: AutomationWorkspaceCreateCommand
    ) async -> AutomationWorkspaceCreateOutcome {
        let outcome = await dependencies.createBridge.createWorkspace(command)
        guard case .completed(let effect) = outcome else {
            return outcome
        }
        var attachedSurfaceID: UUID?
        var attached = false
        if !command.shouldSelect, let workspace = workspace(with: effect.workspaceID) {
            attachedSurfaceID = dependencies.attachWorkspaceSessionWithoutSelection(workspace)
            attached = attachedSurfaceID != nil
        }
        let selectedID = dependencies.selectedWorkspaceID()
        let activeSessionID = dependencies.tileTreeStore.activeSessionID
        if command.shouldSelect {
            attached = selectedID == effect.workspaceID && activeSessionID != nil
            attachedSurfaceID = attached ? activeSessionID : nil
            dependencies.smokeDriver.noteAPIWorkspaceCreateCompleted(
                repoID: effect.repoID,
                workspaceID: effect.workspaceID,
                repos: dependencies.repos(),
                parkOnRepoTerminal: { dependencies.selectRepoTerminal($0) }
            )
        }
        return .completed(
            AutomationWorkspaceCreateEffect(
                repoID: effect.repoID,
                workspaceID: effect.workspaceID,
                workspaceName: effect.workspaceName,
                workspacePath: effect.workspacePath,
                selectedWorkspaceID: selectedID,
                attachedSurfaceID: attachedSurfaceID,
                attachedTerminal: attached
            )
        )
    }

    private func performArchive(
        _ target: AutomationGestureVerbs.WorkspaceTarget,
        _ command: AutomationWorkspaceArchiveCommand
    ) async -> AutomationWorkspaceArchiveOutcome {
        guard let workspace = workspace(with: target.workspaceID) else {
            return .notFound
        }
        let controller = SidebarWorkspaceController(
            modelContext: dependencies.modelContext,
            workspaceService: dependencies.workspaceService,
            workspaceProviderRegistry: dependencies.providerRegistry,
            retireTerminalSessions: dependencies.retireTerminalSessions
        )
        var teardown: AutomationWorkspaceArchiveTeardownReport?
        if command.teardownTerminals {
            let scopeKey: HostTerminalSessionKey
            do {
                scopeKey = try controller.terminalSessionKey(for: workspace)
            } catch {
                return .unsupported(
                    "Failed to resolve the workspace's terminal scope: \(error.localizedDescription)")
            }
            switch await dependencies.makeTeardownController().teardown(scopeKey: scopeKey) {
            case .completed(let report):
                teardown = report
                dependencies.focusCoordinator.cancelPendingFocusRequest(
                    reason: "workspace_archive_teardown_retired_sessions")
            case .closeBlockedByConfirmation(let message):
                return .closeBlockedByConfirmation(message)
            }
        }
        do {
            try await controller.archive(workspace)
            return .completed(
                AutomationWorkspaceArchiveEffect(
                    workspaceID: workspace.id,
                    selectedWorkspaceID: dependencies.selectedWorkspaceID(),
                    teardown: teardown
                )
            )
        } catch let error as GhosttySurfaceRetirementCloseError {
            // The typed terminal-still-live arms (#1226): the transient timeout is
            // retryable; the confirmation-blocked case is not — the dialog cannot be
            // answered headlessly, so callers should re-issue with teardownTerminals.
            switch error {
            case .timedOut:
                return .terminalActive(
                    error.localizedDescription
                        + " Retry, or archive with teardownTerminals to close it first.")
            case .processStillRunning:
                return .closeBlockedByConfirmation(
                    error.localizedDescription
                        + " Archive with teardownTerminals to tear the terminal down first.")
            }
        } catch {
            return .unsupported("Failed to archive workspace: \(error.localizedDescription)")
        }
    }
}
