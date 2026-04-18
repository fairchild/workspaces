import Foundation
import WorkspaceManagerCore

struct MainSelectionCoordinator {
    private var cachedWorkspaceIndex: [UUID: Workspace] = [:]
    private var cachedRepoIndex: [UUID: Repo] = [:]
    private var cachedWebSourceIndex: [UUID: WebSource] = [:]
    private var lastRepoIDSet: Set<UUID> = []
    private var lastWorkspaceIDSet: Set<UUID> = []
    private var lastWebSourceIDSet: Set<UUID> = []
    private(set) var cachedNormalizedRepoPaths: Set<String> = []

    func repo(with id: UUID?, in repos: [Repo]) -> Repo? {
        guard let id else { return nil }
        return repos.first { $0.id == id }
    }

    func workspace(with id: UUID?, in repos: [Repo]) -> Workspace? {
        guard let id else { return nil }
        return repos.flatMap(\.workspaces).first { $0.id == id }
    }

    func webSource(with id: UUID?, in webSources: [WebSource]) -> WebSource? {
        guard let id else { return nil }
        return webSources.first { $0.id == id }
    }

    // MARK: - Cached lookups

    mutating func rebuildCachesIfNeeded(
        repos: [Repo],
        webSources: [WebSource],
        normalizePath: (String) -> String
    ) {
        let repoIDs = Set(repos.map(\.id))
        let workspaceIDs = Set(repos.flatMap(\.workspaces).map(\.id))
        let webSourceIDs = Set(webSources.map(\.id))

        if repoIDs != lastRepoIDSet || workspaceIDs != lastWorkspaceIDSet {
            lastRepoIDSet = repoIDs
            lastWorkspaceIDSet = workspaceIDs
            cachedRepoIndex = Dictionary(uniqueKeysWithValues: repos.map { ($0.id, $0) })
            cachedWorkspaceIndex = Dictionary(
                uniqueKeysWithValues: repos.flatMap(\.workspaces).map { ($0.id, $0) }
            )
            cachedNormalizedRepoPaths = Set(repos.map { normalizePath($0.localPath) })
        }

        if webSourceIDs != lastWebSourceIDSet {
            lastWebSourceIDSet = webSourceIDs
            cachedWebSourceIndex = Dictionary(
                uniqueKeysWithValues: webSources.map { ($0.id, $0) }
            )
        }
    }

    func cachedRepo(with id: UUID?) -> Repo? {
        guard let id else { return nil }
        return cachedRepoIndex[id]
    }

    func cachedWorkspace(with id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return cachedWorkspaceIndex[id]
    }

    func cachedWebSource(with id: UUID?) -> WebSource? {
        guard let id else { return nil }
        return cachedWebSourceIndex[id]
    }

    func bestWorkspaceMatch(
        for cwd: String,
        repos: [Repo],
        normalizePath: (String) -> String,
        pathIsInside: (String, String) -> Bool
    ) -> Workspace? {
        let normalizedCWD = normalizePath(cwd)
        let allWorkspaces = repos.flatMap(\.workspaces)

        let matches = allWorkspaces.compactMap { workspace -> (workspace: Workspace, matchLength: Int)? in
            let workspacePath = normalizePath(workspace.path)
            guard pathIsInside(normalizedCWD, workspacePath) else { return nil }
            return (workspace, workspacePath.count)
        }

        let bestMatch = matches.sorted { lhs, rhs in
            if lhs.matchLength == rhs.matchLength {
                return lhs.workspace.lastAccessedAt > rhs.workspace.lastAccessedAt
            }
            return lhs.matchLength > rhs.matchLength
        }.first

        return bestMatch?.workspace
    }

    func bestRepoMatch(
        for cwd: String,
        repoRoot: String?,
        repos: [Repo],
        normalizePath: (String) -> String,
        pathIsInside: (String, String) -> Bool
    ) -> Repo? {
        if let repoRoot {
            let normalizedRepoRoot = normalizePath(repoRoot)
            if let exact = repos.first(where: { normalizePath($0.localPath) == normalizedRepoRoot }) {
                return exact
            }
        }

        let normalizedCWD = normalizePath(cwd)
        let matches = repos.compactMap { repo -> (repo: Repo, matchLength: Int)? in
            let repoPath = normalizePath(repo.localPath)
            guard pathIsInside(normalizedCWD, repoPath) else { return nil }
            return (repo, repoPath.count)
        }

        let bestMatch = matches.sorted { lhs, rhs in
            if lhs.matchLength == rhs.matchLength {
                return lhs.repo.lastAccessedAt > rhs.repo.lastAccessedAt
            }
            return lhs.matchLength > rhs.matchLength
        }.first

        return bestMatch?.repo
    }

    func syncedWorkspaceSelection(
        for activeSession: HostTerminalSession?,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> Workspace? {
        guard let activeSession else { return nil }

        switch activeSession.key {
        case .backendSession(let providerID, let instanceID):
            return repos.flatMap(\.workspaces).first {
                $0.backendIdentifier == providerID && $0.terminalSessionIdentifier == instanceID
            }
        case .hostPath(let path):
            let normalizedPath = normalizePath(path)
            return repos.flatMap(\.workspaces).first { normalizePath($0.path) == normalizedPath }
        case .repoPath, .defaultHome:
            return nil
        }
    }
}
