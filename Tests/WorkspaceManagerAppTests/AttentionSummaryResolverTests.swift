//
//  AttentionSummaryResolverTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("AttentionSummaryResolver Mac adapter")
struct AttentionSummaryResolverAdapterTests {
    @Test("Converts SwiftData repos into core attention snapshots")
    func convertsSwiftDataReposIntoCoreSnapshots() {
        let repo = Repo(
            name: "workspaces",
            localPath: URL(fileURLWithPath: "/tmp/workspaces"),
            lastAccessedAt: Date()
        )
        let workspace = Workspace(
            name: "notification-menu",
            path: URL(fileURLWithPath: "/tmp/workspaces/notification-menu"),
            sourceRepo: repo,
            lastAccessedAt: Date()
        )
        repo.workspaces = [workspace]

        let rows = AttentionSummaryResolver.resolve(
            attentionItems: [
                .init(
                    target: .workspace(workspace.id),
                    hostSessionID: UUID(),
                    run: .awaitingInput(reason: .permissionPrompt),
                    lastEventAt: Date(),
                    lastAccessedAt: Date()
                ),
                .init(
                    target: .repo(repo.id),
                    hostSessionID: UUID(),
                    run: .errored(category: .toolFailure, message: "merge failed"),
                    lastEventAt: Date(),
                    lastAccessedAt: Date().addingTimeInterval(-30)
                ),
            ],
            repos: [repo]
        )

        #expect(rows.count == 2)
        #expect(rows[0].title == "notification-menu")
        #expect(rows[0].context == "workspaces tab")
        #expect(rows[0].badge == "Permission")
        #expect(rows[1].title == "workspaces")
        #expect(rows[1].context == "Repo tab")
        #expect(rows[1].badge == "Error")
        #expect(rows.first?.target == .workspace(workspace.id))
    }
}
