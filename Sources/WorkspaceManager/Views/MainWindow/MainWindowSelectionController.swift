import SwiftData
import SwiftUI
import WorkspaceManagerCore
import os.log

private let workspaceProviderLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceProvider"
)

/// Runs the main window's selection cluster: what happens when a repo, a workspace, or a
/// web source becomes the active surface, and how a dangling selection is repaired after
/// the model changes. The ordering is the behavior — cancel in-flight focus, abandon a
/// pending remote connect, attach or reuse the terminal, record access, navigate, persist
/// continuity, request focus — so it lives here rather than in the view that supplies the
/// collaborators. `Dependencies` is the full coupling surface, stated once.
@MainActor
struct MainWindowSelectionController {
    struct Dependencies {
        let state: Binding<MainWindowViewState>
        let lastSurfaceRawValue: Binding<String>
        let repos: @MainActor () -> [Repo]
        let webSources: @MainActor () -> [WebSource]
        let selectedWorkspace: @MainActor () -> Workspace?
        let selectedWebSource: @MainActor () -> WebSource?
        let selectedRepoForLanding: @MainActor () -> Repo?
        let tileTreeStore: TileTreeStore
        let focusCoordinator: any MainWindowTerminalFocusRequesting
        let smokeDriver: SmokeScenarioDriver
        let webDetailSurfaceStore: SurfaceStore
        let providerRegistry: WorkspaceProviderRegistry
        let providerSetupActionRunner: WorkspaceProviderSetupActionRunner
        let bootstrapController: MainWindowBootstrapController
        let modelContext: ModelContext
        let abandonPendingRemoteConnection: @MainActor (String) -> Void
        let applyNavigationDestination: @MainActor (MainWindowNavigationDestination) -> Void
        let markRepoAccessed: @MainActor (Repo) -> Void
        let markWorkspaceAccessed: @MainActor (Workspace) -> Void
        let markWebSourceAccessed: @MainActor (WebSource) -> Void
        let acknowledgeAttention: @MainActor (WorkspaceStatusAggregator.AttentionTarget) -> Void
        let acknowledgeAgentSession: @MainActor (UUID) -> Void
        let activateHostSession: MainWindowHostSessionActivator
        /// Realizes a session targeting an already-live tmux session by name, for adoption's
        /// bound-session case (#1390) — the same shape `TileTreeStore.createRestoredSession`
        /// gives restore's `reattachTmux` surfaces, since a directory-matched live session is
        /// the same kind of thing to attach to.
        let activateAdoptedHostSession: @MainActor (HostTerminalSessionKey, URL, String) -> HostTerminalSession
        let persistTerminalContinuity: @MainActor (TerminalContinuityManifest.TargetKind, UUID, URL, URL) -> Void
        let restoredLaunchDirectoryForRepo: @MainActor (Repo) -> URL?
        let restoredLaunchDirectoryForWorkspace: @MainActor (Workspace) -> URL?
        let clearCodePreview: @MainActor () -> Void
        let presentWorkspaceOperationError: @MainActor (String) -> Void
    }

    let dependencies: Dependencies

    // MARK: - Launch surfaces

    /// Enter a resolved launch surface (deep link, restore, fallback) through the same
    /// selection paths a click uses, so a restored surface reacts exactly like a chosen one.
    func applyLaunchSurface(_ surface: MainWindowLaunchSurface) {
        switch surface {
        case .repoOverview(let repo):
            selectRepoOverview(repo)
        case .repoTerminal(let repo):
            selectRepoTerminal(repo, preferredDirectory: dependencies.restoredLaunchDirectoryForRepo(repo))
        case .workspace(let workspace):
            selectWorkspace(
                workspace,
                preferredDirectory: dependencies.restoredLaunchDirectoryForWorkspace(workspace)
            )
        case .webView(let source):
            selectWebSource(source)
        }
    }

    // MARK: - Selection

