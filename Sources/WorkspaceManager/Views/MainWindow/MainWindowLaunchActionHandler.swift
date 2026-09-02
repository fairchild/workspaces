import Foundation
import WorkspaceManagerCore
import os.log

private let log = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "MainWindowLaunchActionHandler"
)

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
        /// Applies a surface for display without recording it as the last surface.
        let applyProvisionalLaunchSurface: (MainWindowLaunchSurface) -> Void
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
            log.error("[DeepLink] No workspace match for cwd: \(request.cwd, privacy: .public)")
            actions.clearDeepLink()
            return true

        case .selectDeepLinkedWorkspace(let request, let workspace):
            log.info(
                "[DeepLink] Matched workspace '\(workspace.name, privacy: .public)' for cwd '\(request.cwd, privacy: .public)' (session_id=\(request.sessionID ?? "", privacy: .public) source=\(request.source ?? "", privacy: .public))"
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
            log.info(
                "[DeepLink] Matched repo '\(repo.name, privacy: .public)' for cwd '\(request.cwd, privacy: .public)' (session_id=\(request.sessionID ?? "", privacy: .public) source=\(request.source ?? "", privacy: .public))"
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
                log.error(
                    "[DeepLink] Failed to import repo for cwd '\(request.cwd, privacy: .public)' repo_root='\(repoRoot, privacy: .public)'"
                )
                actions.clearDeepLink()
                return true
            }

            log.info(
                "[DeepLink] Imported repo '\(repo.name, privacy: .public)' for cwd '\(request.cwd, privacy: .public)' (repo_root=\(repoRoot, privacy: .public))"
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
            log.error(
                "[UIFixture] Preview bootstrap skipped (repo=\(configuration.repoName, privacy: .public) path=\(configuration.relativePath, privacy: .public))"
            )
            return true

        case .applyPreviewBootstrap(_, let repo, let selection):
            state.didApplyFixturePreviewBootstrap = true
            state.didResolveInitialSurface = true
            actions.selectRepoTerminal(repo, nil)
            state.selectedCodePreview = selection
            state.isTerminalPanelVisible = true
            state.isRightPaneVisible = true
            log.info(
                "[UIFixture] Preview bootstrap applied (repo=\(repo.name, privacy: .public) file=\(selection.relativePath, privacy: .public))"
            )
            return false

        case .recordMissingWebBootstrap(let targetName):
            state.didApplyFixtureWebBootstrap = true
            log.error("[UIFixture] Web bootstrap skipped (target=\(targetName, privacy: .public))")
            return true

        case .applyWebBootstrap(let targetName, let selectedSource):
            state.didApplyFixtureWebBootstrap = true
            state.didResolveInitialSurface = true
            actions.selectWebSource(selectedSource)
            log.info(
                "[UIFixture] Web bootstrap applied (target=\(targetName, privacy: .public) selected=\(selectedSource.name, privacy: .public))"
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

        case .provisionalFallback(let surface):
            // Deliberately leaves `didResolveInitialSurface` false: the launch has
            // not resolved while a saved surface is still waiting for the models
            // that would judge it, and the next delivery must be allowed to run
            // this resolution again (#845).
            actions.applyProvisionalLaunchSurface(surface)
            return false
        }
    }
}
