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

    func sessionActivity(
        for key: HostTerminalSessionKey,
        paneCountBySessionKey: [HostTerminalSessionKey: Int],
        activeSessionKey: HostTerminalSessionKey?
    ) -> SidebarSessionActivity {
        SidebarSessionActivity(
            hasLiveSession: paneCount(for: key, paneCountBySessionKey: paneCountBySessionKey) > 0,
            isActiveSession: activeSessionKey == key
        )
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
