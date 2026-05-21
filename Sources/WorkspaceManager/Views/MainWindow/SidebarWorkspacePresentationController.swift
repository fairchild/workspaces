//
//  SidebarWorkspacePresentationController.swift
//  WorkspaceManager
//

import Foundation
import WorkspaceManagerCore

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

    /// Pick the freshest registered `AgentSessionStatus` whose host session shares `key`.
    /// Returns `nil` when no session for that key has a registered status.
    func freshestAgentStatus(
        for key: HostTerminalSessionKey,
        sessions: [HostTerminalSession],
        agentStatusBySessionID: [UUID: AgentSessionStatus]
    ) -> AgentSessionStatus? {
        guard !agentStatusBySessionID.isEmpty, !sessions.isEmpty else { return nil }
        let normalizedKey = key.normalized()
        return sessions
            .filter { $0.key == normalizedKey }
            .compactMap { agentStatusBySessionID[$0.id] }
            .max { $0.lastEventAt < $1.lastEventAt }
    }

    func sessionActivity(
        for key: HostTerminalSessionKey,
        paneCountBySessionKey: [HostTerminalSessionKey: Int],
        activeSessionKey: HostTerminalSessionKey?,
        sessions: [HostTerminalSession] = [],
        agentStatusBySessionID: [UUID: AgentSessionStatus] = [:]
    ) -> SidebarSessionActivity {
        // Prefer the agent-derived activity when the registry has a status for any
        // session sharing this key. Fall back to the existing pane-count signal so
        // sessions without registered agent state still show the inactive/live/active
        // dots they always have.
        let baseline = SidebarSessionActivity(
            hasLiveSession: paneCount(for: key, paneCountBySessionKey: paneCountBySessionKey) > 0,
            isActiveSession: activeSessionKey == key
        )

        let candidate = freshestAgentStatus(
            for: key,
            sessions: sessions,
            agentStatusBySessionID: agentStatusBySessionID
        )

        guard let candidate else { return baseline }

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
