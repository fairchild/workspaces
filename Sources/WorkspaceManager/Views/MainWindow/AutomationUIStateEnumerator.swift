//
//  AutomationUIStateEnumerator.swift
//  WorkspaceManager
//
//  Projects the main window's live chrome — selection, banners, sidebar rows, the
//  attention pill, terminal topology — into the structural `AutomationUIStateCapture`
//  the operator-scope `GET /v1/ui-state` route returns. The same MainActor read the
//  workspace inventory performs, extended to visible chrome; ordering and token rules
//  live in `AutomationUIStateProjection` so tests and goldens share one author.
//

import Foundation
import WorkspaceManagerCore

enum AutomationUIStateEnumerator {
    @MainActor
    static func capture(
        repos: [Repo],
        selectedWorkspaceID: UUID?,
        selectedRepoID: UUID?,
        workspaceStatuses: [UUID: AgentSessionStatus],
        attentionCount: Int,
        minimalToolbar: Bool,
        banners: [AutomationUIBanner],
        tileTreeStore: TileTreeStore
    ) -> AutomationUIStateCapture {
        let workspacesByID = Dictionary(
            uniqueKeysWithValues: repos.flatMap(\.workspaces).map { ($0.id, $0) }
        )
        let selectedWorkspace = selectedWorkspaceID.flatMap { workspacesByID[$0] }
        let selectedRepo = selectedRepoID.flatMap { id in repos.first { $0.id == id } }

        let selection: AutomationUIStateSelection
        if let selectedWorkspace {
            selection = AutomationUIStateSelection(kind: .workspace, name: selectedWorkspace.name)
        } else if let selectedRepo {
            selection = AutomationUIStateSelection(kind: .repo, name: selectedRepo.name)
        } else {
            selection = AutomationUIStateSelection(kind: .none, name: nil)
        }

        let sidebar = repos.map { repo in
            AutomationUIStateRepoSection(
                name: repo.name,
                isSelected: repo.id == selectedRepoID,
                workspaces: repo.workspaces.map { workspace in
                    AutomationUIStateWorkspaceRow(
                        name: workspace.name,
                        status: workspace.status.rawValue,
                        isSelected: workspace.id == selectedWorkspaceID,
                        attention: workspaceStatuses[workspace.id].flatMap {
                            AutomationUIStateProjection.statusToken(for: $0.run)
                        }
                    )
                }
            )
        }

        let topology = terminalTopology(in: tileTreeStore)
        let state = AutomationUIStateProjection.snapshot(
            selection: selection,
            banners: banners,
            attentionCount: attentionCount,
            minimalToolbar: minimalToolbar,
            sidebar: sidebar,
            terminal: topology.terminal
        )
        return AutomationUIStateCapture(
            state: state,
            volatile: AutomationUIStateVolatile(
                selectedWorkspaceID: selectedWorkspaceID,
                selectedRepoID: selectedRepoID,
                tabTitles: topology.tabTitles
            )
        )
    }

    /// Tab/split topology for the scope containing the active session, plus the
    /// (volatile, shell-controlled) tab titles in tab order.
    @MainActor
    private static func terminalTopology(
        in tileTreeStore: TileTreeStore
    ) -> (terminal: AutomationUIStateTerminal, tabTitles: [String]) {
        guard
            let activeSessionID = tileTreeStore.activeSessionID,
            let primaryID = tileTreeStore.primarySessionID(containing: activeSessionID),
            let primarySession = tileTreeStore.sessions.first(where: { $0.id == primaryID })
        else {
            return (AutomationUIStateTerminal(attached: false, tabCount: 0, splitCount: 0), [])
        }
        let tabs = tileTreeStore.sessions(inScope: primarySession.key)
        let splitCount = tileTreeStore.splitSessions(forPrimarySessionID: primaryID).count
        let titles = tabs.map { session in
            tileTreeStore.tabTitleOverride(for: session.id)
                ?? tileTreeStore.surfaceStore.displayTitle(for: session)
        }
        return (
            AutomationUIStateTerminal(attached: true, tabCount: tabs.count, splitCount: splitCount),
            titles
        )
    }
}