    func selectRepoOverview(_ repo: Repo) {
        dependencies.focusCoordinator.cancelPendingFocusRequest(reason: "repo_overview_selected")
        dependencies.abandonPendingRemoteConnection("repo_overview_selected")
        dependencies.markRepoAccessed(repo)
        dependencies.applyNavigationDestination(.repoOverview(repo))
    }

    func selectRepoTerminal(_ repo: Repo, preferredDirectory: URL? = nil) {
        let repoDirectory = repo.localURL.standardizedFileURL.resolvingSymlinksInPath()
        let launchDirectory = MainWindowPathResolution.preferredSessionDirectory(
            preferredDirectory,
            inside: repoDirectory
        )

        dependencies.focusCoordinator.cancelPendingFocusRequest(reason: "repo_terminal_selected")
        dependencies.abandonPendingRemoteConnection("repo_terminal_selected")
        let session = dependencies.activateHostSession(
            key: .repoPath(repoDirectory.path),
            directory: launchDirectory,
            customCommand: nil
        )
        dependencies.focusCoordinator.beginRepoClickMeasurement(
            sessionID: session.id,
            repoPath: repoDirectory.path
        )
        dependencies.smokeDriver.noteRepoTerminalAttached(
            sessionID: session.id,
            scopePath: repoDirectory.path
        )
        dependencies.markRepoAccessed(repo)
        dependencies.acknowledgeAttention(.repo(repo.id))
        dependencies.applyNavigationDestination(.repoTerminal(repo))
        dependencies.persistTerminalContinuity(.repo, repo.id, repoDirectory, launchDirectory)
        dependencies.focusCoordinator.requestMainTerminalFocus(
            targetSessionID: session.id,
            activateApp: true,
            surfaceStore: dependencies.tileTreeStore.surfaceStore,
            activeSessionID: dependencies.tileTreeStore.activeSessionID,
            onTargetFocused: {
                dependencies.focusCoordinator.completeRepoClickMeasurement(
                    sessionID: session.id,
                    outcome: "focused"
                )
                dependencies.smokeDriver.noteSurfaceFocused(sessionID: session.id)
            }
        )
    }

    /// Warm a local workspace's terminal surface without making it the selection — the
    /// automation create verb's non-selecting arm, which needs a live surface to report
    /// without moving the user off what they are looking at.
    func attachWorkspaceSessionWithoutSelection(_ workspace: Workspace) -> UUID? {
        guard workspace.status == .active else { return nil }
        guard workspace.backend == .local else { return nil }

        let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let session = dependencies.tileTreeStore.ensureSession(
            key: .hostPath(workspaceDirectory.path),
            directory: workspaceDirectory
        ).session
        _ = dependencies.tileTreeStore.terminalSurfaceView(for: session)
        return session.id
    }

    func selectWorkspace(_ workspace: Workspace, preferredDirectory: URL? = nil) {
        dependencies.focusCoordinator.cancelPendingRepoClickMeasurement(reason: "workspace_selected")
        dependencies.focusCoordinator.cancelPendingFocusRequest(reason: "workspace_selected")

        guard workspace.status != .archived else {
            dependencies.abandonPendingRemoteConnection("archived_workspace_selected")
            if let repo = workspace.sourceRepo {
                dependencies.applyNavigationDestination(.repoOverview(repo))
            } else {
                dependencies.state.wrappedValue.selectedWorkspace = nil
            }
            return
        }

        guard workspace.backend == .local else {
            selectProviderBackedWorkspace(workspace)
            return
        }

        dependencies.abandonPendingRemoteConnection("local_workspace_selected")
        let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let launchDirectory = MainWindowPathResolution.preferredSessionDirectory(
            preferredDirectory,
            inside: workspaceDirectory
        )
        let session = dependencies.activateHostSession(
            key: .hostPath(workspaceDirectory.path),
            directory: launchDirectory,
            customCommand: nil
        )
        finishSelectingLocalWorkspace(
            workspace,
            session: session,
            workspaceDirectory: workspaceDirectory,
            launchDirectory: launchDirectory
        )
    }

