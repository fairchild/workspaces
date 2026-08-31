import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

/// The in-body sort inventory #1354's review left behind, now memoized (#1366). Two things have
/// to hold for that to be safe: the cache returns the same order the uncached comparator would,
/// and every input the comparator or its filter reads invalidates it — including the object
/// identity hole review found in `SidebarRepoSortCache`.
@MainActor
@Suite("MainWindowOrderCache")
struct MainWindowOrderCacheTests {
    private func repo(_ name: String = "alpha") -> Repo {
        Repo(name: name, localPath: URL(fileURLWithPath: "/repos/\(name)"))
    }

    @discardableResult
    private func workspace(
        _ name: String,
        in repo: Repo,
        lastAccessedAt: Date = Date(timeIntervalSince1970: 0),
        status: WorkspaceStatus = .active
    ) -> Workspace {
        let workspace = Workspace(
            name: name,
            path: URL(fileURLWithPath: "\(repo.localPath)/\(name)"),
            sourceRepo: repo,
            lastAccessedAt: lastAccessedAt
        )
        workspace.status = status
        return workspace
    }

    private func webSource(
        _ name: String,
        lastAccessedAt: Date = Date(timeIntervalSince1970: 0)
    ) -> WebSource {
        let source = WebSource(
            name: name,
            baseURLString: "https://\(name).example.com/",
            allowedHost: "\(name).example.com"
        )
        source.lastAccessedAt = lastAccessedAt
        return source
    }

    // MARK: - Ordering parity

