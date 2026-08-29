//
//  MainWindowMaintenanceController.swift
//  WorkspaceManager
//
//  The main window's background maintenance work: the remote status-sync pass, the rule
//  picking archived workspaces that have aged out, and the sidebar-aggregator projection.
//  The archived purge itself stays in the view because it clears the current selection on
//  the way through; everything here is reachable without a window, so the decisions and the
//  save they drive are testable.
//

import Foundation
import SwiftData
import WorkspaceManagerCore
import os.log

private let perfLog = Logger(subsystem: "com.cloudcompute.workspaces", category: "PerformanceSignposts")
private let workspaceProviderLog = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceProvider"
)

@MainActor
struct MainWindowMaintenanceController {
    /// A workspace whose persisted status disagrees with what its provider reports.
    /// `previousStatus` is captured before the caller writes, so the log line reads the
    /// same transition the decision was made on.
    struct StatusChange {
        let workspace: Workspace
        let previousStatus: WorkspaceStatus
        let newStatus: WorkspaceStatus
    }

    /// One sidebar-aggregation pass, projected from the current model and session state.
    struct AggregatorInputs: Equatable {
        let workspaces: [WorkspaceStatusAggregator.WorkspaceInput]
        let repos: [WorkspaceStatusAggregator.RepoInput]
    }

    /// What one status-sync pass did. The pass also emits the `workspace_status_sync` perf
    /// line; this is the same tally as a return value, so callers and tests can assert the
    /// outcome without reading the log stream.
    struct StatusSyncOutcome: Equatable {
        let providerCount: Int
        let workspaceCount: Int
        let changedCount: Int
        let hadFailure: Bool

        static let noWork = StatusSyncOutcome(
            providerCount: 0, workspaceCount: 0, changedCount: 0, hadFailure: false
        )
    }

    // MARK: - Archived purge