    /// Adoption's counterpart to `selectWorkspace` (#1390): the workspace's directory was just
    /// recorded, so there is no continuity row to restore from, but a live tmux session found by
    /// directory match is exactly what a restored `reattachTmux` surface targets — same launch
    /// shape, reached from a different origin. `boundTmuxSessionName` is `nil` when no single
    /// live session matched the worktree, in which case this opens a plain shell like any other
    /// freshly created workspace.
    ///
    /// Adoption only ever creates a local, active workspace, so this skips the archived and
    /// provider-backed branches `selectWorkspace` carries for a click on existing data — the
    /// fallback exists only so a future adoption source that produced something else degrades
    /// to the general path instead of misbehaving.
    func selectAdoptedWorkspace(_ workspace: Workspace, boundTmuxSessionName: String?) {
        guard workspace.status == .active, workspace.backend == .local else {
            selectWorkspace(workspace)
            return
        }

        dependencies.focusCoordinator.cancelPendingRepoClickMeasurement(reason: "workspace_adopted")
        dependencies.focusCoordinator.cancelPendingFocusRequest(reason: "workspace_adopted")
        dependencies.abandonPendingRemoteConnection("workspace_adopted")

        let workspaceDirectory = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
        let session: HostTerminalSession
        if let boundTmuxSessionName {
            session = dependencies.activateAdoptedHostSession(
                .hostPath(workspaceDirectory.path),
                workspaceDirectory,
                boundTmuxSessionName
            )
        } else {
            session = dependencies.activateHostSession(
                key: .hostPath(workspaceDirectory.path),
                directory: workspaceDirectory,
                customCommand: nil
            )
        }
        finishSelectingLocalWorkspace(
            workspace,
            session: session,
            workspaceDirectory: workspaceDirectory,
            launchDirectory: workspaceDirectory
        )
    }

    /// The half of selecting a local workspace that does not depend on how its session was
    /// obtained: measurement, access bookkeeping, navigation, continuity, and focus. Shared by
    /// `selectWorkspace` and `selectAdoptedWorkspace` so the two ways a session can be created
    /// stay behaviorally identical everywhere after that point.
    private func finishSelectingLocalWorkspace(
        _ workspace: Workspace,
        session: HostTerminalSession,
        workspaceDirectory: URL,
        launchDirectory: URL
    ) {
        dependencies.focusCoordinator.beginWorkspaceClickMeasurement(
            sessionID: session.id,
            workspacePath: workspaceDirectory.path
        )
        dependencies.smokeDriver.noteWorkspaceTerminalAttached(
            sessionID: session.id,
            scopePath: workspaceDirectory.path
        )
        dependencies.markWorkspaceAccessed(workspace)
        dependencies.acknowledgeAttention(.workspace(workspace.id))
        dependencies.applyNavigationDestination(.workspaceTerminal(workspace))
        dependencies.persistTerminalContinuity(
            .workspace,
            workspace.id,
            workspaceDirectory,
            launchDirectory
        )
        dependencies.focusCoordinator.requestMainTerminalFocus(
            targetSessionID: session.id,
            activateApp: true,
            surfaceStore: dependencies.tileTreeStore.surfaceStore,
            activeSessionID: dependencies.tileTreeStore.activeSessionID,
            onTargetFocused: {
                dependencies.focusCoordinator.completeWorkspaceClickMeasurement(
                    sessionID: session.id,
                    outcome: "focused"
                )
                dependencies.smokeDriver.noteSurfaceFocused(sessionID: session.id)
            }
        )
    }

