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
        #expect(aggregator.attentionItems.isEmpty)
        #expect(aggregator.attentionWorkspaces.isEmpty)
        #expect(aggregator.attentionCount == 0)
    }

    @Test("Attention list orders attention-first by severity, then recency")
    func attentionList() {
        let aggregator = WorkspaceStatusAggregator()
        let now = Date()
        let older = now.addingTimeInterval(-60)
        let oldest = now.addingTimeInterval(-120)
        let repoID = UUID()
        let recentAwaiting = UUID()
        let olderErrored = UUID()
        let oldestThinking = UUID()

        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: oldestThinking,
                    repoID: repoID,
                    lastAccessedAt: oldest,
                    status: status(run: .thinking)
                ),
                .init(
                    workspaceID: olderErrored,
                    repoID: repoID,
                    lastAccessedAt: older,
                    status: status(run: .errored(category: .toolFailure, message: nil))
                ),
                .init(
                    workspaceID: recentAwaiting,
                    repoID: repoID,
                    lastAccessedAt: now,
                    status: status(run: .awaitingInput(reason: .permissionPrompt))
                ),
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )

        #expect(aggregator.attentionCount == 2)
        // Severity-first: the older errored session outranks the more recent awaiting one
        // (errored > awaitingInput on the shared ladder); recency only breaks ties.
        #expect(aggregator.attentionItems.map(\.target) == [.workspace(olderErrored), .workspace(recentAwaiting)])
        #expect(aggregator.attentionWorkspaces == [olderErrored, recentAwaiting])
    }

    @Test("Repo-root attention contributes to the global attention list")
    func repoRootAttention() {
        let aggregator = WorkspaceStatusAggregator()
        let now = Date()
        let older = now.addingTimeInterval(-60)
        let repoID = UUID()
        let wsID = UUID()

        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: older,
                    status: status(run: .errored(category: .toolFailure, message: nil))
                )
            ],
            repos: [
                .init(
                    repoID: repoID,
                    lastAccessedAt: now,
                    status: status(run: .awaitingInput(reason: .permissionPrompt))
                )
            ]
        )

        #expect(aggregator.attentionCount == 2)
        // Severity-first: the errored workspace outranks the awaiting repo root despite the
        // repo root being more recently accessed.
        #expect(aggregator.attentionItems.map(\.target) == [.workspace(wsID), .repo(repoID)])
        #expect(aggregator.attentionTargets == [.workspace(wsID), .repo(repoID)])
        #expect(aggregator.attentionRepos == [repoID])
        #expect(aggregator.attentionWorkspaces == [wsID])
    }

    @Test("Acknowledged attention target is removed from the global attention list")
    func acknowledgedTargetDropsFromAttentionList() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()
        let hostID = UUID()
        let eventAt = Date()
        let workspace = WorkspaceStatusAggregator.WorkspaceInput(
            workspaceID: wsID,
            repoID: repoID,
            lastAccessedAt: eventAt,
            status: status(
                host: hostID,
                run: .awaitingInput(reason: .permissionPrompt),
                at: eventAt
            )
        )

        aggregator.update(workspaces: [workspace], repos: [.init(repoID: repoID, status: nil)])
        #expect(aggregator.attentionItems.map(\.target) == [.workspace(wsID)])

        aggregator.acknowledgeAttention(for: .workspace(wsID))
        aggregator.update(workspaces: [workspace], repos: [.init(repoID: repoID, status: nil)])

        #expect(aggregator.attentionItems.isEmpty)
        #expect(aggregator.attentionWorkspaces.isEmpty)
        #expect(aggregator.workspaceStatuses[wsID]?.run == .awaitingInput(reason: .permissionPrompt))
    }

    @Test("Newer attention event reappears after acknowledgement")
    func newerEventReappearsAfterAcknowledgement() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()
        let hostID = UUID()
        let eventAt = Date()
        let acknowledgedWorkspace = WorkspaceStatusAggregator.WorkspaceInput(
            workspaceID: wsID,
            repoID: repoID,
            lastAccessedAt: eventAt,
            status: status(
                host: hostID,
                run: .awaitingInput(reason: .permissionPrompt),
                at: eventAt
            )
        )

        aggregator.update(
            workspaces: [acknowledgedWorkspace],
            repos: [.init(repoID: repoID, status: nil)]
        )
        aggregator.acknowledgeAttention(for: .workspace(wsID))
        aggregator.update(
            workspaces: [acknowledgedWorkspace],
            repos: [.init(repoID: repoID, status: nil)]
        )
        #expect(aggregator.attentionItems.isEmpty)

        let newerWorkspace = WorkspaceStatusAggregator.WorkspaceInput(
            workspaceID: wsID,
            repoID: repoID,
            lastAccessedAt: eventAt,
            status: status(
                host: hostID,
                run: .awaitingInput(reason: .permissionPrompt),
                at: eventAt.addingTimeInterval(1)
            )
        )
        aggregator.update(workspaces: [newerWorkspace], repos: [.init(repoID: repoID, status: nil)])

        #expect(aggregator.attentionItems.map(\.target) == [.workspace(wsID)])
    }

    @Test("Masked acknowledged session stays hidden until it produces a newer event")
    func maskedAcknowledgementSurvivesFreshestStatusChanges() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()
        let acknowledgedHostID = UUID()
        let maskingHostID = UUID()
        let eventAt = Date()
        let acknowledgedStatus = status(
            host: acknowledgedHostID,
            run: .awaitingInput(reason: .permissionPrompt),
            at: eventAt
        )

        aggregator.acknowledgeAttention(for: acknowledgedStatus)
        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: eventAt,
                    status: status(
                        host: maskingHostID,
                        run: .thinking,
                        at: eventAt.addingTimeInterval(1)
                    )
                )
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )
        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: eventAt,
                    status: acknowledgedStatus
                )
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )

        #expect(aggregator.attentionItems.isEmpty)

        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: eventAt,
                    status: status(
                        host: acknowledgedHostID,
                        run: .awaitingInput(reason: .permissionPrompt),
                        at: eventAt.addingTimeInterval(2)
                    )
                )
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )

        #expect(aggregator.attentionItems.map(\.target) == [.workspace(wsID)])
    }

    @Test("demandsAttention only fires for awaiting/errored")
    func demandsAttentionMatrix() {
        #expect(WorkspaceStatusAggregator.demandsAttention(.awaitingInput(reason: .permissionPrompt)))
        #expect(WorkspaceStatusAggregator.demandsAttention(.errored(category: .server, message: nil)))
        #expect(!WorkspaceStatusAggregator.demandsAttention(.thinking))
        #expect(!WorkspaceStatusAggregator.demandsAttention(.runningTool(name: "x", detail: nil)))
        #expect(!WorkspaceStatusAggregator.demandsAttention(.idle))
        #expect(!WorkspaceStatusAggregator.demandsAttention(.complete))
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

    @Test("Repo status bubbles the most severe child on the shared ladder")
    func repoStatusBubblesMostSevere() {
        let aggregator = WorkspaceStatusAggregator()
        let now = Date()
        let repoID = UUID()
        aggregator.update(
            workspaces: [
                .init(workspaceID: UUID(), repoID: repoID, lastAccessedAt: now, status: status(run: .thinking)),
                .init(
                    workspaceID: UUID(), repoID: repoID, lastAccessedAt: now,
                    status: status(run: .errored(category: .server, message: nil))),
                .init(
                    workspaceID: UUID(), repoID: repoID, lastAccessedAt: now,
                    status: status(run: .runningTool(name: "grep", detail: nil))),
            ],
            repos: [.init(repoID: repoID, status: nil)]
        )

        // errored is the most severe child, so it represents the repo.
        let bubbled = aggregator.repoStatuses[repoID]?.run
        let isErrored: Bool = { if case .errored = bubbled { return true } else { return false } }()
        #expect(isErrored)
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

    @Test("Attention items preserve exact target state separate from bubbled repo status")
    func attentionItemsPreserveExactTargetState() {
        let aggregator = WorkspaceStatusAggregator()
        let repoID = UUID()
        let wsID = UUID()

        aggregator.update(
            workspaces: [
                .init(
                    workspaceID: wsID,
                    repoID: repoID,
                    lastAccessedAt: Date().addingTimeInterval(-30),
                    status: status(run: .errored(category: .toolFailure, message: "tool failed"))
                )
            ],
            repos: [
                .init(
                    repoID: repoID,
                    lastAccessedAt: Date(),
                    status: status(run: .awaitingInput(reason: .permissionPrompt))
                )
            ]
        )

        if case .errored = aggregator.repoStatuses[repoID]?.run {
            // pass
        } else {
            Issue.record("expected workspace error to remain the bubbled repo status")
        }

        let repoAttention = aggregator.attentionItems.first { $0.target == .repo(repoID) }
        if case .awaitingInput(reason: .permissionPrompt) = repoAttention?.run {
            // pass
        } else {
            Issue.record("expected repo attention item to keep the repo terminal status")
        }
    }
}