    /// Local archived workspaces whose `.archived/` directory has aged past the configured
    /// retention. Workspaces without an `archivedAt` (archived before this was tracked) are
    /// never auto-purged, and a non-positive delay disables the sweep entirely.
    func expiredArchivedWorkspaces(
        _ workspaces: [Workspace],
        now: Date,
        delayDays: Int
    ) -> [Workspace] {
        guard delayDays > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(delayDays) * 86_400)
        return workspaces.filter { workspace in
            workspace.backend == .local
                && workspace.status == .archived
                && !workspace.isAdopted
                && (workspace.archivedAt.map { $0 <= cutoff } ?? false)
        }
    }

    // MARK: - Remote status sync

    /// Remote-backed workspaces that can be synced, grouped by the provider that owns them.
    /// Local workspaces and remote ones with no remote id have nothing to ask a provider about.
    func statusSyncGroups(repos: [Repo]) -> [String: [Workspace]] {
        let syncable = repos.flatMap(\.workspaces).filter {
            $0.backend != .local && $0.remoteId != nil
        }
        return Dictionary(grouping: syncable, by: \.backendIdentifier)
    }

    /// The status a provider reports, keyed by remote id. Traps on duplicate remote ids,
    /// which is the long-standing contract with providers.
    func statusesByRemoteID(
        from snapshots: [WorkspaceProviderStatusSnapshot]
    ) -> [String: WorkspaceStatus] {
        Dictionary(uniqueKeysWithValues: snapshots.map { ($0.remoteId, $0.status) })
    }

    /// What a provider's answer implies for one workspace, or `nil` when its status already
    /// matches. A workspace the provider no longer reports is treated as archived.
    ///
    /// Deciding one workspace at a time — rather than batching a group's decisions ahead of
    /// its writes — is what keeps a status read after any earlier write in the same pass, so
    /// a workspace reached twice in one group settles instead of transitioning twice.
    func statusChange(
        for workspace: Workspace,
        statusesByRemoteID: [String: WorkspaceStatus]
    ) -> StatusChange? {
        guard let remoteID = workspace.remoteId else { return nil }
        let newStatus = statusesByRemoteID[remoteID] ?? .archived
        guard workspace.status != newStatus else { return nil }
        return StatusChange(
            workspace: workspace,
            previousStatus: workspace.status,
            newStatus: newStatus
        )
    }

    /// Asks each provider for the current status of its remote workspaces and writes back
    /// what moved. Provider failures are isolated: one provider throwing is logged and marks
    /// the pass a partial failure without stopping the others, and the context is saved once
    /// at the end only if something actually changed.
    @discardableResult
    func syncWorkspaceStatuses(
        repos: [Repo],
        registry: WorkspaceProviderRegistry,
        modelContext: ModelContext,
        trigger: String
    ) async -> StatusSyncOutcome {
        let syncStartedAt = Date()
        let groupedWorkspaces = statusSyncGroups(repos: repos)
        let syncableCount = groupedWorkspaces.values.reduce(0) { $0 + $1.count }
        guard syncableCount > 0 else { return .noWork }

        var changed = false
        var changedCount = 0
        var hadFailure = false

        for (providerID, providerWorkspaces) in groupedWorkspaces {
            guard let provider = registry.provider(for: providerID) else { continue }

            let providerSyncStartedAt = Date()
            var providerChangedCount = 0
            var outcome = "success"

            do {
                let snapshots = try await provider.syncStatuses(
                    for: providerWorkspaces.map(WorkspaceProviderTarget.init)
                )
                let reportedStatuses = statusesByRemoteID(from: snapshots)

                for workspace in providerWorkspaces {
                    guard
                        let change = statusChange(
                            for: workspace,
                            statusesByRemoteID: reportedStatuses
                        )
                    else { continue }

                    workspaceProviderLog.info(
                        "[WorkspaceProvider] Syncing workspace '\(change.workspace.name, privacy: .public)' (\(providerID, privacy: .public)): \(change.previousStatus.rawValue, privacy: .public) -> \(change.newStatus.rawValue, privacy: .public)"
                    )
                    change.workspace.status = change.newStatus
                    if change.newStatus == .archived {
                        change.workspace.pinOrder = nil
                    }
                    changed = true
                    changedCount += 1
                    providerChangedCount += 1
                }
            } catch {
                outcome = "failure"
                hadFailure = true
                workspaceProviderLog.error(
                    "[WorkspaceProvider] Failed to sync \(providerID, privacy: .public) workspace statuses: \(error.localizedDescription, privacy: .public)"
                )
            }

            perfLog.info(
                "[Perf] metric=workspace_status_sync_provider duration_ms=\(String(format: "%.2f", Date().timeIntervalSince(providerSyncStartedAt) * 1000), privacy: .public) trigger=\(trigger, privacy: .public) provider=\(providerID, privacy: .public) workspace_count=\(providerWorkspaces.count, privacy: .public) changed_count=\(providerChangedCount, privacy: .public) outcome=\(outcome, privacy: .public)"
            )
        }

        if changed {
            try? modelContext.save()
        }

        perfLog.info(
            "[Perf] metric=workspace_status_sync duration_ms=\(String(format: "%.2f", Date().timeIntervalSince(syncStartedAt) * 1000), privacy: .public) trigger=\(trigger, privacy: .public) providers=\(groupedWorkspaces.count, privacy: .public) workspace_count=\(syncableCount, privacy: .public) changed_count=\(changedCount, privacy: .public) outcome=\(hadFailure ? "partial_failure" : "success", privacy: .public)"
        )

        return StatusSyncOutcome(
            providerCount: groupedWorkspaces.count,
            workspaceCount: syncableCount,
            changedCount: changedCount,
            hadFailure: hadFailure
        )
    }

    // MARK: - Sidebar aggregation

    /// Projects repos, workspaces, live sessions, and agent status into the aggregator's
    /// inputs. Pure over its arguments, so the sidebar's status roll-up is assertable
    /// without a window or a live registry.
    func aggregatorInputs(
        repos: [Repo],
        sessions: [HostTerminalSession],
        agentStatusBySessionID: [UUID: AgentSessionStatus],
        registry: WorkspaceProviderRegistry,
        normalizePath: (URL) -> String
    ) -> AggregatorInputs {
        let presentation = SidebarWorkspacePresentationController()

        let workspaceInputs: [WorkspaceStatusAggregator.WorkspaceInput] =
            repos
            .flatMap(\.workspaces)
            .map { workspace in
                let key = presentation.sessionKey(
                    for: workspace,
                    registry: registry,
                    normalizePath: normalizePath
                )
                let status = presentation.freshestAgentStatus(
                    for: key,
                    sessions: sessions,
                    agentStatus: { agentStatusBySessionID[$0] }
                )
                return WorkspaceStatusAggregator.WorkspaceInput(
                    workspaceID: workspace.id,
                    repoID: workspace.sourceRepo?.id,
                    lastAccessedAt: workspace.lastAccessedAt,
                    status: status
                )
            }

        let repoInputs: [WorkspaceStatusAggregator.RepoInput] = repos.map { repo in
            let key = HostTerminalSessionKey.repoPath(normalizePath(repo.localURL))
            let status = presentation.freshestAgentStatus(
                for: key,
                sessions: sessions,
                agentStatus: { agentStatusBySessionID[$0] }
            )
            return WorkspaceStatusAggregator.RepoInput(
                repoID: repo.id,
                lastAccessedAt: repo.lastAccessedAt,
                status: status
            )
        }

        return AggregatorInputs(workspaces: workspaceInputs, repos: repoInputs)
    }
}
