import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainSelectionCoordinator")
struct MainSelectionCoordinatorTests {
    private let coordinator = MainSelectionCoordinator()

    @Test("Backend session selects workspace by provider and instance")
    func backendSessionSelectionMatchesProviderAndInstance() {
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let localWorkspace = Workspace(
            name: "local",
            path: URL(fileURLWithPath: "/tmp/workspaces/local"),
            sourceRepo: repo
        )
        let lumeWorkspace = Workspace(
            name: "lume",
            path: URL(fileURLWithPath: "/tmp/workspaces/lume"),
            sourceRepo: repo,
            backendIdentifier: LumeWorkspaceProvider.identifier,
            remoteId: "vm-123",
            sessionRoutingID: "lume-route-123"
        )
        let daytonaWorkspace = Workspace(
            name: "daytona",
            path: URL(fileURLWithPath: "/tmp/workspaces/daytona"),
            sourceRepo: repo,
            backendIdentifier: DaytonaWorkspaceProvider.identifier,
            remoteId: "vm-123"
        )
        repo.workspaces = [localWorkspace, lumeWorkspace, daytonaWorkspace]

        let activeSession = HostTerminalSession(
            key: .backendSession(providerID: LumeWorkspaceProvider.identifier, instanceID: "lume-route-123"),
            directory: URL(fileURLWithPath: "/tmp/workspaces/lume"),
            customCommand: "/usr/local/bin/lume ssh vm-123"
        )

        let selection = coordinator.syncedWorkspaceSelection(
            for: activeSession,
            repos: [repo],
            normalizePath: normalizePath
        )

        #expect(selection?.id == lumeWorkspace.id)
    }

    @Test("Repo lookup returns current repo by id")
    func repoLookupReturnsMatchingRepo() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))

        let resolved = coordinator.repo(with: repo.id, in: [repo])

        #expect(resolved?.id == repo.id)
    }

    @Test("Workspace lookup searches across all repos")
    func workspaceLookupReturnsMatchingWorkspace() {
        let firstRepo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let secondRepo = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))
        let workspace = Workspace(
            name: "feature-b",
            path: URL(fileURLWithPath: "/tmp/beta/workspaces/feature-b"),
            sourceRepo: secondRepo
        )
        secondRepo.workspaces = [workspace]

        let resolved = coordinator.workspace(with: workspace.id, in: [firstRepo, secondRepo])

        #expect(resolved?.id == workspace.id)
    }

    @Test("Web source lookup returns matching scoped source by id")
    func webSourceLookupReturnsMatchingSource() {
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com/",
            allowedHost: "docs.example.com"
        )

        let resolved = coordinator.webSource(with: source.id, in: [source])

        #expect(resolved?.id == source.id)
    }

    @Test("Best repo match prefers explicit repo root and longest path")
    func bestRepoMatchPrefersExplicitRepoRoot() {
        let firstRepo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let secondRepo = Repo(name: "nested", localPath: URL(fileURLWithPath: "/tmp/alpha/nested"))

        let resolved = coordinator.bestRepoMatch(
            for: "/tmp/alpha/nested/Sources/App",
            repoRoot: "/tmp/alpha/nested",
            repos: [firstRepo, secondRepo],
            normalizePath: normalizePath,
            pathIsInside: path(_:isInside:)
        )

        #expect(resolved?.id == secondRepo.id)
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
