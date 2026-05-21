//
//  WorkspaceStatusAggregator.swift
//  WorkspaceManagerCore
//
//  Aggregates per-workspace agent status into bubbled repo state and an
//  attention list, so the UI can render bubbled dots and a project-wide
//  "needs you" pill from a single source of truth.
//

import Combine
import Foundation

@MainActor
public final class WorkspaceStatusAggregator: ObservableObject {
    public struct WorkspaceInput: Equatable, Sendable {
        public let workspaceID: UUID
        public let repoID: UUID?
        public let lastAccessedAt: Date
        public let status: AgentSessionStatus?

        public init(
            workspaceID: UUID,
            repoID: UUID?,
            lastAccessedAt: Date,
            status: AgentSessionStatus?
        ) {
            self.workspaceID = workspaceID
            self.repoID = repoID
            self.lastAccessedAt = lastAccessedAt
            self.status = status
        }
    }

    public struct RepoInput: Equatable, Sendable {
        public let repoID: UUID
        public let lastAccessedAt: Date
        public let status: AgentSessionStatus?

        public init(
            repoID: UUID,
            lastAccessedAt: Date = .distantPast,
            status: AgentSessionStatus?
        ) {
            self.repoID = repoID
            self.lastAccessedAt = lastAccessedAt
            self.status = status
        }
    }

    public enum AttentionTarget: Equatable, Sendable {
        case workspace(UUID)
        case repo(UUID)

        public var workspaceID: UUID? {
            switch self {
            case .workspace(let id): return id
            case .repo: return nil
            }
        }

        public var repoID: UUID? {
            switch self {
            case .workspace: return nil
            case .repo(let id): return id
            }
        }

        fileprivate var stableSortKey: String {
            switch self {
            case .workspace(let id): return "workspace-\(id.uuidString)"
            case .repo(let id): return "repo-\(id.uuidString)"
            }
        }
    }

    private struct AttentionEntry: Equatable {
        let target: AttentionTarget
        let lastAccessedAt: Date
    }

    @Published public private(set) var workspaceStatuses: [UUID: AgentSessionStatus] = [:]
    @Published public private(set) var repoStatuses: [UUID: AgentSessionStatus] = [:]
    /// Repo or workspace targets currently demanding attention, ordered by
    /// `lastAccessedAt` descending.
    @Published public private(set) var attentionTargets: [AttentionTarget] = []
    /// Workspace IDs that currently demand the user's attention, ordered by
    /// `lastAccessedAt` descending.
    @Published public private(set) var attentionWorkspaces: [UUID] = []
    /// Repo-root terminal IDs that currently demand the user's attention, ordered by
    /// `lastAccessedAt` descending.
    @Published public private(set) var attentionRepos: [UUID] = []

    public var attentionCount: Int { attentionTargets.count }

    public init() {}

    public func update(workspaces: [WorkspaceInput], repos: [RepoInput]) {
        var workspaceStatuses: [UUID: AgentSessionStatus] = [:]
        var workspacesByRepo: [UUID: [WorkspaceInput]] = [:]
        for input in workspaces {
            if let status = input.status {
                workspaceStatuses[input.workspaceID] = status
            }
            if let repoID = input.repoID {
                workspacesByRepo[repoID, default: []].append(input)
            }
        }

        var repoStatuses: [UUID: AgentSessionStatus] = [:]
        for repo in repos {
            let candidates: [AgentSessionStatus] =
                [repo.status].compactMap { $0 }
                + (workspacesByRepo[repo.repoID]?.compactMap(\.status) ?? [])
            if let mostSevere = Self.mostSevere(among: candidates) {
                repoStatuses[repo.repoID] = mostSevere
            }
        }

        let workspaceAttention = workspaces.compactMap { input -> AttentionEntry? in
            guard let status = input.status, Self.demandsAttention(status.run) else { return nil }
            return AttentionEntry(
                target: .workspace(input.workspaceID),
                lastAccessedAt: input.lastAccessedAt
            )
        }
        let repoAttention = repos.compactMap { input -> AttentionEntry? in
            guard let status = input.status, Self.demandsAttention(status.run) else { return nil }
            return AttentionEntry(
                target: .repo(input.repoID),
                lastAccessedAt: input.lastAccessedAt
            )
        }
        let attentionTargets =
            (workspaceAttention + repoAttention)
            .sorted { lhs, rhs in
                if lhs.lastAccessedAt != rhs.lastAccessedAt {
                    return lhs.lastAccessedAt > rhs.lastAccessedAt
                }
                return lhs.target.stableSortKey < rhs.target.stableSortKey
            }
            .map(\.target)
        let attentionWorkspaces = attentionTargets.compactMap(\.workspaceID)
        let attentionRepos = attentionTargets.compactMap(\.repoID)

        if self.workspaceStatuses != workspaceStatuses {
            self.workspaceStatuses = workspaceStatuses
        }
        if self.repoStatuses != repoStatuses {
            self.repoStatuses = repoStatuses
        }
        if self.attentionTargets != attentionTargets {
            self.attentionTargets = attentionTargets
        }
        if self.attentionWorkspaces != attentionWorkspaces {
            self.attentionWorkspaces = attentionWorkspaces
        }
        if self.attentionRepos != attentionRepos {
            self.attentionRepos = attentionRepos
        }
    }

    /// Severity ordering — higher number wins when choosing the bubbled state.
    /// Mirrors the visual hierarchy encoded in `SidebarSessionActivity.indicatorColor`
    /// (red > yellow > blue > accent).
    public static func severity(of state: AgentRunState) -> Int {
        switch state {
        case .errored: return 5
        case .awaitingInput: return 4
        case .runningTool: return 3
        case .thinking: return 2
        case .idle, .complete: return 1
        }
    }

    public static func demandsAttention(_ state: AgentRunState) -> Bool {
        switch state {
        case .awaitingInput, .errored: return true
        case .idle, .thinking, .runningTool, .complete: return false
        }
    }

    private static func mostSevere(among statuses: [AgentSessionStatus]) -> AgentSessionStatus? {
        statuses
            .max { lhs, rhs in
                let ls = severity(of: lhs.run)
                let rs = severity(of: rhs.run)
                if ls != rs { return ls < rs }
                return lhs.lastEventAt < rhs.lastEventAt
            }
    }
}
