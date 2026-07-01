//
//  AttentionSummaryResolver.swift
//  WorkspaceManager
//
//  Adapts SwiftData repositories into the core Attention summary values used
//  by the toolbar. The portable resolver lives in WorkspaceManagerCore so
//  companion surfaces can reuse the same Attention language.
//

import WorkspaceManagerCore

extension AttentionWorkspaceSnapshot {
    fileprivate init(workspace: Workspace) {
        self.init(id: workspace.id, name: workspace.name)
    }
}

extension AttentionRepositorySnapshot {
    fileprivate init(repo: Repo) {
        self.init(
            id: repo.id,
            name: repo.name,
            workspaces: repo.workspaces.map(AttentionWorkspaceSnapshot.init(workspace:))
        )
    }
}

extension AttentionSummaryResolver {
    static func resolve(
        attentionItems: [WorkspaceStatusAggregator.AttentionItem],
        repos: [Repo]
    ) -> [AttentionSummaryItem] {
        resolve(
            attentionItems: attentionItems,
            repositories: repos.map(AttentionRepositorySnapshot.init(repo:))
        )
    }
}