    /// A remote-backed workspace: reuse a live session in its scope when there is one,
    /// otherwise run provider setup and connect.
    func selectProviderBackedWorkspace(_ workspace: Workspace) {
        guard let provider = dependencies.providerRegistry.provider(for: workspace) else {
            dependencies.presentWorkspaceOperationError(
                "No workspace provider is registered for '\(workspace.backendIdentifier)'."
            )
            return
        }

        let providerTarget = WorkspaceProviderTarget(workspace)
        let sessionKey = provider.sessionKey(for: providerTarget)
        if workspace.status == .active,
            let existing = dependencies.tileTreeStore.activeSession(inScope: sessionKey)
        {
            dependencies.abandonPendingRemoteConnection("remote_workspace_reused_existing_session")
            dependencies.markWorkspaceAccessed(workspace)
            dependencies.acknowledgeAttention(.workspace(workspace.id))
            dependencies.applyNavigationDestination(.workspaceTerminal(workspace))
            dependencies.tileTreeStore.activateExistingSession(sessionID: existing.id)
            dependencies.acknowledgeAgentSession(existing.id)
            dependencies.focusCoordinator.requestMainTerminalFocus(
                targetSessionID: existing.id,
                activateApp: true,
                surfaceStore: dependencies.tileTreeStore.surfaceStore,
                activeSessionID: dependencies.tileTreeStore.activeSessionID,
                onTargetFocused: nil
            )
            return
        }

        Task { @MainActor in
            do {
                try await dependencies.providerSetupActionRunner.run(
                    provider: provider,
                    action: .openTerminal(workspaceName: workspace.name)
                ) {
                    await connectToProviderBackedWorkspace(workspace, provider: provider)
                }
            } catch {
                dependencies.presentWorkspaceOperationError(error.localizedDescription)
            }
        }
    }

