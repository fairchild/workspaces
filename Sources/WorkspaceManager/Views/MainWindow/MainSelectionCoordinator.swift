import Foundation
import WorkspaceManagerCore

struct MainSelectionCoordinator {
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

    func syncedWorkspaceSelection(
        for activeSession: HostTerminalSession?,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> Workspace? {
        guard let activeSession else { return nil }

        switch activeSession.key {
        case .remoteSandbox(let sandboxId):
            return repos.flatMap(\.workspaces).first { $0.remoteId == sandboxId }
        case .hostPath(let path):
            let normalizedPath = normalizePath(path)
            return repos.flatMap(\.workspaces).first { normalizePath($0.path) == normalizedPath }
        case .repoPath, .defaultHome:
            return nil
        }
    }
}
