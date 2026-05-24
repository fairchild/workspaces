//
//  SwitchableIndexTests.swift
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SwitchableIndex")
struct SwitchableIndexTests {
    private func makeWorkspace(
        name: String,
        repo: Repo,
        lastAccessed: Date = Date(),
        branch: String? = nil
    ) -> Workspace {
        Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/ws/\(name)"),
            sourceRepo: repo,
            lastAccessedAt: lastAccessed,
            gitBranch: branch
        )
    }

    private func makeItem(
        name: String,
        repo: Repo,
        lastAccessed: Date = Date(),
        branch: String? = nil,
        indicator: SidebarSessionActivity = .inactive
    ) -> WorkspaceSwitchableItem {
        WorkspaceSwitchableItem(
            workspace: makeWorkspace(
                name: name, repo: repo, lastAccessed: lastAccessed, branch: branch
            ),
            indicator: indicator,
            waitingDescriptor: nil
        )
    }

    @Test("Empty query returns all items, recency-first")
    func emptyQueryReturnsAll() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let now = Date()
        let recent = makeItem(name: "feature-x", repo: repo, lastAccessed: now)
        let older = makeItem(
            name: "feature-y", repo: repo, lastAccessed: now.addingTimeInterval(-3600))

        let results = SwitchableIndex.rank([older, recent], query: "")
        #expect(results.map(\.id) == [recent.id, older.id])
    }

    @Test("Whitespace-only query behaves like empty")
    func whitespaceQuery() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let item = makeItem(name: "feature-x", repo: repo)
        #expect(SwitchableIndex.rank([item], query: "   ").count == 1)
    }

    @Test("Prefix matches outrank substring matches")
    func prefixOutranksSubstring() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let prefix = makeItem(name: "search-results", repo: repo)
        let substring = makeItem(name: "user-search", repo: repo)

        let results = SwitchableIndex.rank([substring, prefix], query: "search")
        #expect(results.first?.id == prefix.id)
    }

    @Test("Filter drops non-matching items")
    func filterDropsNonMatches() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let a = makeItem(name: "auth-fix", repo: repo)
        let b = makeItem(name: "payments-rewrite", repo: repo)

        let results = SwitchableIndex.rank([a, b], query: "auth")
        #expect(results.map(\.id) == [a.id])
    }

    @Test("Case-insensitive matching")
    func caseInsensitive() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let item = makeItem(name: "Auth-Fix", repo: repo)
        #expect(SwitchableIndex.rank([item], query: "AUTH").count == 1)
        #expect(SwitchableIndex.rank([item], query: "auth").count == 1)
    }

    @Test("Workspace matches against repo name and branch")
    func multiFieldMatch() {
        let repo = Repo(name: "payments", localPath: URL(fileURLWithPath: "/tmp/p"))
        let item = makeItem(
            name: "bugfix",
            repo: repo,
            branch: "fix-checkout-bug"
        )
        #expect(SwitchableIndex.rank([item], query: "payments").count == 1)
        #expect(SwitchableIndex.rank([item], query: "checkout").count == 1)
    }

    @Test("Repo adapter activates via selectRepo callback")
    func repoActivatesViaCallback() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let item = RepoSwitchableItem(repo: repo, indicator: .inactive)
        var selectedRepoID: UUID?
        let context = SwitchableContext(
            selectWorkspace: { _ in Issue.record("workspace handler should not fire") },
            selectRepo: { selectedRepoID = $0.id },
            selectWebSource: { _ in Issue.record("web handler should not fire") }
        )
        item.activate(context)
        #expect(selectedRepoID == repo.id)
    }

    @Test("Workspace adapter activates via selectWorkspace callback")
    func workspaceActivatesViaCallback() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let workspace = makeWorkspace(name: "feature", repo: repo)
        let item = WorkspaceSwitchableItem(
            workspace: workspace, indicator: .live, waitingDescriptor: nil
        )
        var selectedID: UUID?
        let context = SwitchableContext(
            selectWorkspace: { selectedID = $0.id },
            selectRepo: { _ in Issue.record("repo handler should not fire") },
            selectWebSource: { _ in Issue.record("web handler should not fire") }
        )
        item.activate(context)
        #expect(selectedID == workspace.id)
    }

    @Test("Limit caps the result set")
    func limitCaps() {
        let repo = Repo(name: "alpha", localPath: URL(fileURLWithPath: "/tmp/alpha"))
        let items = (0..<10).map { i in
            makeItem(name: "name-\(i)", repo: repo, lastAccessed: Date().addingTimeInterval(-Double(i)))
        }
        let results = SwitchableIndex.rank(items, query: "", limit: 3)
        #expect(results.count == 3)
    }
}
