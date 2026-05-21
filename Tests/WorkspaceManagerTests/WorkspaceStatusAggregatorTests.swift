//
//  WorkspaceStatusAggregatorTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
@Suite("WorkspaceStatusAggregator")
struct WorkspaceStatusAggregatorTests {
    private func status(
        host: UUID = UUID(),
        cwd: String = "/tmp/w",
        run: AgentRunState,
        at date: Date = Date()
    ) -> AgentSessionStatus {
        AgentSessionStatus(
            hostSessionID: host,
            cwd: cwd,
            run: run,
            lastEventAt: date
        )
    }

    @Test("Empty inputs yield empty outputs")
    func emptyInputs() {
        let aggregator = WorkspaceStatusAggregator()
        aggregator.update(workspaces: [], repos: [])
        #expect(aggregator.workspaceStatuses.isEmpty)
        #expect(aggregator.repoStatuses.isEmpty)
    }

    @Test("Awaiting-input workspace bubbles to its repo")
    func bubblesAwaitingInput() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()
        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: Date(),
                    status: status(run: .awaitingInput(reason: .permissionPrompt))
                )
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )
        let repoRun = aggregator.repoStatuses[repoID]?.run
        if case .awaitingInput = repoRun {
            // pass
        } else {
            Issue.record("expected awaitingInput, got \(String(describing: repoRun))")
        }
    }

    @Test("Most-severe child status wins for the repo row")
    func mostSevereWins() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let awaitingID = UUID()
        let erroredID = UUID()
        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: awaitingID,
                    repoID: repoID,
                    lastAccessedAt: Date(),
                    status: status(run: .awaitingInput(reason: .idlePrompt))
                ),
                .init(
                    workspaceID: erroredID,
                    repoID: repoID,
                    lastAccessedAt: Date(),
                    status: status(run: .errored(category: .toolFailure, message: nil))
                ),
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )
        if case .errored = aggregator.repoStatuses[repoID]?.run {
            // pass
        } else {
            Issue.record("expected errored to win, got \(String(describing: aggregator.repoStatuses[repoID]?.run))")
        }
    }

    @Test("Repo's own terminal status is considered alongside children")
    func includesRepoOwnStatus() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()
        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: Date(),
                    status: status(run: .thinking)
                )
            ],
            repos: [
                .init(
                    repoID: repoID,
                    status: status(run: .errored(category: .server, message: "boom"))
                )
            ]
        )
        if case .errored = aggregator.repoStatuses[repoID]?.run {
            // pass
        } else {
            Issue.record("expected repo own errored to win")
        }
    }

    @Test("Severity ordering matches the documented hierarchy")
    func severityOrdering() {
        let errored = WorkspaceStatusAggregator.severity(
            of: .errored(category: .unknown, message: nil))
        let awaiting = WorkspaceStatusAggregator.severity(of: .awaitingInput(reason: .custom))
        let runningTool = WorkspaceStatusAggregator.severity(
            of: .runningTool(name: "x", detail: nil))
        let thinking = WorkspaceStatusAggregator.severity(of: .thinking)
        let idle = WorkspaceStatusAggregator.severity(of: .idle)
        let complete = WorkspaceStatusAggregator.severity(of: .complete)

        #expect(errored > awaiting)
        #expect(awaiting > runningTool)
        #expect(runningTool > thinking)
        #expect(thinking > idle)
        #expect(idle == complete)
    }

    @Test("Workspaces without status are absent from workspaceStatuses")
    func skipsMissingStatuses() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()
        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: Date(),
                    status: nil
                )
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )
        #expect(aggregator.workspaceStatuses.isEmpty)
        #expect(aggregator.repoStatuses[repoID] == nil)
    }

    @Test("Update is idempotent — repeat call doesn't mutate published values")
    func idempotent() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()
        let workspace = WorkspaceStatusAggregator.WorkspaceInput(
            workspaceID: wsID,
            repoID: repoID,
            lastAccessedAt: Date(),
            status: status(run: .awaitingInput(reason: .permissionPrompt))
        )
        aggregator.update(workspaces: [workspace], repos: [.init(repoID: repoID, status: nil)])
        let firstSnapshot = aggregator.repoStatuses
        aggregator.update(workspaces: [workspace], repos: [.init(repoID: repoID, status: nil)])
        #expect(aggregator.repoStatuses == firstSnapshot)
    }
}
