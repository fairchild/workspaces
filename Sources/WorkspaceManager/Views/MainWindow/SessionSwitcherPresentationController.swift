//
//  SessionSwitcherPresentationController.swift
//  WorkspaceManager
//
//  The projections the main window feeds the session switcher and command palette: per-workspace
//  session keys, per-workspace activity, and per-repo activity — the last of which merges a repo's
//  own session activity with the status bubbled up from its workspaces. `SessionSwitcherSnapshot`
//  ranks and assembles the rows; this decides what it is ranking, so those inputs are assertable
//  without a window.
//

import Foundation
import WorkspaceManagerCore

/// Everything the switcher's projections read, gathered once per pass so a rebuild takes one
/// consistent view of sessions, statuses, and selection rather than re-reading them per row.
struct SessionSwitcherProjectionContext {
    let repos: [Repo]
    let webSources: [WebSource]
    let sessions: [HostTerminalSession]
    let activeSessionID: UUID?
    let agentStatusBySessionID: [UUID: AgentSessionStatus]
    let paneCountBySessionKey: [HostTerminalSessionKey: Int]
    let activeSessionKey: HostTerminalSessionKey?
    /// Per-repo status rolled up from that repo's workspaces by `WorkspaceStatusAggregator`.
    let bubbledRepoStatuses: [UUID: AgentSessionStatus]
    let registry: WorkspaceProviderRegistry
    let normalizePath: (URL) -> String
}

@MainActor
struct SessionSwitcherPresentationController {
    private let presentation = SidebarWorkspacePresentationController()

    /// The host-session key each workspace's row routes to.
    func workspaceSessionKeys(
        _ context: SessionSwitcherProjectionContext
    ) -> [UUID: HostTerminalSessionKey] {
        Dictionary(
            uniqueKeysWithValues: context.repos.flatMap(\.workspaces).map { workspace in
                (workspace.id, sessionKey(for: workspace, in: context))
            }
        )
    }

    /// Activity for each workspace row, read from the same session and agent-status state the
    /// sidebar uses so the two surfaces cannot disagree.
    func workspaceActivities(
        _ context: SessionSwitcherProjectionContext
    ) -> [UUID: SessionActivity] {
        Dictionary(
            uniqueKeysWithValues: context.repos.flatMap(\.workspaces).map { workspace in
                let activity = presentation.sessionActivity(
                    for: sessionKey(for: workspace, in: context),
                    paneCountBySessionKey: context.paneCountBySessionKey,
                    activeSessionKey: context.activeSessionKey,
                    sessions: context.sessions,
                    agentStatusBySessionID: context.agentStatusBySessionID
                )
                return (workspace.id, activity)
            }
        )
    }

    /// Activity for each repo row. A repo has its own terminal session, but it also stands in for
    /// its workspaces — so its row merges the baseline activity of its own session with the status
    /// the aggregator bubbled up from below. A repo the aggregator has nothing for contributes
    /// `.inactive`, leaving the baseline to speak for itself.
    func repoActivities(
        _ context: SessionSwitcherProjectionContext
    ) -> [UUID: SessionActivity] {
        Dictionary(
            uniqueKeysWithValues: context.repos.map { repo in
                let key = HostTerminalSessionKey.repoPath(context.normalizePath(repo.localURL))
                let baseline = presentation.sessionActivity(
                    for: key,
                    paneCountBySessionKey: context.paneCountBySessionKey,
                    activeSessionKey: context.activeSessionKey,
                    sessions: context.sessions,
                    agentStatusBySessionID: context.agentStatusBySessionID
                )
                let bubbled =
                    context.bubbledRepoStatuses[repo.id]
                    .map { SessionActivity.from($0) } ?? .inactive
                return (repo.id, baseline.mergedWithBubbled(bubbled))
            }
        )
    }

    /// One switcher snapshot, built from the projections above.
    func snapshot(_ context: SessionSwitcherProjectionContext) -> SessionSwitcherSnapshot {
        SessionSwitcherSnapshot.make(
            repos: context.repos,
            webSources: context.webSources,
            sessions: context.sessions,
            activeSessionID: context.activeSessionID,
            agentStatuses: context.agentStatusBySessionID,
            paneCountBySessionKey: context.paneCountBySessionKey,
            workspaceSessionKeys: workspaceSessionKeys(context),
            workspaceActivities: workspaceActivities(context),
            repoActivities: repoActivities(context)
        )
    }

    private func sessionKey(
        for workspace: Workspace,
        in context: SessionSwitcherProjectionContext
    ) -> HostTerminalSessionKey {
        presentation.sessionKey(
            for: workspace,
            registry: context.registry,
            normalizePath: context.normalizePath
        )
    }
}
