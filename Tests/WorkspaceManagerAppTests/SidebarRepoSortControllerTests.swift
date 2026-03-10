import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarRepoSortController")
struct SidebarRepoSortControllerTests {
    private let controller = SidebarRepoSortController()

    @Test("Alphabetical sort orders repos by name")
    func alphabeticalSortOrdersReposByName() {
        let zed = Repo(name: "zed", localPath: URL(fileURLWithPath: "/tmp/zed"))
        let alpha = Repo(name: "Alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let beta = Repo(name: "beta", localPath: URL(fileURLWithPath: "/tmp/beta"))

        let sorted = controller.sortedRepos(
            [zed, alpha, beta],
            mode: .alphabetical,
            lastAccessedSnapshot: [:]
        )

        #expect(sorted.map(\.name) == ["Alpha", "beta", "zed"])
    }

    @Test("Last accessed sort uses a stable snapshot until refreshed")
    func lastAccessedSortUsesStableSnapshot() {
        let alpha = Repo(
            name: "alpha",
            localPath: URL(fileURLWithPath: "/tmp/alpha"),
            lastAccessedAt: Date(timeIntervalSince1970: 10)
        )
        let beta = Repo(
            name: "beta",
            localPath: URL(fileURLWithPath: "/tmp/beta"),
            lastAccessedAt: Date(timeIntervalSince1970: 20)
        )

        let snapshot = controller.snapshot(for: [alpha, beta])
        alpha.lastAccessedAt = Date(timeIntervalSince1970: 30)

        let sorted = controller.sortedRepos(
            [alpha, beta],
            mode: .lastAccessed,
            lastAccessedSnapshot: snapshot
        )

        #expect(sorted.map(\.name) == ["beta", "alpha"])
    }

    @Test("Repos missing from the snapshot fall to the bottom alphabetically")
    func reposMissingFromSnapshotFallToBottom() {
        let alpha = Repo(
            name: "alpha",
            localPath: URL(fileURLWithPath: "/tmp/alpha"),
            lastAccessedAt: Date(timeIntervalSince1970: 30)
        )
        let beta = Repo(
            name: "beta",
            localPath: URL(fileURLWithPath: "/tmp/beta"),
            lastAccessedAt: Date(timeIntervalSince1970: 20)
        )
        let gamma = Repo(
            name: "gamma",
            localPath: URL(fileURLWithPath: "/tmp/gamma"),
            lastAccessedAt: Date(timeIntervalSince1970: 40)
        )

        let snapshot = controller.snapshot(for: [alpha, beta])
        let sorted = controller.sortedRepos(
            [gamma, beta, alpha],
            mode: .lastAccessed,
            lastAccessedSnapshot: snapshot
        )

        #expect(sorted.map(\.name) == ["alpha", "beta", "gamma"])
    }
}
