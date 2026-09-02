import Foundation
import WorkspaceManagerCore

struct MainWindowBootstrapController {
    private static let perfAutoSelectFlagKey = "WORKSPACES_PERF_AUTO_SELECT_FIRST_REPO"
    private static let perfAutoSelectRepoPathKey = "WORKSPACES_PERF_AUTO_SELECT_REPO_PATH"

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
        /// The collection this surface would be resolved against is empty, so
        /// its absence proves nothing. Neither restore nor clear; ask again when
        /// there is something to ask against (#845).
        case awaitingModels
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
        guard environment[Self.perfAutoSelectFlagKey] == "1" else { return nil }
        guard !didRun else { return nil }
        guard pendingRequest == nil else { return nil }
        if let targetPath = Self.perfAutoSelectRepoPath(environment: environment) {
            return repos.first { Self.normalizedPath($0.localPath) == targetPath }
        }
        return repos.first
    }

    func shouldWaitForPerfAutoSelectedRepo(
        environment: [String: String],
        didRun: Bool,
        pendingRequest: WorkspaceDeepLink?,
        repos: [Repo]
    ) -> Bool {
        guard environment[Self.perfAutoSelectFlagKey] == "1" else { return false }
        guard !didRun else { return false }
        guard pendingRequest == nil else { return false }
        guard Self.perfAutoSelectRepoPath(environment: environment) != nil else { return false }
        return perfAutoSelectedRepo(
            environment: environment,
            didRun: didRun,
            pendingRequest: pendingRequest,
            repos: repos
        ) == nil
    }

    func shouldPerfAutoOpenNewWorkspace(
        environment: [String: String],
        didRun: Bool,
        pendingRequest: WorkspaceDeepLink?
    ) -> Bool {
        guard environment[Self.perfAutoSelectFlagKey] == "1" else { return false }
        guard environment["WORKSPACES_PERF_AUTO_OPEN_NEW_WORKSPACE"] == "1" else { return false }
        guard !didRun else { return false }
        guard pendingRequest == nil else { return false }
        return true
    }

    private static func perfAutoSelectRepoPath(environment: [String: String]) -> String? {
        guard let rawValue = environment[perfAutoSelectRepoPathKey] else { return nil }
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        return normalizedPath(trimmedValue)
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        return URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath().path
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

    /// Decides what a persisted last surface is worth against the current query
    /// arrays: restore it, erase it, or say the question cannot be answered yet.
    ///
    /// The third answer is the one #845 is about. Erasing the raw value is
    /// destructive and silent — the user's saved place is gone and the app looks
    /// like it simply lost it — so it may only follow from evidence, and an empty
    /// collection is not evidence. A missing id proves absence once the store has
    /// delivered; before then, "no repos" and "no such repo" are the same
    /// reading. Each kind is therefore gated on the collection its own lookup
    /// walks: a delivered repo list says nothing about a web source still in
    /// flight, and vice versa.
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
            guard !repos.isEmpty else { return .awaitingModels }
            guard let repo = selectionCoordinator.repo(with: savedSurface.id, in: repos) else {
                return .clearInvalid
            }
            return .select(.repoOverview(repo))

        case .repoTerminal:
            guard !repos.isEmpty else { return .awaitingModels }
            guard let repo = selectionCoordinator.repo(with: savedSurface.id, in: repos) else {
                return .clearInvalid
            }
            return .select(.repoTerminal(repo))

        case .workspaceTerminal:
            // Workspaces are reached through their repos, so the repo list is the
            // delivery this lookup depends on. A delivered repo holding no
            // workspaces is a real answer; no repos at all is not one yet.
            guard !repos.isEmpty else { return .awaitingModels }
            guard let workspace = selectionCoordinator.workspace(with: savedSurface.id, in: repos),
                workspace.status != .archived
            else {
                return .clearInvalid
            }
            return .select(.workspace(workspace))

        case .webView:
            guard !webSources.isEmpty else { return .awaitingModels }
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
        case .none, .awaitingModels, .select:
            return rawValue
        }
    }

    func fallbackSurface(
        repos: [Repo],
        webSources: [WebSource]
    ) -> MainWindowLaunchSurface? {
        let workspace =
            repos
            .flatMap(\.workspaces)
            .filter { $0.status != .archived }
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first
        if let workspace {
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
        if let workspace = selectionCoordinator.workspace(with: ownerWorkspaceID, in: repos),
            workspace.status != .archived
        {
            return .workspace(workspace)
        }

        if let repo = selectionCoordinator.repo(with: ownerRepoID, in: repos) {
            return .repoOverview(repo)
        }

        return nonWebFallbackSurface(repos: repos)
    }

    func nonWebFallbackSurface(repos: [Repo]) -> MainWindowLaunchSurface? {
        let workspace =
            repos
            .flatMap(\.workspaces)
            .filter { $0.status != .archived }
            .sorted(by: { $0.lastAccessedAt > $1.lastAccessedAt })
            .first
        if let workspace {
            return .workspace(workspace)
        }

        guard let repo = repos.first else { return nil }
        return .repoOverview(repo)
    }
}
