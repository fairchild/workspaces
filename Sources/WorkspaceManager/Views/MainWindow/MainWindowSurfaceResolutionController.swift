import Foundation
import WorkspaceManagerCore

struct MainWindowSurfaceResolutionContext {
    let environment: [String: String]
    let didRunPerfAutoSelection: Bool
    let didApplyFixturePreviewBootstrap: Bool
    let didApplyFixtureWebBootstrap: Bool
    let didResolveInitialSurface: Bool
    let pendingRequest: WorkspaceDeepLink?
    let lastSurfaceRawValue: String
    let previewConfiguration: UIFixturePreviewBootstrapConfiguration?
    let webConfiguration: UIFixtureWebBootstrapConfiguration?
    let repos: [Repo]
    let webSources: [WebSource]
}

enum MainWindowSurfaceResolutionAction {
    case none
    case waitForRepos
    case clearDeepLinkNoMatch(WorkspaceDeepLink)
    case selectDeepLinkedWorkspace(WorkspaceDeepLink, Workspace)
    case selectDeepLinkedRepo(WorkspaceDeepLink, Repo)
    case importDeepLinkedRepo(WorkspaceDeepLink, String)
    case perfAutoSelect(Repo)
    case recordMissingPreviewBootstrap(UIFixturePreviewBootstrapConfiguration)
    case applyPreviewBootstrap(UIFixturePreviewBootstrapConfiguration, Repo, CodePreviewSelection)
    case recordMissingWebBootstrap(String)
    case applyWebBootstrap(String, WebSource)
    case clearInvalidLastSurface
    case restore(MainWindowLaunchSurface)
    case fallback(MainWindowLaunchSurface)
}

struct MainWindowSurfaceResolutionController {
    /// The bootstrap controller is injected per call rather than constructed here, so the
    /// root view's single instance is the only one driving startup/selection-restore logic.
    func nextAction(
        context: MainWindowSurfaceResolutionContext,
        bootstrapController: MainWindowBootstrapController
    ) -> MainWindowSurfaceResolutionAction {
        switch bootstrapController.deepLinkDecision(
            pendingRequest: context.pendingRequest,
            repos: context.repos,
            normalizePath: normalizePath(_:),
            pathIsInside: path(_:isInside:)
        ) {
        case .none:
            break
        case .waitForRepos:
            return .waitForRepos
        case .clearNoMatch(let request):
            return .clearDeepLinkNoMatch(request)
        case .selectWorkspace(let request, let workspace):
            return .selectDeepLinkedWorkspace(request, workspace)
        case .selectRepo(let request, let repo):
            return .selectDeepLinkedRepo(request, repo)
        case .importRepo(let request, let repoRoot):
            return .importDeepLinkedRepo(request, repoRoot)
        }

        guard !context.didResolveInitialSurface else { return .none }

        if let repo = bootstrapController.perfAutoSelectedRepo(
            environment: context.environment,
            didRun: context.didRunPerfAutoSelection,
            pendingRequest: context.pendingRequest,
            repos: context.repos
        ) {
            return .perfAutoSelect(repo)
        }
        if bootstrapController.shouldWaitForPerfAutoSelectedRepo(
            environment: context.environment,
            didRun: context.didRunPerfAutoSelection,
            pendingRequest: context.pendingRequest,
            repos: context.repos
        ) {
            return .waitForRepos
        }

        switch bootstrapController.previewBootstrapDecision(
            didApply: context.didApplyFixturePreviewBootstrap,
            pendingRequest: context.pendingRequest,
            configuration: context.previewConfiguration,
            repos: context.repos
        ) {
        case .none:
            break
        case .noMatch(let configuration):
            return .recordMissingPreviewBootstrap(configuration)
        case .apply(let configuration, let repo, let selection):
            return .applyPreviewBootstrap(configuration, repo, selection)
        }

        switch bootstrapController.webBootstrapDecision(
            didApply: context.didApplyFixtureWebBootstrap,
            pendingRequest: context.pendingRequest,
            configuration: context.webConfiguration,
            webSources: context.webSources
        ) {
        case .none:
            break
        case .noMatch(let targetName):
            return .recordMissingWebBootstrap(targetName)
        case .select(let targetName, let source):
            return .applyWebBootstrap(targetName, source)
        }

        switch bootstrapController.restoredSurfaceDecision(
            rawValue: context.lastSurfaceRawValue,
            repos: context.repos,
            webSources: context.webSources
        ) {
        case .none:
            break
        case .clearInvalid:
            return .clearInvalidLastSurface
        case .select(let surface):
            return .restore(surface)
        }

        let fallback = bootstrapController.fallbackSurface(
            repos: context.repos,
            webSources: context.webSources
        )
        guard let fallback else {
            return .none
        }

        return .fallback(fallback)
    }

    private func normalizePath(_ rawPath: String) -> String {
        URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func path(_ path: String, isInside root: String) -> Bool {
        if path == root { return true }
        guard root != "/" else { return true }
        return path.hasPrefix(root + "/")
    }
}
