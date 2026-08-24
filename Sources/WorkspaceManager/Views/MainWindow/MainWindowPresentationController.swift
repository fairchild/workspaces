import Foundation
import WorkspaceManagerCore

struct MainWindowToolbarTitle: Equatable {
    let repoName: String
    let workspaceName: String?

    var windowTitle: String {
        if let workspaceName {
            return "\(repoName) / \(workspaceName)"
        }
        return repoName
    }
}

struct MainWindowPrincipalToolbarPresentation: Equatable {
    let toolbarTitle: MainWindowToolbarTitle?
    let showsDevelopmentBadge: Bool
}

struct MainWindowPresentationController {
    static let showsVisualWindowTitle = false

    func principalToolbarPresentation(
        toolbarTitle: MainWindowToolbarTitle?,
        buildIdentity: AppBuildIdentity
    ) -> MainWindowPrincipalToolbarPresentation {
        MainWindowPrincipalToolbarPresentation(
            toolbarTitle: toolbarTitle,
            showsDevelopmentBadge: buildIdentity.isDevelopment
        )
    }

    func activeHostSession(
        activeSessionID: UUID?,
        sessions: [HostTerminalSession]
    ) -> HostTerminalSession? {
        guard let activeSessionID else {
            return sessions.last
        }
        return sessions.first(where: { $0.id == activeSessionID }) ?? sessions.last
    }

    /// Takes a prebuilt normalized-path index (see `PathNormalizationCache`)
    /// rather than repos + a normalizer: this runs several times per
    /// `ContentView.body` evaluation, and rebuilding the index there put
    /// per-repo symlink resolution on the render path (#1347 B1).
    func selectedRepoForInspector(
        selectedWorkspace: Workspace?,
        selectedWebSource: WebSource?,
        activeRepoPath: String?,
        activeHostSession: HostTerminalSession?,
        repoByNormalizedPath: [String: Repo],
        normalizePath: (String) -> String
    ) -> Repo? {
        guard selectedWorkspace == nil, selectedWebSource == nil else {
            return nil
        }

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
        paneCount: (UUID) -> Int
    ) -> [HostTerminalSessionKey: Int] {
        var paneCounts: [HostTerminalSessionKey: Int] = [:]
        paneCounts.reserveCapacity(sessions.count)

        for session in sessions {
            paneCounts[session.key, default: 0] &+= paneCount(session.id)
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

    func toolbarTitle(
        selectedWorkspace: Workspace?,
        selectedRepo: Repo?,
        activeHostSession: HostTerminalSession?
    ) -> MainWindowToolbarTitle? {
        if let selectedWorkspace {
            if let sourceRepo = selectedWorkspace.sourceRepo {
                return MainWindowToolbarTitle(
                    repoName: sourceRepo.name,
                    workspaceName: selectedWorkspace.name
                )
            }

            return MainWindowToolbarTitle(
                repoName: selectedWorkspace.name,
                workspaceName: nil
            )
        }

        if let selectedRepo {
            return MainWindowToolbarTitle(
                repoName: selectedRepo.name,
                workspaceName: nil
            )
        }

        guard let activeHostSession else { return nil }

        switch activeHostSession.key {
        case .defaultHome:
            return nil
        case .repoPath, .hostPath:
            return MainWindowToolbarTitle(
                repoName: activeHostSession.directoryURL.lastPathComponent,
                workspaceName: nil
            )
        case .backendSession(_, let instanceID):
            return MainWindowToolbarTitle(
                repoName: "Workspace \(instanceID)",
                workspaceName: nil
            )
        }
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

}
