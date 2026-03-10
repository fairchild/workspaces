import Foundation
import WorkspaceManagerCore

struct MainWindowBootstrapController {
    enum DeepLinkDecision {
        case none
        case waitForRepos(WorkspaceDeepLink)
        case clearNoMatch(WorkspaceDeepLink)
        case select(request: WorkspaceDeepLink, workspace: Workspace)
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
            return .select(request: pendingRequest, workspace: workspace)
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
            guard let repo = repos.first(where: { $0.id == savedSurface.id }) else {
                return .clearInvalid
            }
            return .select(.repoOverview(repo))

        case .repoTerminal:
            guard let repo = repos.first(where: { $0.id == savedSurface.id }) else {
                return .clearInvalid
            }
            return .select(.repoTerminal(repo))

        case .workspaceTerminal:
            let workspace =
                repos
                .flatMap(\.workspaces)
                .first(where: { $0.id == savedSurface.id })
            guard let workspace else {
                return .clearInvalid
            }
            return .select(.workspace(workspace))

        case .webView:
            guard let source = webSources.first(where: { $0.id == savedSurface.id }) else {
                return .clearInvalid
            }
            return .select(.webView(source))
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
