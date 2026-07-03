import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("RestoreTargetIndexBuilder")
struct RestoreTargetIndexBuilderTests {
    private func makeBuilder() -> RestoreTargetIndexBuilder {
        RestoreTargetIndexBuilder(homeDirectoryPath: "/Users/me", normalizePath: { $0 })
    }

    @Test("Repos map to normalized-path/root entries")
    func mapsRepos() {
        let repo = Repo(name: "app", localPath: URL(fileURLWithPath: "/code/app"))
        let index = makeBuilder().build(repos: [repo])
        #expect(index.homeDirectoryPath == "/Users/me")
        #expect(index.repos == [RestoreTargetIndex.Entry(normalizedPath: "/code/app", rootPath: "/code/app")])
    }

    @Test("Only non-archived workspaces are indexed")
    func filtersArchivedWorkspaces() {
        let repo = Repo(name: "app", localPath: URL(fileURLWithPath: "/code/app"))
        let active = Workspace(
            name: "wt", path: URL(fileURLWithPath: "/code/app/wt"), sourceRepo: repo, status: .active)
        let archived = Workspace(
            name: "old",
            path: URL(fileURLWithPath: "/code/app/old"),
            sourceRepo: repo,
            status: .archived
        )
        repo.workspaces = [active, archived]

        let index = makeBuilder().build(repos: [repo])
        #expect(
            index.workspaces == [RestoreTargetIndex.Entry(normalizedPath: "/code/app/wt", rootPath: "/code/app/wt")])
    }

    @Test("Normalization is applied to indexed paths")
    func appliesNormalization() {
        let builder = RestoreTargetIndexBuilder(
            homeDirectoryPath: "/Users/me",
            normalizePath: { $0.uppercased() }
        )
        let repo = Repo(name: "app", localPath: URL(fileURLWithPath: "/code/app"))
        let index = builder.build(repos: [repo])
        #expect(index.repos.first?.normalizedPath == "/CODE/APP")
        #expect(index.repos.first?.rootPath == "/code/app")  // root stays the real path
    }
}
