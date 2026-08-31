//
//  SidebarWorkspacePresentationController.swift
//  WorkspaceManager
//

import Foundation
import WorkspaceManagerCore

/// What the selected workspace row's status line reads: which agent is at work, the run-state
/// summary the hover card also shows, and the fixed point the elapsed timer counts from.
/// `startedAt` is the session's registration time — written once, never moved — so the row can
/// hold it as a plain value and let its timer leaf own the clock. For sessions born in this
/// app run that is the session's lifetime; a reattach after relaunch registers anew, so the
/// clock restarts with it (a durable start date is a tracked follow-up).
struct SidebarLiveSessionStatus: Equatable {
    let kind: AgentKind
    let summary: String
    let startedAt: Date
}

struct SidebarWorkspacePresentationController {
    func paneCount(
        for key: HostTerminalSessionKey,
        paneCountBySessionKey: [HostTerminalSessionKey: Int]
    ) -> Int {
        paneCountBySessionKey[key] ?? 0
    }

    func sessionKey(
        for workspace: Workspace,
        registry: WorkspaceProviderRegistry,
        normalizePath: (URL) -> String
    ) -> HostTerminalSessionKey {
        if let provider = registry.provider(for: workspace) {
            return provider.sessionKey(for: WorkspaceProviderTarget(workspace))
        }

        return .hostPath(normalizePath(workspace.workspaceURL))
    }

    /// Everything one row needs to know about the tabs sharing its session key, gathered in a
    /// single pass. Rows compare on this (#1366), and the row's dot, its live status line, and
    /// its hover card are all derived from it, so a session's tabs are looked up once per row
    /// per render instead of once per consumer.
    ///
    /// The lookups stay closure-shaped for the reason `freshestAgentStatus` always was: a
    /// SwiftUI body passes `observedStatus(for:)`, so only the sessions actually rendered
    /// register Observation dependencies.
    func rowSessionState(
        for key: HostTerminalSessionKey,
        sessions: [HostTerminalSession],
        agentStatus: (UUID) -> AgentSessionStatus?,
        foregroundName: (UUID) -> String? = { _ in nil },
        transcriptTail: (UUID) -> String? = { _ in nil }
    ) -> SidebarRowSessionState {
        guard !sessions.isEmpty else { return SidebarRowSessionState() }
        let normalizedKey = key.normalized()
        let matching = sessions.filter { $0.key == normalizedKey }
        guard !matching.isEmpty else { return SidebarRowSessionState() }
        return SidebarRowSessionState(
            sessions: matching,
            statuses: matching.map { agentStatus($0.id) },
            foregroundNames: matching.map { foregroundName($0.id) },
            transcriptTails: matching.map { transcriptTail($0.id) }
        )
    }

    /// Pick the freshest registered `AgentSessionStatus` whose host session shares `key`.
    /// Returns `nil` when no session for that key has a registered status.
    func freshestAgentStatus(
        for key: HostTerminalSessionKey,
        sessions: [HostTerminalSession],
        agentStatus: (UUID) -> AgentSessionStatus?
    ) -> AgentSessionStatus? {
        rowSessionState(for: key, sessions: sessions, agentStatus: agentStatus).freshestStatus
    }

    /// The live status line for one session key, or nil when no session sharing it has a
    /// registered agent status. Resolved through the same `freshestAgentStatus` lookup the
    /// activity dot makes, so a row's line and its dot always describe the same session.
    func liveSessionStatus(
        for key: HostTerminalSessionKey,
        sessions: [HostTerminalSession],
        agentStatus: (UUID) -> AgentSessionStatus?
    ) -> SidebarLiveSessionStatus? {
        liveSessionStatus(
            from: rowSessionState(for: key, sessions: sessions, agentStatus: agentStatus))
    }

    /// The live status line for a row whose session state has already been gathered.
    func liveSessionStatus(from state: SidebarRowSessionState) -> SidebarLiveSessionStatus? {
        guard let status = state.freshestStatus else { return nil }
        return SidebarLiveSessionStatus(
            kind: status.kind,
            summary: AgentChromeProjection.runState(status.run).summaryText,
            startedAt: status.createdAt
        )
    }

    func sessionActivity(
        for key: HostTerminalSessionKey,
        paneCountBySessionKey: [HostTerminalSessionKey: Int],
        activeSessionKey: HostTerminalSessionKey?,
        sessions: [HostTerminalSession] = [],
        agentStatus: (UUID) -> AgentSessionStatus? = { _ in nil }
    ) -> SidebarSessionActivity {
        sessionActivity(
            for: key,
            paneCountBySessionKey: paneCountBySessionKey,
            activeSessionKey: activeSessionKey,
            sessionState: rowSessionState(
                for: key, sessions: sessions, agentStatus: agentStatus)
        )
    }

    /// The activity dot for a row whose session state has already been gathered.
    func sessionActivity(
        for key: HostTerminalSessionKey,
        paneCountBySessionKey: [HostTerminalSessionKey: Int],
        activeSessionKey: HostTerminalSessionKey?,
        sessionState: SidebarRowSessionState
    ) -> SidebarSessionActivity {
        // Prefer the agent-derived activity when the registry has a status for any
        // session sharing this key. Fall back to the existing pane-count signal so
        // sessions without registered agent state still show the inactive/live/active
        // dots they always have.
        let baseline = SidebarSessionActivity(
            hasLiveSession: paneCount(for: key, paneCountBySessionKey: paneCountBySessionKey) > 0,
            isActiveSession: activeSessionKey == key
        )

        guard let candidate = sessionState.freshestStatus else { return baseline }

        let agentDerived = SidebarSessionActivity.from(candidate)
        // If the registry only knows the session as `.idle`, the baseline `.live` /
        // `.active` is more informative — keep it.
        if agentDerived == .live { return baseline }
        // Preserve the active highlight even when agent state is more specific so
        // the user can still see which workspace they're focused on.
        if activeSessionKey == key, baseline == .active {
            return agentDerived
        }
        return agentDerived
    }

    func workspaceStatusMessage(
        workspaceID: UUID,
        connectingWorkspaceID: UUID?,
        workspaceAction: WorkspaceActionState?
    ) -> String? {
        if connectingWorkspaceID == workspaceID { return "Connecting..." }
        if let workspaceAction, workspaceAction.workspaceID == workspaceID {
            return workspaceAction.message
        }
        return nil
    }

    func providerDescriptor(
        for workspace: Workspace,
        registry: WorkspaceProviderRegistry
    ) -> WorkspaceProviderDescriptor? {
        registry.provider(for: workspace)?.descriptor
    }

    func providerDisplayName(
        for providerID: String,
        registry: WorkspaceProviderRegistry
    ) -> String {
        registry.provider(for: providerID)?.descriptor.displayName ?? providerID
    }

    func usesHostWorkspaceFiles(
        for workspace: Workspace,
        registry: WorkspaceProviderRegistry
    ) -> Bool {
        providerDescriptor(for: workspace, registry: registry)?.usesHostWorkspaceFiles ?? !workspace.isRemote
    }
}
