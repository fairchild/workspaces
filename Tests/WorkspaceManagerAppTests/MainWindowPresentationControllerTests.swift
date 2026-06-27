import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainWindowPresentationController")
struct MainWindowPresentationControllerTests {
    private let controller = MainWindowPresentationController()

    @Test("Active host session falls back to the last session when active is missing")
    func activeHostSessionFallsBackToLastSession() {
        let first = HostTerminalSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/tmp/home")
        )
        let second = HostTerminalSession(
            key: .repoPath("/tmp/repo"),
            directory: URL(fileURLWithPath: "/tmp/repo")
        )

        let result = controller.activeHostSession(
            activeSessionID: UUID(),
            sessions: [first, second]
        )

        #expect(result?.id == second.id)
    }

    @Test("Selected repo for inspector prefers active repo path and hides for web selection")
    func selectedRepoForInspectorPrefersActiveRepoPath() {
        let repoA = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let repoB = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))
        let session = HostTerminalSession(
            key: .hostPath("/tmp/alpha/worktrees/feature"),
            directory: URL(fileURLWithPath: "/tmp/alpha/worktrees/feature")
        )

        let selectedRepo = controller.selectedRepoForInspector(
            selectedWorkspace: nil,
            selectedWebSource: nil,
            activeRepoPath: repoB.localPath,
            activeHostSession: session,
            repos: [repoA, repoB],
            normalizePath: normalizePath
        )
        #expect(selectedRepo?.id == repoB.id)

        let webSource = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com",
            allowedHost: "docs.example.com"
        )
        let hiddenWhileBrowsingWeb = controller.selectedRepoForInspector(
            selectedWorkspace: nil,
            selectedWebSource: webSource,
            activeRepoPath: repoB.localPath,
            activeHostSession: session,
            repos: [repoA, repoB],
            normalizePath: normalizePath
        )
        #expect(hiddenWhileBrowsingWeb == nil)
    }

    @Test("Pane counts include attached split sessions")
    func paneCountsIncludeSplitSessions() {
        let repoURL = URL(fileURLWithPath: "/tmp/repo")
        let primary = HostTerminalSession(
            key: .repoPath(repoURL.path),
            directory: repoURL
        )
        let defaultHome = HostTerminalSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/tmp/home")
        )

        let paneCounts = controller.paneCountBySessionKey(
            sessions: [primary, defaultHome],
            paneCount: { sessionID in
                sessionID == primary.id ? 2 : 1
            }
        )

        #expect(paneCounts[primary.key] == 2)
        #expect(paneCounts[defaultHome.key] == 1)
    }

    @Test("Toolbar title nests workspace under its source repo")
    func toolbarTitleNestsWorkspaceUnderSourceRepo() {
        let repo = Repo(name: "pi-mono", localPath: URL(fileURLWithPath: "/tmp/pi-mono"))
        let workspace = Workspace(
            name: "gentle-frog",
            path: URL(fileURLWithPath: "/tmp/workspaces/pi-mono/gentle-frog"),
            sourceRepo: repo
        )

        let title = controller.toolbarTitle(
            selectedWorkspace: workspace,
            selectedRepo: repo,
            activeHostSession: nil
        )

        #expect(title?.repoName == "pi-mono")
        #expect(title?.workspaceName == "gentle-frog")
        #expect(title?.windowTitle == "pi-mono / gentle-frog")
    }

    @Test("Toolbar title shows only repo for root terminal")
    func toolbarTitleShowsOnlyRepoForRootTerminal() {
        let repo = Repo(name: "pi-mono", localPath: URL(fileURLWithPath: "/tmp/pi-mono"))

        let title = controller.toolbarTitle(
            selectedWorkspace: nil,
            selectedRepo: repo,
            activeHostSession: nil
        )

        #expect(title?.repoName == "pi-mono")
        #expect(title?.workspaceName == nil)
        #expect(title?.windowTitle == "pi-mono")
    }

    @Test("Toolbar title falls back to active terminal directory when no repo is selected")
    func toolbarTitleFallsBackToActiveTerminalDirectory() {
        let session = HostTerminalSession(
            key: .hostPath("/tmp/scratch"),
            directory: URL(fileURLWithPath: "/tmp/scratch")
        )

        let title = controller.toolbarTitle(
            selectedWorkspace: nil,
            selectedRepo: nil,
            activeHostSession: session
        )

        #expect(title?.repoName == "scratch")
        #expect(title?.workspaceName == nil)
        #expect(title?.windowTitle == "scratch")
    }

    @Test("Open in editor target prefers file selection over workspace and repo")
    func openInEditorTargetPrefersFileSelection() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        let selection = CodePreviewSelection(
            rootURL: workspace.workspaceURL,
            relativePath: "Sources/App/main.swift"
        )

        let target = controller.openInEditorTarget(
            selectedCodePreview: selection,
            selectedWorkspace: workspace,
            selectedRepo: repo
        )

        switch target {
        case .projectAndFile(let rootURL, let fileURL):
            #expect(rootURL == workspace.workspaceURL)
            #expect(fileURL == selection.fileURL)
        default:
            Issue.record("Expected project-and-file target")
        }
    }

    @Test("Open in editor target ignores remote workspace selections")
    func openInEditorTargetIgnoresRemoteWorkspaceSelections() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "cloud-feature",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/cloud-feature"),
            sourceRepo: repo,
            backendIdentifier: SSHBackend.identifier,
            remoteId: "remote-123"
        )

        let target = controller.openInEditorTarget(
            selectedCodePreview: nil,
            selectedWorkspace: workspace,
            selectedRepo: nil
        )

        #expect(target == nil)
    }

    @Test("Open in editor context key tracks current selection type")
    func openInEditorContextKeyTracksSelectionType() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = Workspace(
            name: "feature-a",
            path: URL(fileURLWithPath: "/tmp/alpha/workspaces/feature-a"),
            sourceRepo: repo
        )
        let selection = CodePreviewSelection(
            rootURL: workspace.workspaceURL,
            relativePath: "README.md"
        )

        #expect(
            controller.openInEditorContextKey(
                selectedCodePreview: selection,
                selectedWorkspace: workspace,
                selectedRepo: repo
            ) == .file(selection.id)
        )
        #expect(
            controller.openInEditorContextKey(
                selectedCodePreview: nil,
                selectedWorkspace: workspace,
                selectedRepo: repo
            ) == .workspace(workspace.id)
        )
        #expect(
            controller.openInEditorContextKey(
                selectedCodePreview: nil,
                selectedWorkspace: nil,
                selectedRepo: repo
            ) == .repo(repo.id)
        )
    }

    private func normalizePath(_ rawPath: String) -> String {
        URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
