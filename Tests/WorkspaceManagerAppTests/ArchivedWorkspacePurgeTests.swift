//
//  ArchivedWorkspacePurgeTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the pure selection rule that drives the archived-workspace purge sweep.
//

import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("ArchivedWorkspacePurge")
struct ArchivedWorkspacePurgeTests {
    private let controller = MainWindowMaintenanceController()
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let day = 86_400.0

    private func makeContext() throws -> ModelContext {
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    @discardableResult
    private func makeWorkspace(
        in context: ModelContext,
        repo: Repo,
        name: String,
        status: WorkspaceStatus,
        backendIdentifier: String,
        archivedAt: Date?
    ) -> Workspace {
        let workspace = Workspace(
            name: name,
            path: URL(fileURLWithPath: "/tmp/workspaces/\(name)"),
            sourceRepo: repo,
            status: status,
            archivedAt: archivedAt,
            backendIdentifier: backendIdentifier
        )
        context.insert(workspace)
        return workspace
    }

    @Test("Selects only local archived workspaces past the delay (boundary inclusive)")
    func selectsExpiredLocalArchived() throws {
        let context = try makeContext()
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)

        let expired = makeWorkspace(
            in: context, repo: repo, name: "expired",
            status: .archived, backendIdentifier: "local",
            archivedAt: now.addingTimeInterval(-40 * day)
        )
        let boundary = makeWorkspace(
            in: context, repo: repo, name: "boundary",
            status: .archived, backendIdentifier: "local",
            archivedAt: now.addingTimeInterval(-30 * day)
        )
        makeWorkspace(
            in: context, repo: repo, name: "fresh",
            status: .archived, backendIdentifier: "local",
            archivedAt: now.addingTimeInterval(-10 * day)
        )
        makeWorkspace(
            in: context, repo: repo, name: "no-timestamp",
            status: .archived, backendIdentifier: "local", archivedAt: nil
        )
        makeWorkspace(
            in: context, repo: repo, name: "active",
            status: .active, backendIdentifier: "local", archivedAt: nil
        )
        makeWorkspace(
            in: context, repo: repo, name: "remote-archived",
            status: .archived, backendIdentifier: "daytona",
            archivedAt: now.addingTimeInterval(-40 * day)
        )

        let result = controller.expiredArchivedWorkspaces(
            [expired, boundary],
            now: now,
            delayDays: 30
        )

        // Re-run over the full set to confirm filtering excludes the others.
        let all = repo.workspaces
        let resultAll = controller.expiredArchivedWorkspaces(all, now: now, delayDays: 30)
        #expect(Set(resultAll.map(\.name)) == ["expired", "boundary"])
        #expect(Set(result.map(\.name)) == ["expired", "boundary"])
    }

    @Test("Zero or negative delay disables purge")
    func zeroDelayDisablesPurge() throws {
        let context = try makeContext()
        let repo = Repo(name: "api", localPath: URL(fileURLWithPath: "/tmp/api"))
        context.insert(repo)
        let expired = makeWorkspace(
            in: context, repo: repo, name: "expired",
            status: .archived, backendIdentifier: "local",
            archivedAt: now.addingTimeInterval(-400 * day)
        )

        #expect(controller.expiredArchivedWorkspaces([expired], now: now, delayDays: 0).isEmpty)
        #expect(controller.expiredArchivedWorkspaces([expired], now: now, delayDays: -5).isEmpty)
    }
}
