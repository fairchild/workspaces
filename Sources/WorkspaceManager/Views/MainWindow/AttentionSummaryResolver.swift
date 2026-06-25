//
//  AttentionSummaryResolver.swift
//  WorkspaceManager
//
//  Turns agent attention targets into compact toolbar dropdown rows. Keeping
//  this outside the SwiftUI view makes the summary text testable and lets the
//  performance benchmark measure the same resolution path the toolbar uses.
//

import Foundation
import WorkspaceManagerCore

struct AttentionSummaryItem: Identifiable, Equatable {
    let id: String
    let target: WorkspaceStatusAggregator.AttentionTarget
    let title: String
    let context: String
    let detail: String
    let badge: String
    let systemImage: String
    let isError: Bool
}

struct AttentionSummaryResolver {
    static func resolve(
        attentionItems: [WorkspaceStatusAggregator.AttentionItem],
        repos: [Repo]
    ) -> [AttentionSummaryItem] {
        guard !attentionItems.isEmpty, !repos.isEmpty else { return [] }

        var reposByID: [UUID: Repo] = [:]
        reposByID.reserveCapacity(repos.count)
        var workspacesByID: [UUID: (workspace: Workspace, repo: Repo)] = [:]

        for repo in repos {
            reposByID[repo.id] = repo
            for workspace in repo.workspaces {
                workspacesByID[workspace.id] = (workspace, repo)
            }
        }

        return attentionItems.compactMap { item in
            let presentation = presentation(for: item.run)
            switch item.target {
            case .workspace(let id):
                guard let resolved = workspacesByID[id] else { return nil }
                return AttentionSummaryItem(
                    id: item.id,
                    target: item.target,
                    title: resolved.workspace.name,
                    context: "\(resolved.repo.name) tab",
                    detail: presentation.detail,
                    badge: presentation.badge,
                    systemImage: presentation.systemImage,
                    isError: presentation.isError
                )
            case .repo(let id):
                guard let repo = reposByID[id] else { return nil }
                return AttentionSummaryItem(
                    id: item.id,
                    target: item.target,
                    title: repo.name,
                    context: "Repo tab",
                    detail: presentation.detail,
                    badge: presentation.badge,
                    systemImage: presentation.systemImage,
                    isError: presentation.isError
                )
            }
        }
    }

    private static func presentation(
        for run: AgentRunState
    ) -> (badge: String, detail: String, systemImage: String, isError: Bool) {
        switch run {
        case .awaitingInput(let reason):
            switch reason {
            case .permissionPrompt:
                return ("Permission", "Awaiting permission", "hand.raised.fill", false)
            case .idlePrompt:
                return ("Prompt", "Waiting for your reply", "text.bubble.fill", false)
            case .custom:
                return ("Input", "Waiting for input", "questionmark.bubble.fill", false)
            }
        case .errored(_, let message):
            let detail = trimmed(message) ?? "Agent errored"
            return ("Error", detail, "exclamationmark.triangle.fill", true)
        case .idle, .thinking, .runningTool, .complete:
            return ("Needs you", "Needs attention", "bell.badge.fill", false)
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        if trimmedValue.count <= 72 { return trimmedValue }
        let endIndex = trimmedValue.index(trimmedValue.startIndex, offsetBy: 69)
        return "\(trimmedValue[..<endIndex])..."
    }
}
