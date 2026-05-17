import Foundation
import WorkspaceManagerCore

@MainActor
struct MainWindowLaunchActionHandler {
    struct Actions {
        let clearDeepLink: () -> Void
        let clearLastSurface: () -> Void
        let discardPendingRemoteConnection: (String) -> Void
        let importRepo: (String) -> Repo?
        let selectWorkspace: (Workspace, URL?) -> Void
        let selectRepoTerminal: (Repo, URL?) -> Void
        let selectWebSource: (WebSource) -> Void
        let applyLaunchSurface: (MainWindowLaunchSurface) -> Void
        let schedulePerfAutoSelect: (Repo, Bool) -> Void
        let focusWorkspaceWindow: () -> Void
    }

    @discardableResult
    func apply(
        _ action: MainWindowSurfaceResolutionAction,
        state: inout MainWindowViewState,
        environment: [String: String],
        pendingRequest: WorkspaceDeepLink?,
        bootstrapController: MainWindowBootstrapController,
        actions: Actions
    ) -> Bool {
        switch action {
        case .none, .waitForRepos:
            return false

        case .clearDeepLinkNoMatch(let request):
            NSLog("[DeepLink] No workspace match for cwd: %@", request.cwd)
            actions.clearDeepLink()
            return true

        case .selectDeepLinkedWorkspace(let request, let workspace):
            NSLog(
                "[DeepLink] Matched workspace '%@' for cwd '%@' (session_id=%@ source=%@)",
                workspace.name,
                request.cwd,
                request.sessionID ?? "",
                request.source ?? ""
            )
            actions.discardPendingRemoteConnection("deep_link_selected")
            actions.selectWorkspace(
                workspace,
                URL(fileURLWithPath: request.cwd, isDirectory: true)
            )
            actions.clearDeepLink()
            state.didResolveInitialSurface = true
            actions.focusWorkspaceWindow()
            return false

        case .selectDeepLinkedRepo(let request, let repo):
            NSLog(
                "[DeepLink] Matched repo '%@' for cwd '%@' (session_id=%@ source=%@)",
                repo.name,
                request.cwd,
                request.sessionID ?? "",
                request.source ?? ""
            )
            actions.discardPendingRemoteConnection("deep_link_selected")
            actions.selectRepoTerminal(
                repo,
                URL(fileURLWithPath: request.cwd, isDirectory: true)
            )
            actions.clearDeepLink()
            state.didResolveInitialSurface = true
            actions.focusWorkspaceWindow()
            return false

        case .importDeepLinkedRepo(let request, let repoRoot):
            guard let repo = actions.importRepo(repoRoot) else {
                NSLog("[DeepLink] Failed to import repo for cwd '%@' repo_root='%@'", request.cwd, repoRoot)
                actions.clearDeepLink()
                return true
            }

            NSLog(
                "[DeepLink] Imported repo '%@' for cwd '%@' (repo_root=%@)",
                repo.name,
                request.cwd,
                repoRoot
            )
            actions.discardPendingRemoteConnection("deep_link_repo_imported")
            actions.selectRepoTerminal(
                repo,
                URL(fileURLWithPath: request.cwd, isDirectory: true)
            )
            actions.clearDeepLink()
            state.didResolveInitialSurface = true
            actions.focusWorkspaceWindow()
            return false

        case .perfAutoSelect(let repo):
            let shouldAutoOpenNewWorkspace = bootstrapController.shouldPerfAutoOpenNewWorkspace(
                environment: environment,
                didRun: state.didRunPerfAutoOpenNewWorkspace,
                pendingRequest: pendingRequest
            )
            state.didRunPerfAutoSelection = true
            if shouldAutoOpenNewWorkspace {
                state.didRunPerfAutoOpenNewWorkspace = true
            }
            actions.schedulePerfAutoSelect(repo, shouldAutoOpenNewWorkspace)
            return false

        case .recordMissingPreviewBootstrap(let configuration):
            state.didApplyFixturePreviewBootstrap = true
            NSLog(
                "[UIFixture] Preview bootstrap skipped (repo=%@ path=%@)",
                configuration.repoName,
                configuration.relativePath
            )
            return true

        case .applyPreviewBootstrap(_, let repo, let selection):
            state.didApplyFixturePreviewBootstrap = true
            state.didResolveInitialSurface = true
            actions.selectRepoTerminal(repo, nil)
            state.selectedCodePreview = selection
            state.isTerminalPanelVisible = true
            state.isRightPaneVisible = true
            NSLog(
                "[UIFixture] Preview bootstrap applied (repo=%@ file=%@)",
                repo.name,
                selection.relativePath
            )
            return false

        case .recordMissingWebBootstrap(let targetName):
            state.didApplyFixtureWebBootstrap = true
            NSLog("[UIFixture] Web bootstrap skipped (target=%@)", targetName)
            return true

        case .applyWebBootstrap(let targetName, let selectedSource):
            state.didApplyFixtureWebBootstrap = true
            state.didResolveInitialSurface = true
            actions.selectWebSource(selectedSource)
            NSLog(
                "[UIFixture] Web bootstrap applied (target=%@ selected=%@)",
                targetName,
                selectedSource.name
            )
            return false

        case .clearInvalidLastSurface:
            actions.clearLastSurface()
            return true

        case .restore(let surface):
            state.didResolveInitialSurface = true
            actions.applyLaunchSurface(surface)
            return false

        case .fallback(let surface):
            state.didResolveInitialSurface = true
            actions.applyLaunchSurface(surface)
            return false
        }
    }
}