    /// Ask the provider for a launch spec and open the session. `connectingWorkspaceID`
    /// is the in-flight token: every resumption re-checks it, so a selection that moved on
    /// while the provider was working lands nothing.
    func connectToProviderBackedWorkspace(
        _ workspace: Workspace,
        provider: any WorkspaceProviderProtocol
    ) async {
        dependencies.state.wrappedValue.connectingWorkspaceID = workspace.id

        do {
            let launchSpec = try await provider.terminalLaunchSpec(for: WorkspaceProviderTarget(workspace))

            guard dependencies.state.wrappedValue.connectingWorkspaceID == workspace.id else { return }
            dependencies.state.wrappedValue.connectingWorkspaceID = nil
            workspace.status = launchSpec.statusAfterLaunch
            try? dependencies.modelContext.save()
            let session = dependencies.activateHostSession(
                key: launchSpec.sessionKey,
                directory: launchSpec.workingDirectory,
                customCommand: launchSpec.customCommand
            )
            dependencies.applyNavigationDestination(.workspaceTerminal(workspace))
            dependencies.state.wrappedValue.columnVisibility = .all
            dependencies.acknowledgeAttention(.workspace(workspace.id))
            dependencies.focusCoordinator.requestMainTerminalFocus(
                targetSessionID: session.id,
                activateApp: true,
                surfaceStore: dependencies.tileTreeStore.surfaceStore,
                activeSessionID: dependencies.tileTreeStore.activeSessionID,
                onTargetFocused: nil
            )
            workspaceProviderLog.info(
                "[WorkspaceProvider] Session created for \(workspace.backendIdentifier, privacy: .public) workspace \(workspace.name, privacy: .public)"
            )
        } catch {
            workspaceProviderLog.error(
                "[WorkspaceProvider] Failed to connect to \(workspace.backendIdentifier, privacy: .public) workspace \(workspace.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            guard dependencies.state.wrappedValue.connectingWorkspaceID == workspace.id else { return }
            dependencies.state.wrappedValue.connectingWorkspaceID = nil
            dependencies.presentWorkspaceOperationError(error.localizedDescription)
        }
    }

    func selectWebSource(_ source: WebSource) {
        dependencies.state.wrappedValue.connectingWorkspaceID = nil
        dependencies.focusCoordinator.cancelPendingRepoClickMeasurement(reason: "web_source_selected")
        dependencies.focusCoordinator.cancelPendingFocusRequest(reason: "web_source_selected")
        dependencies.abandonPendingRemoteConnection("web_source_selected")
        dependencies.applyNavigationDestination(.webView(source))
        // Reselecting inside the deferred-release window rescues the source's live page before the
        // pane re-mounts (mounting would cancel too; this makes the intent explicit and immediate).
        dependencies.webDetailSurfaceStore.webStore(forSourceID: source.id).cancelPendingRelease()
        dependencies.markWebSourceAccessed(source)
    }

    // MARK: - Reconciliation

    /// Repair a selection the model no longer contains. Web source first, then workspace,
    /// then landing repo: a single model change can invalidate only one of them, and each
    /// arm resolves to a fallback surface before the next is considered.
    func reconcileSelectionAfterModelChange() {
        clearInvalidLastSurfaceIfNeeded()

        if let selectedWebSource = dependencies.state.wrappedValue.selectedWebSource,
            dependencies.selectedWebSource() == nil
        {
            dependencies.state.wrappedValue.selectedWebSource = nil
            // Hard release happens in the view's deletion diff (release authority);
            // this path only repairs the dangling selection.
            handleSelectedWebSourceRemoval(selectedWebSource)
            return
        }

        if let selectedWorkspace = dependencies.state.wrappedValue.selectedWorkspace,
            dependencies.selectedWorkspace() == nil
        {
            handleSelectedWorkspaceRemoval(selectedWorkspace)
            return
        }

        if dependencies.state.wrappedValue.selectedRepoForLandingID != nil,
            dependencies.selectedRepoForLanding() == nil
        {
            handleSelectedRepoRemoval()
        }
    }

    func clearInvalidLastSurfaceIfNeeded() {
        dependencies.lastSurfaceRawValue.wrappedValue =
            dependencies.bootstrapController.sanitizedLastSurfaceRawValue(
                rawValue: dependencies.lastSurfaceRawValue.wrappedValue,
                repos: dependencies.repos(),
                webSources: dependencies.webSources()
            )
    }

    func handleSelectedWorkspaceRemoval(_ removedWorkspace: MainWindowWorkspaceSelection) {
        dependencies.state.wrappedValue.selectedWorkspace = nil
        dependencies.clearCodePreview()

        if let surface = dependencies.bootstrapController.fallbackSurfaceAfterRemovingWorkspace(
            repoID: removedWorkspace.repoID,
            repos: dependencies.repos(),
            webSources: dependencies.webSources()
        ) {
            dependencies.state.wrappedValue.didResolveInitialSurface = true
            applyLaunchSurface(surface)
            return
        }

        dependencies.state.wrappedValue.didResolveInitialSurface = false
    }

    func handleSelectedRepoRemoval() {
        dependencies.state.wrappedValue.selectedRepoForLandingID = nil
        dependencies.clearCodePreview()

        applyFallbackAfterInvalidSelection()
    }

    func applyFallbackAfterInvalidSelection() {
        dependencies.state.wrappedValue.didResolveInitialSurface = false
        if let surface = dependencies.bootstrapController.fallbackSurface(
            repos: dependencies.repos(),
            webSources: dependencies.webSources()
        ) {
            dependencies.state.wrappedValue.didResolveInitialSurface = true
            applyLaunchSurface(surface)
        }
    }

    func handleSelectedWebSourceRemoval(_ source: MainWindowWebSourceSelection) {
        // The restore path's rule — an empty array is not evidence — deliberately
        // does not apply here (#845). This runs from `reconcileSelectionAfterModelChange`,
        // which fires *because* a model change was observed, and only for a source
        // that was selected and is therefore known to have been present. That
        // sequence is the delivery evidence the launch path lacks. Requiring a
        // non-empty array here would refuse to clear when the removed source was
        // the last one, which is the ordinary case.
        if let lastSurface = MainWindowLastSurface.decode(from: dependencies.lastSurfaceRawValue.wrappedValue),
            lastSurface.kind == .webView,
            lastSurface.id == source.webSourceID
        {
            dependencies.lastSurfaceRawValue.wrappedValue = ""
        }

        dependencies.state.wrappedValue.didResolveInitialSurface = false
        if let surface = dependencies.bootstrapController.fallbackSurfaceAfterRemovingWebSource(
            ownerWorkspaceID: source.ownerWorkspaceID,
            ownerRepoID: source.ownerRepoID,
            repos: dependencies.repos()
        ) {
            dependencies.state.wrappedValue.didResolveInitialSurface = true
            applyLaunchSurface(surface)
        }
    }
}
