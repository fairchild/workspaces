import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("SidebarInfoCard")
struct SidebarInfoCardTests {
    private func status() -> AgentSessionStatus {
        AgentSessionStatus(hostSessionID: UUID(), kind: .claudeCode, cwd: "/tmp")
    }

    @Test("Name-only card has no content")
    func nameOnlyHasNoContent() {
        #expect(!SidebarInfoCard.hasContent(branch: nil, agentStatus: nil))
        #expect(!SidebarInfoCard.hasContent(branch: "", agentStatus: nil))
    }

    @Test("A branch is content")
    func branchIsContent() {
        #expect(SidebarInfoCard.hasContent(branch: "main", agentStatus: nil))
    }

    @Test("An agent status is content")
    func agentStatusIsContent() {
        #expect(SidebarInfoCard.hasContent(branch: nil, agentStatus: status()))
        #expect(SidebarInfoCard.hasContent(branch: "", agentStatus: status()))
    }
}
