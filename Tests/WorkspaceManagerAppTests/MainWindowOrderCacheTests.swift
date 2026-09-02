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

    // MARK: - The memo actually hits

    /// Every input is fingerprinted, so a hit and a miss return the same answer and no assertion
    /// over the *result* can separate them. These read the build count instead.
    @Test("The Recent memo hits while the snapshot instant holds still")
    func recentMemoHitsOnAStableInstant() {
        let repo = repo()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = workspace("alpha", in: repo, lastAccessedAt: now)
        repo.workspaces = [alpha]
        let snapshot = [alpha.id: now]

        let cache = MainWindowOrderCache()
        func ask(now instant: Date) {
            _ = cache.recentBuckets(
                repos: [repo], snapshot: snapshot, repoRootPaneCounts: [:],
                now: instant, calendar: .current)
        }

        ask(now: now)
        #expect(cache.buildCount == 1)

        // The sidebar's shape: `now` is re-read from `@State`, not re-taken, so repeated body
        // evaluations pass the same instant and the arrangement is built once.
        ask(now: now)
        ask(now: now)
        #expect(cache.buildCount == 1, "a stable instant must not rebuild the arrangement")

        // Deliberately re-taking the snapshot is the one thing that has to invalidate it.
        ask(now: now.addingTimeInterval(60))
        #expect(cache.buildCount == 2)
    }

    /// The hazard raised in review of #1504: `now` is compared exactly, so a caller taking a fresh
    /// instant per access would miss every time and the memo would do nothing for this path.
    /// `SidebarView` passes `recentSnapshotTakenAt` — `@State` re-taken only by
    /// `syncRecentSnapshot(forceRefresh:)`, never during a redraw — and this pins what changing
    /// that would cost, so the hazard fails a test rather than going quiet.
    @Test("A freshly taken instant per access defeats the Recent memo")
    func freshInstantPerAccessDefeatsTheRecentMemo() {
        let repo = repo()
        let alpha = workspace("alpha", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 1_000))
        repo.workspaces = [alpha]

        let cache = MainWindowOrderCache()
        for _ in 0..<3 {
            _ = cache.recentBuckets(
                repos: [repo], snapshot: [:], repoRootPaneCounts: [:],
                now: Date(), calendar: .current)
        }

        #expect(cache.buildCount == 3, "a fresh instant per access must miss every time")
    }

    @Test("A repeated ordering request with unchanged inputs does not re-sort")
    func slotMemoHitsOnUnchangedInputs() {
        let repo = repo()
        repo.workspaces = [
            workspace("alpha", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 100)),
            workspace("beta", in: repo, lastAccessedAt: Date(timeIntervalSince1970: 200)),
        ]

        let cache = MainWindowOrderCache()
        _ = cache.activeWorkspaces(for: repo)
        _ = cache.activeWorkspaces(for: repo)
        _ = cache.activeWorkspaces(for: repo)
        #expect(cache.buildCount == 1)

        repo.workspaces[0].lastAccessedAt = Date(timeIntervalSince1970: 300)
        _ = cache.activeWorkspaces(for: repo)
        #expect(cache.buildCount == 2)
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

    /// Raised by the codex pass on #1504: the Recent memo keyed on the model fingerprint and
    /// `now`, and passed `calendar` only to the builder — yet the calendar is what decides the
    /// Today / This Week / Earlier boundaries. An automatic time-zone change while the app stays
    /// active moves a workspace near midnight between buckets without moving any model value.
    @Test("A calendar change rebuilds the Recent buckets")
    func calendarChangeRebuildsRecentBuckets() {
        let repo = repo()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let alpha = workspace("alpha", in: repo, lastAccessedAt: now)
        repo.workspaces = [alpha]
        let snapshot = [alpha.id: now]

        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt

        let cache = MainWindowOrderCache()
        func ask(_ calendar: Calendar) {
            _ = cache.recentBuckets(
                repos: [repo], snapshot: snapshot, repoRootPaneCounts: [:],
                now: now, calendar: calendar)
        }

        ask(eastern)
        ask(eastern)
        #expect(cache.buildCount == 1, "the same calendar must still hit")

        ask(tokyo)
        #expect(cache.buildCount == 2, "a different calendar must rebuild the buckets")
    }

    /// The pin fingerprint carries `name` because the Pinned comparator falls back to it when two
    /// workspaces share a rank — which a store carrying duplicates from an older build does. The
    /// parity test above uses distinct ranks, so it would pass with `name` deleted from
    /// `pinSignatures`; this one would not.
    @Test("A rename reorders the Pinned section when ranks tie")
    func pinnedOrderingInvalidatesOnRename() {
        let repo = repo()
        let alpha = workspace("alpha", in: repo)
        let beta = workspace("beta", in: repo)
        alpha.pinOrder = 0
        beta.pinOrder = 0
        let all = [alpha, beta]

        let cache = MainWindowOrderCache()
        let controller = SidebarPinController()
        #expect(
            cache.pinnedWorkspaces(in: all, controller: controller).map(\.name)
                == ["alpha", "beta"]
        )

        alpha.name = "zulu"
        #expect(
            cache.pinnedWorkspaces(in: all, controller: controller).map(\.name)
                == ["beta", "zulu"]
        )
    }

    // MARK: - The pin graph revision

    /// The blocker the codex pass on #1504 found. `togglePin` and `movePin` are reached from
    /// closures a skipped row keeps, and both walk the *whole* workspace list — so a peer
    /// replaced by an equal-valued instance has to move the number every row compares on, even
    /// though that row's own workspace, pinned index, and pinned count are all unchanged.
    @Test("A replaced peer moves the pin graph revision")
    func peerReplacementMovesThePinGraphRevision() {
        let repo = repo()
        let mine = workspace("mine", in: repo)
        let peer = workspace("peer", in: repo)
        mine.pinOrder = 0
        peer.pinOrder = 1

        let cache = MainWindowOrderCache()
        let controller = SidebarPinController()
        let before = cache.pinnedSection(in: [mine, peer], controller: controller)

        let replacement = Workspace(
            name: peer.name,
            path: URL(fileURLWithPath: peer.path),
            sourceRepo: repo,
            lastAccessedAt: peer.lastAccessedAt
        )
        replacement.id = peer.id
        replacement.createdAt = peer.createdAt
        replacement.pinOrder = peer.pinOrder

        let after = cache.pinnedSection(in: [mine, replacement], controller: controller)

        #expect(
            before.workspaces.map(\.name) == after.workspaces.map(\.name),
            "the section reads identically, which is what makes this hazard quiet"
        )
        #expect(
            before.graphRevision != after.graphRevision,
            "yet every row must rebuild so no closure keeps the superseded peer"
        )
    }

    /// The converse, and the reason the revision is safe to carry on every row: the graph holding
    /// still must not manufacture rebuilds, or the per-row scoping this slice exists for is gone.
    @Test("An unchanged graph holds the pin graph revision still")
    func unchangedGraphHoldsThePinGraphRevision() {
        let repo = repo()
        let alpha = workspace("alpha", in: repo)
        let beta = workspace("beta", in: repo)
        alpha.pinOrder = 0
        beta.pinOrder = 1
        let all = [alpha, beta]

        let cache = MainWindowOrderCache()
        let controller = SidebarPinController()
        let first = cache.pinnedSection(in: all, controller: controller).graphRevision

        for _ in 0..<5 {
            #expect(cache.pinnedSection(in: all, controller: controller).graphRevision == first)
        }

        beta.pinOrder = 2
        #expect(
            cache.pinnedSection(in: all, controller: controller).graphRevision != first,
            "a real pin move still has to invalidate"
        )
    }
}
