import Foundation
import WorkspaceManagerCore

struct MainWindowPresentationController {
    func activeHostSession(
        activeSessionID: UUID?,
        sessions: [HostTerminalSession]
    ) -> HostTerminalSession? {
        guard let activeSessionID else {
            return sessions.last
        }
        return sessions.first(where: { $0.id == activeSessionID }) ?? sessions.last
    }

    func selectedRepoForInspector(
        selectedWorkspace: Workspace?,
        selectedWebSource: WebSource?,
        activeRepoPath: String?,
        activeHostSession: HostTerminalSession?,
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> Repo? {
        guard selectedWorkspace == nil, selectedWebSource == nil else {
            return nil
        }

        let repoByNormalizedPath = repoIndex(
            repos: repos,
            normalizePath: normalizePath
        )

        if let activeRepoPath {
            let normalizedActiveRepoPath = normalizePath(activeRepoPath)
            if let matchedRepo = repoByNormalizedPath[normalizedActiveRepoPath] {
                return matchedRepo
            }
        }

        guard let activeHostSession else {
            return nil
        }

        let normalizedActiveSessionPath = normalizePath(activeHostSession.directoryPath)
        return repoByNormalizedPath[normalizedActiveSessionPath]
    }

    func paneCountBySessionKey(
        sessions: [HostTerminalSession],
        splitSession: (UUID) -> HostTerminalSession?
    ) -> [HostTerminalSessionKey: Int] {
        var paneCounts: [HostTerminalSessionKey: Int] = [:]
        paneCounts.reserveCapacity(sessions.count)

        for session in sessions {
            paneCounts[session.key, default: 0] &+= 1
            if splitSession(session.id) != nil {
                paneCounts[session.key, default: 0] &+= 1
            }
        }

        return paneCounts
    }

    func activeSessionKeyForSidebar(
        selectedWebSource: WebSource?,
        activeSessionID: UUID?,
        sessions: [HostTerminalSession]
    ) -> HostTerminalSessionKey? {
        guard selectedWebSource == nil else { return nil }
        guard let activeSessionID else { return nil }
        return sessions.first(where: { $0.id == activeSessionID })?.key
    }

    func openInEditorTarget(
        selectedCodePreview: CodePreviewSelection?,
        selectedWorkspace: Workspace?,
        selectedRepo: Repo?
    ) -> OpenInEditorTarget? {
        if let selectedCodePreview {
            return .projectAndFile(
                rootURL: selectedCodePreview.rootURL,
                fileURL: selectedCodePreview.fileURL
            )
        }
        if let selectedWorkspace,
            let localDirectoryURL = selectedWorkspace.localDirectoryURL
        {
            return .project(rootURL: localDirectoryURL)
        }
        if let selectedRepo {
            return .project(rootURL: selectedRepo.localURL)
        }
        return nil
    }

    func openInEditorContextKey(
        selectedCodePreview: CodePreviewSelection?,
        selectedWorkspace: Workspace?,
        selectedRepo: Repo?
    ) -> MainWindowOpenInEditorContextKey {
        if let selectedCodePreview {
            return .file(selectedCodePreview.id)
        }
        if let selectedWorkspace {
            return .workspace(selectedWorkspace.id)
        }
        if let selectedRepo {
            return .repo(selectedRepo.id)
        }
        return .none
    }

    private func repoIndex(
        repos: [Repo],
        normalizePath: (String) -> String
    ) -> [String: Repo] {
        var index: [String: Repo] = [:]
        index.reserveCapacity(repos.count)

        for repo in repos {
            let normalizedPath = normalizePath(repo.localPath)
            if index[normalizedPath] == nil {
                index[normalizedPath] = repo
            }
        }

        return index
    }
}
