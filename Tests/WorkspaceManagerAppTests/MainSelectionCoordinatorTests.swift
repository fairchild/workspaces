import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("MainSelectionCoordinator")
struct MainSelectionCoordinatorTests {
    private let coordinator = MainSelectionCoordinator()

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
