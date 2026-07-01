//
//  AttentionSummaryResolverTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("AttentionSummaryResolver")
struct AttentionSummaryResolverTests {
    @Test("Resolves workspace and repo attention rows")
    func resolvesWorkspaceAndRepoRows() {
        let repoID = UUID()
        let workspaceID = UUID()
        let rows = AttentionSummaryResolver.resolve(
            attentionItems: [
                item(
                    target: .workspace(workspaceID),
                    run: .awaitingInput(reason: .permissionPrompt)
                ),
                item(
                    target: .repo(repoID),
                    run: .errored(category: .toolFailure, message: "merge failed"),
                    at: Date().addingTimeInterval(-30)
                ),
            ],
            repositories: [
                .init(
                    id: repoID,
                    name: "workspaces",
                    workspaces: [.init(id: workspaceID, name: "notification-menu")]
                )
            ]
        )

        #expect(rows.count == 2)
        #expect(rows[0].title == "notification-menu")
        #expect(rows[0].context == "workspaces tab")
        #expect(rows[0].badge == "Permission")
        #expect(rows[0].isError == false)
        #expect(rows[1].title == "workspaces")
        #expect(rows[1].context == "Repo tab")
        #expect(rows[1].badge == "Error")
        #expect(rows[1].detail == "merge failed")
        #expect(rows[1].isError)
    }

    @Test("Skips stale attention targets")
    func skipsStaleAttentionTargets() {
        let rows = AttentionSummaryResolver.resolve(
            attentionItems: [
                item(
                    target: .workspace(UUID()),
                    run: .awaitingInput(reason: .custom)
                )
            ],
            repositories: [.init(id: UUID(), name: "workspaces", workspaces: [])]
        )

        #expect(rows.isEmpty)
    }

    @Test("Resolved rows are the actionable count when stale targets are mixed in")
    func resolvedRowsAreActionableCount() {
        let repoID = UUID()
        let workspaceID = UUID()
        let rows = AttentionSummaryResolver.resolve(
            attentionItems: [
                item(
                    target: .workspace(workspaceID),
                    run: .awaitingInput(reason: .permissionPrompt)
                ),
                item(
                    target: .workspace(UUID()),
                    run: .errored(category: .toolFailure, message: "stale session"),
                    at: Date().addingTimeInterval(-30)
                ),
            ],
            repositories: [
                .init(
                    id: repoID,
                    name: "workspaces",
                    workspaces: [.init(id: workspaceID, name: "notification-menu")]
                )
            ]
        )

        #expect(rows.count == 1)
        #expect(rows.first?.target == .workspace(workspaceID))
    }

    @Test("Trims long error detail")
    func trimsLongErrorDetail() {
        let repoID = UUID()
        let message = String(repeating: "x", count: 90)

        let rows = AttentionSummaryResolver.resolve(
            attentionItems: [
                item(
                    target: .repo(repoID),
                    run: .errored(category: .toolFailure, message: message)
                )
            ],
            repositories: [.init(id: repoID, name: "workspaces", workspaces: [])]
        )

        #expect(rows.first?.detail.count == 72)
        #expect(rows.first?.detail.hasSuffix("...") == true)
    }

    private func item(
        target: WorkspaceStatusAggregator.AttentionTarget,
        run: AgentRunState,
        at date: Date = Date()
    ) -> WorkspaceStatusAggregator.AttentionItem {
        WorkspaceStatusAggregator.AttentionItem(
            target: target,
            hostSessionID: UUID(),
            run: run,
            lastEventAt: date,
            lastAccessedAt: date
        )
    }
}