    @Test("Workspace orderings match the comparator they replaced")
    func workspaceOrderingsMatchTheComparator() {
        let repo = repo()
        let newest = workspace("newest", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 300))
        let middle = workspace("middle", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 200))
        let archived = workspace(
            "archived", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 250),
            status: .archived)
        repo.workspaces = [middle, archived, newest]

        let cache = MainWindowOrderCache()
        #expect(cache.workspaces(for: repo).map(\.name) == ["newest", "archived", "middle"])
        #expect(cache.activeWorkspaces(for: repo).map(\.name) == ["newest", "middle"])
        #expect(cache.archivedWorkspaces(for: repo).map(\.name) == ["archived"])
    }

    @Test("Pinned ordering matches SidebarPinController")
    func pinnedOrderingMatchesTheController() {
        let repo = repo()
        let first = workspace("first", in: repo)
        let second = workspace("second", in: repo)
        first.pinOrder = 1
        second.pinOrder = 0
        let all = [first, second]

        let controller = SidebarPinController()
        let cache = MainWindowOrderCache()
        #expect(
            cache.pinnedWorkspaces(in: all, controller: controller).map(\.name)
                == controller.pinnedWorkspaces(in: all).map(\.name)
        )
        #expect(cache.pinnedWorkspaces(in: all, controller: controller).map(\.name) == ["second", "first"])
    }

    @Test("The global Web section keeps only global sources, newest first")
    func globalWebSourcesFilterAndOrder() {
        let repo = repo()
        let owned = webSource("owned", lastAccessedAt: Date(timeIntervalSince1970: 400))
        owned.sourceRepo = repo
        let older = webSource("older", lastAccessedAt: Date(timeIntervalSince1970: 100))
        let newer = webSource("newer", lastAccessedAt: Date(timeIntervalSince1970: 200))

        let cache = MainWindowOrderCache()
        #expect(cache.globalWebSources(in: [older, owned, newer]).map(\.name) == ["newer", "older"])
    }

    // MARK: - Invalidation

    @Test("A changed access date reorders rather than serving the cached order")
    func accessDateInvalidates() {
        let repo = repo()
        let alpha = workspace("alpha", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 100))
        let beta = workspace("beta", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 200))
        repo.workspaces = [alpha, beta]

        let cache = MainWindowOrderCache()
        #expect(cache.activeWorkspaces(for: repo).map(\.name) == ["beta", "alpha"])

        alpha.lastAccessedAt = Date(timeIntervalSince1970: 300)
        #expect(cache.activeWorkspaces(for: repo).map(\.name) == ["alpha", "beta"])
    }

    @Test("A status change moves a workspace between the active and archived orderings")
    func statusInvalidates() {
        let repo = repo()
        let alpha = workspace("alpha", in: repo)
        repo.workspaces = [alpha]

        let cache = MainWindowOrderCache()
        #expect(cache.activeWorkspaces(for: repo).map(\.name) == ["alpha"])
        #expect(cache.archivedWorkspaces(for: repo).isEmpty)

        alpha.status = .archived
        #expect(cache.activeWorkspaces(for: repo).isEmpty)
        #expect(cache.archivedWorkspaces(for: repo).map(\.name) == ["alpha"])
    }

    @Test("A repin reorders the Pinned section")
    func pinOrderInvalidates() {
        let repo = repo()
        let first = workspace("first", in: repo)
        let second = workspace("second", in: repo)
        first.pinOrder = 0
        second.pinOrder = 1
        let all = [first, second]

        let cache = MainWindowOrderCache()
        let controller = SidebarPinController()
        #expect(cache.pinnedWorkspaces(in: all, controller: controller).map(\.name) == ["first", "second"])

        first.pinOrder = 2
        #expect(cache.pinnedWorkspaces(in: all, controller: controller).map(\.name) == ["second", "first"])
    }

    /// The hole review found in #1354's repo-sort cache: SwiftData can replace a model instance
    /// with an equal-valued one, and a cache keyed on values alone goes on vending the object
    /// that was superseded.
    @Test("A replacement instance with identical values still invalidates")
    func objectIdentityInvalidates() {
        let repo = repo()
        let original = workspace("alpha", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 100))
        repo.workspaces = [original]

        let cache = MainWindowOrderCache()
        #expect(cache.activeWorkspaces(for: repo).first === original)

        let replacement = Workspace(
            name: original.name,
            path: URL(fileURLWithPath: original.path),
            sourceRepo: repo,
            lastAccessedAt: original.lastAccessedAt
        )
        replacement.id = original.id
        repo.workspaces = [replacement]

        #expect(cache.activeWorkspaces(for: repo).first === replacement)
    }

    @Test("Each repo keeps its own cached ordering")
    func slotsAreKeyedByContainer() {
        let alpha = repo("alpha")
        let beta = repo("beta")
        alpha.workspaces = [workspace("a1", in: alpha)]
        beta.workspaces = [workspace("b1", in: beta), workspace("b2", in: beta)]

        let cache = MainWindowOrderCache()
        #expect(cache.activeWorkspaces(for: alpha).map(\.name) == ["a1"])
        #expect(cache.activeWorkspaces(for: beta).count == 2)
        #expect(cache.activeWorkspaces(for: alpha).map(\.name) == ["a1"])
    }

    @Test("Recent buckets rebuild when the snapshot is re-taken")
    func recentBucketsInvalidateOnSnapshot() {
        let repo = repo()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = workspace("alpha", in: repo, lastAccessedAt: now)
        let beta = workspace("beta", in: repo, lastAccessedAt: now)
        repo.workspaces = [alpha, beta]

        let cache = MainWindowOrderCache()
        let first = cache.recentBuckets(
            repos: [repo],
            snapshot: [alpha.id: now, beta.id: now.addingTimeInterval(-60)],
            repoRootPaneCounts: [:],
            now: now,
            calendar: .current
        )
        #expect(first.first?.rows.map(\.name) == ["alpha", "beta"])

        let second = cache.recentBuckets(
            repos: [repo],
            snapshot: [alpha.id: now.addingTimeInterval(-120), beta.id: now],
            repoRootPaneCounts: [:],
            now: now,
            calendar: .current
        )
        #expect(second.first?.rows.map(\.name) == ["beta", "alpha"])
    }
}
