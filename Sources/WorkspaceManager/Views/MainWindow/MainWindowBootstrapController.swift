import Foundation
import WorkspaceManagerCore

struct MainWindowBootstrapController {
    enum DeepLinkDecision {
        case none
        case waitForRepos(WorkspaceDeepLink)
        case clearNoMatch(WorkspaceDeepLink)
        case selectWorkspace(request: WorkspaceDeepLink, workspace: Workspace)
        case selectRepo(request: WorkspaceDeepLink, repo: Repo)
        case importRepo(request: WorkspaceDeepLink, repoRoot: String)
    }

    enum PreviewBootstrapDecision {
        case none
        case noMatch(configuration: UIFixturePreviewBootstrapConfiguration)
        case apply(
            configuration: UIFixturePreviewBootstrapConfiguration,
            repo: Repo,
            selection: CodePreviewSelection
        )
    }

    enum WebBootstrapDecision {
        case none
        case noMatch(targetName: String)
        case select(targetName: String, source: WebSource)
    }

    enum RestoredSurfaceDecision {
        case none
        case clearInvalid
        case select(MainWindowLaunchSurface)
    }

    private let selectionCoordinator = MainSelectionCoordinator()

    func deepLinkDecision(
        pendingRequest: WorkspaceDeepLink?,
        repos: [Repo],
        normalizePath: (String) -> String,
        pathIsInside: (String, String) -> Bool
    ) -> DeepLinkDecision {
        guard let pendingRequest else {
            return .none
        }

        if let workspace = selectionCoordinator.bestWorkspaceMatch(
            for: pendingRequest.cwd,
            repos: repos,
            normalizePath: normalizePath,
            pathIsInside: pathIsInside
        ) {
            return .selectWorkspace(request: pendingRequest, workspace: workspace)
        }

        if let repo = selectionCoordinator.bestRepoMatch(
            for: pendingRequest.cwd,
            repoRoot: pendingRequest.repoRoot,
            repos: repos,
            normalizePath: normalizePath,
            pathIsInside: pathIsInside
        ) {
            return .selectRepo(request: pendingRequest, repo: repo)
        }

        if let repoRoot = pendingRequest.repoRoot {
            return .importRepo(request: pendingRequest, repoRoot: repoRoot)
        }

        return repos.isEmpty ? .waitForRepos(pendingRequest) : .clearNoMatch(pendingRequest)
    }

    func perfAutoSelectedRepo(
        environment: [String: String],
        didRun: Bool,
        pendingRequest: WorkspaceDeepLink?,
        repos: [Repo]
    ) -> Repo? {
        guard environment["WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO"] == "1" else { return nil }
        guard !didRun else { return nil }
        guard pendingRequest == nil else { return nil }
        return repos.first
    }

    func previewBootstrapDecision(
        didApply: Bool,
        pendingRequest: WorkspaceDeepLink?,
        configuration: UIFixturePreviewBootstrapConfiguration?,
        repos: [Repo]
    ) -> PreviewBootstrapDecision {
        guard !didApply else { return .none }
        guard pendingRequest == nil else { return .none }
        guard let configuration else { return .none }
        guard !repos.isEmpty else { return .none }

        guard
            let resolved = UIFixturePreviewBootstrap.resolveSelection(
                configuration: configuration,
                repos: repos
            )
        else {
            return .noMatch(configuration: configuration)
        }

        return .apply(
            configuration: configuration,
            repo: resolved.repo,
            selection: resolved.selection
        )
    }

    func webBootstrapDecision(
        didApply: Bool,
        pendingRequest: WorkspaceDeepLink?,
        configuration: UIFixtureWebBootstrapConfiguration?,
        webSources: [WebSource]
    ) -> WebBootstrapDecision {
        guard !didApply else { return .none }
        guard pendingRequest == nil else { return .none }
        guard let configuration else { return .none }
        guard !webSources.isEmpty else { return .none }

        let targetName = configuration.webSourceName
        let selectedSource =
            webSources.first(where: { $0.name.caseInsensitiveCompare(targetName) == .orderedSame })
            ?? webSources.first(where: { $0.name.localizedCaseInsensitiveContains(targetName) })
            ?? webSources.first

        guard let selectedSource else {
            return .noMatch(targetName: targetName)
        }

        return .select(targetName: targetName, source: selectedSource)
    }

    func restoredSurfaceDecision(
        rawValue: String,
        repos: [Repo],
        webSources: [WebSource]
    ) -> RestoredSurfaceDecision {
        guard let savedSurface = MainWindowLastSurface.decode(from: rawValue) else {
            return .none
        }

        switch savedSurface.kind {
        case .repoOverview:
            guard let repo = selectionCoordinator.repo(with: savedSurface.id, in: repos) else {
                return .clearInvalid
            }
            return .select(.repoOverview(repo))

        case .repoTerminal:
            guard let repo = selectionCoordinator.repo(with: savedSurface.id, in: repos) else {
                return .clearInvalid
            }
            return .select(.repoTerminal(repo))

        case .workspaceTerminal:
            guard let workspace = selectionCoordinator.workspace(with: savedSurface.id, in: repos) else {
                return .clearInvalid
            }
            return .select(.workspace(workspace))

        case .webView:
            guard let source = selectionCoordinator.webSource(with: savedSurface.id, in: webSources) else {
                return .clearInvalid
            }
            return .select(.webView(source))
        }
    }

    func sanitizedLastSurfaceRawValue(
        rawValue: String,
        repos: [Repo],
        webSources: [WebSource]
    ) -> String {
        switch restoredSurfaceDecision(rawValue: rawValue, repos: repos, webSources: webSources) {
        case .clearInvalid:
            return ""
        case .none, .select:
            return rawValue
        }
    }

    func fallbackSurface(
        repos: [Repo],
        webSources: [WebSource]
    ) -> MainWindowLaunchSurface? {
        if let workspace =
            repos
            .flatMap(\.workspaces)
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first
        {
            return .workspace(workspace)
        }

        if let source =
            webSources
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first
        {
            return .webView(source)
        }

        guard let repo = repos.first else { return nil }
        return .repoOverview(repo)
    }

    func fallbackSurfaceAfterRemovingWorkspace(
        repoID: UUID?,
        repos: [Repo],
        webSources: [WebSource]
    ) -> MainWindowLaunchSurface? {
        if let repo = selectionCoordinator.repo(with: repoID, in: repos) {
            return .repoOverview(repo)
        }

        return fallbackSurface(repos: repos, webSources: webSources)
    }

    func fallbackSurfaceAfterRemovingWebSource(
        ownerWorkspaceID: UUID?,
        ownerRepoID: UUID?,
        repos: [Repo]
    ) -> MainWindowLaunchSurface? {
        if let workspace = selectionCoordinator.workspace(with: ownerWorkspaceID, in: repos) {
            return .workspace(workspace)
        }

        if let repo = selectionCoordinator.repo(with: ownerRepoID, in: repos) {
            return .repoOverview(repo)
        }

        return nonWebFallbackSurface(repos: repos)
    }

    func nonWebFallbackSurface(repos: [Repo]) -> MainWindowLaunchSurface? {
        if let workspace =
            repos
            .flatMap(\.workspaces)
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first
        {
            return .workspace(workspace)
        }

        guard let repo = repos.first else { return nil }
        return .repoOverview(repo)
    }
}
