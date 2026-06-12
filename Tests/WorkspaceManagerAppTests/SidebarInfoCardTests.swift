import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("SidebarInfoCard")
struct SidebarInfoCardTests {
    private func agentTab(title: String = "Claude Code") -> SidebarTabSummary {
        SidebarTabSummary(
            id: UUID(),
            title: title,
            agentStatus: AgentSessionStatus(hostSessionID: UUID(), kind: .claudeCode, cwd: "/tmp")
        )
    }

    private func plainTab(title: String) -> SidebarTabSummary {
        SidebarTabSummary(id: UUID(), title: title)
    }

    @Test("Name-only — no branch, no tabs — has no content")
    func nameOnlyHasNoContent() {
        #expect(!SidebarInfoCard.hasContent(name: "repo", branch: nil, tabs: []))
        #expect(!SidebarInfoCard.hasContent(name: "repo", branch: "", tabs: []))
    }

    @Test("A branch is content")
    func branchIsContent() {
        #expect(SidebarInfoCard.hasContent(name: "ws", branch: "main", tabs: []))
    }

    @Test("An agent tab is content")
    func agentTabIsContent() {
        #expect(SidebarInfoCard.hasContent(name: "repo", branch: nil, tabs: [agentTab()]))
    }

    @Test("A lone plain tab whose title equals the name adds nothing")
    func loneRedundantTabHasNoContent() {
        #expect(!SidebarInfoCard.hasContent(name: "repo", branch: nil, tabs: [plainTab(title: "repo")]))
    }

    @Test("A lone plain tab with a distinct title is content")
    func loneDistinctTabIsContent() {
        #expect(
            SidebarInfoCard.hasContent(name: "repo", branch: nil, tabs: [plainTab(title: "server.ts")]))
    }

    @Test("Multiple tabs are content even when plain")
    func multiplePlainTabsAreContent() {
        let tabs = [plainTab(title: "repo"), plainTab(title: "repo")]
        #expect(SidebarInfoCard.hasContent(name: "repo", branch: nil, tabs: tabs))
    }
}
