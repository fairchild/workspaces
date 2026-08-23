import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SidebarRecentArrangement")
struct SidebarRecentArrangementTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    private static let now = Date(timeIntervalSince1970: 1_755_864_000)  // 2025-08-22 12:00 UTC

    private func makeRepo(
        _ name: String,
        lastAccessedAt: Date = SidebarRecentArrangementTests.now,
        workspaces: [(name: String, lastAccessedAt: Date, status: WorkspaceStatus)] = []
    ) -> Repo {
        let repo = Repo(
            name: name,
            localPath: URL(fileURLWithPath: "/tmp/\(name)"),
            lastAccessedAt: lastAccessedAt
        )
        repo.workspaces = workspaces.map { spec in
            Workspace(
                name: spec.name,
                path: URL(fileURLWithPath: "/tmp/\(name)/\(spec.name)"),
                sourceRepo: repo,
                lastAccessedAt: spec.lastAccessedAt,
                status: spec.status
            )
        }
        return repo
    }

    private func buckets(
        _ repos: [Repo],
        snapshot: [UUID: Date]? = nil,
        paneCounts: [UUID: Int] = [:],
        now: Date = SidebarRecentArrangementTests.now
    ) -> [RecentBucket] {
        SidebarRecentArrangement.buckets(
            repos: repos,
            snapshot: snapshot ?? SidebarRecentArrangement.snapshot(for: repos),
            repoRootPaneCounts: paneCounts,
            now: now,
            calendar: Self.calendar
        )
    }

    /// `[title, row names…]` per bucket — one comparable value for the whole rendered
    /// shape, so an unexpected bucket count fails an expectation rather than trapping.
    private func renderedShape(
        _ repos: [Repo],
        snapshot: [UUID: Date]? = nil,
        paneCounts: [UUID: Int] = [:]
    ) -> [[String]] {
        buckets(repos, snapshot: snapshot, paneCounts: paneCounts).map { [$0.title] + $0.rows.map(\.name) }
    }

    private func days(_ count: Double) -> Date {
        Self.now.addingTimeInterval(-count * 24 * 60 * 60)
    }

    @Test("Late today and early yesterday land in different buckets")
    func dayBoundarySplitsTodayFromThisWeek() {
        let startOfToday = Self.calendar.startOfDay(for: Self.now)
        let lateToday = startOfToday.addingTimeInterval(23 * 3600 + 59 * 60)
        let earlyYesterday = startOfToday.addingTimeInterval(-24 * 3600 + 60)

        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("late-today", lateToday, .active),
                ("early-yesterday", earlyYesterday, .active),
            ]
        )

        #expect(renderedShape([repo]) == [["Today", "late-today"], ["This Week", "early-yesterday"]])
    }

    @Test("This Week ends at six days back; a full week ago is Earlier")
    func sevenDayEdgeFallsToEarlier() {
        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("six-days", days(6), .active),
                ("seven-days", days(7), .active),
            ]
        )

        #expect(renderedShape([repo]) == [["This Week", "six-days"], ["Earlier", "seven-days"]])
    }

    @Test("Archived workspaces never appear")
    func archivedWorkspacesAreExcluded() {
        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("live", Self.now, .active),
                ("shelved", Self.now, .archived),
            ]
        )

        let names = buckets([repo]).flatMap { $0.rows.map(\.name) }

        #expect(names == ["live"])
    }

    @Test("A repo root appears only when it has open panes")
    func repoRootRequiresPanes() {
        let quiet = makeRepo("quiet")
        let busy = makeRepo("busy")

        let withoutPanes = buckets([quiet, busy]).flatMap { $0.rows.map(\.name) }
        #expect(withoutPanes.isEmpty)

        let withPanes = buckets([quiet, busy], paneCounts: [busy.id: 2]).flatMap { $0.rows.map(\.name) }
        #expect(withPanes == ["busy"])
    }

    @Test("A repo with no rows of its own drops out entirely")
    func emptyReposDoNotAppear() {
        let empty = makeRepo("empty")
        let populated = makeRepo("populated", workspaces: [("only", Self.now, .active)])

        let names = buckets([empty, populated]).flatMap { $0.rows.map(\.name) }

        #expect(names == ["only"])
    }

    @Test("Rows sort by snapshot date descending, then by name")
    func rowsSortByDateThenName() {
        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("zulu", Self.now, .active),
                ("older", Self.now.addingTimeInterval(-60), .active),
                ("kilo", Self.now, .active),
            ]
        )

        let names = buckets([repo]).flatMap { $0.rows.map(\.name) }

        #expect(names == ["kilo", "zulu", "older"])
    }

    @Test("Ordering holds against a fixed snapshot while live dates move")
    func orderingIsStableGivenAFixedSnapshot() {
        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("first", Self.now, .active),
                ("second", Self.now.addingTimeInterval(-60), .active),
            ]
        )
        let snapshot = SidebarRecentArrangement.snapshot(for: [repo])

        repo.workspaces[1].lastAccessedAt = Self.now.addingTimeInterval(600)

        let names = buckets([repo], snapshot: snapshot).flatMap { $0.rows.map(\.name) }

        #expect(names == ["first", "second"])
    }

    @Test("A workspace the snapshot has not seen keeps its live date")
    func rowsMissingFromTheSnapshotUseTheirLiveDate() {
        let repo = makeRepo("alpha", workspaces: [("fresh", Self.now, .active)])

        #expect(renderedShape([repo], snapshot: [:]) == [["Today", "fresh"]])
    }

    @Test("Empty buckets are omitted")
    func emptyBucketsAreOmitted() {
        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("today", Self.now, .active),
                ("ancient", days(90), .active),
            ]
        )

        #expect(buckets([repo]).map(\.title) == ["Today", "Earlier"])
    }

    @Test("Rows from different repos interleave by date")
    func rowsFlattenAcrossRepos() {
        let alpha = makeRepo("alpha", workspaces: [("alpha-old", Self.now.addingTimeInterval(-120), .active)])
        let beta = makeRepo("beta", workspaces: [("beta-new", Self.now, .active)])

        let names = buckets([alpha, beta]).flatMap { $0.rows.map(\.name) }

        #expect(names == ["beta-new", "alpha-old"])
    }

    @Test("Pruning drops ids that no longer exist")
    func pruningDropsStaleIdentifiers() {
        let repo = makeRepo("alpha", workspaces: [("only", Self.now, .active)])
        let stale = UUID()
        let snapshot = SidebarRecentArrangement.snapshot(for: [repo]).merging([stale: Self.now]) { current, _ in
            current
        }

        let pruned = SidebarRecentArrangement.prunedSnapshot(
            snapshot,
            validIDs: SidebarRecentArrangement.identifiers(in: [repo])
        )

        #expect(pruned[stale] == nil)
        #expect(pruned.count == 2)
    }

    @Test("An unknown stored arrangement still resolves to alphabetical")
    func unknownStoredRawValueFallsBackToAlphabetical() {
        #expect(SidebarRepoSortMode(rawValue: "byVibes") == nil)
        #expect(SidebarRepoSortMode(rawValue: "recent") == .recent)
        #expect(SidebarRepoSortMode.recent.title == "Recent")
    }

    @Test("The fixture override pins the arrangement only in fixture mode")
    func fixtureOverrideRequiresFixtureMode() {
        let key = UIFixtureSidebarArrangement.arrangementEnvKey

        #expect(UIFixtureSidebarArrangement.mode(from: [key: "recent"]) == nil)
        #expect(
            UIFixtureSidebarArrangement.mode(from: ["WORKSPACES_UI_FIXTURE": "1", key: "recent"]) == .recent
        )
        #expect(
            UIFixtureSidebarArrangement.mode(from: ["WORKSPACES_UI_FIXTURE": "1", key: "byVibes"]) == nil
        )
        #expect(UIFixtureSidebarArrangement.mode(from: ["WORKSPACES_UI_FIXTURE": "1"]) == nil)
    }

    @Test("Pinned workspaces leave the buckets — they have their own section above")
    func pinnedWorkspacesAreExcludedFromBuckets() throws {
        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("pinned-today", Self.now, .active),
                ("loose-today", Self.now, .active),
            ]
        )
        let pinned = try #require(repo.workspaces.first { $0.name == "pinned-today" })

        #expect(renderedShape([repo]) == [["Today", "loose-today", "pinned-today"]])

        pinned.pinOrder = 0

        #expect(renderedShape([repo]) == [["Today", "loose-today"]])
    }

    @Test("A bucket whose only rows are pinned drops out entirely")
    func bucketOfOnlyPinnedRowsIsOmitted() throws {
        let repo = makeRepo(
            "alpha",
            workspaces: [
                ("today", Self.now, .active),
                ("older", days(3), .active),
            ]
        )
        let older = try #require(repo.workspaces.first { $0.name == "older" })
        older.pinOrder = 0

        #expect(renderedShape([repo]) == [["Today", "today"]])
    }

    @Test("Recent leaves the repo-grouped orderings alone")
    func recentDoesNotDisturbRepoSorting() {
        let controller = SidebarRepoSortController()
        let zed = Repo(name: "zed", localPath: URL(fileURLWithPath: "/tmp/zed"))
        let alpha = Repo(name: "Alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))

        let sorted = controller.sortedRepos([zed, alpha], mode: .recent, lastAccessedSnapshot: [:])

        #expect(sorted.map(\.name) == ["Alpha", "zed"])
    }
}
