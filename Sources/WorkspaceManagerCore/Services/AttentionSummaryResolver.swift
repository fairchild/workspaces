//
//  AttentionSummaryResolver.swift
//  WorkspaceManagerCore
//
//  Turns Attention items plus lightweight repository snapshots into portable
//  summary rows. Platform views render these rows, but do not decide which
//  Attention targets exist or how their agent states should read.
//

import Foundation

public struct AttentionWorkspaceSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AttentionRepositorySnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let workspaces: [AttentionWorkspaceSnapshot]

    public init(id: UUID, name: String, workspaces: [AttentionWorkspaceSnapshot]) {
        self.id = id
        self.name = name
        self.workspaces = workspaces
    }
}

public struct AttentionSummaryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let target: WorkspaceStatusAggregator.AttentionTarget
    public let title: String
    public let context: String
    public let detail: String
    public let badge: String
    public let systemImage: String
    public let isError: Bool

    public init(
        id: String,
        target: WorkspaceStatusAggregator.AttentionTarget,
        title: String,
        context: String,
        detail: String,
        badge: String,
        systemImage: String,
        isError: Bool
    ) {
        self.id = id
        self.target = target
        self.title = title
        self.context = context
        self.detail = detail
        self.badge = badge
        self.systemImage = systemImage
        self.isError = isError
    }
}

public enum AttentionSummaryResolver {
    public static func resolve(
        attentionItems: [WorkspaceStatusAggregator.AttentionItem],
        repositories: [AttentionRepositorySnapshot]
    ) -> [AttentionSummaryItem] {
        guard !attentionItems.isEmpty, !repositories.isEmpty else { return [] }

        var repositoriesByID: [UUID: AttentionRepositorySnapshot] = [:]
        repositoriesByID.reserveCapacity(repositories.count)
        var workspacesByID: [UUID: (workspace: AttentionWorkspaceSnapshot, repository: AttentionRepositorySnapshot)] =
            [:]

        for repository in repositories {
            repositoriesByID[repository.id] = repository
            for workspace in repository.workspaces {
                workspacesByID[workspace.id] = (workspace, repository)
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
                    context: "\(resolved.repository.name) tab",
                    detail: presentation.detail,
                    badge: presentation.badge,
                    systemImage: presentation.systemImage,
                    isError: presentation.isError
                )
            case .repo(let id):
                guard let repository = repositoriesByID[id] else { return nil }
                return AttentionSummaryItem(
                    id: item.id,
                    target: item.target,
                    title: repository.name,
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
