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

    public struct AttentionItem: Identifiable, Equatable, Sendable {
        public let target: AttentionTarget
        public let hostSessionID: UUID
        public let run: AgentRunState
        public let lastEventAt: Date
        public let lastAccessedAt: Date

        public var id: String {
            switch target {
            case .workspace(let id): return "workspace-\(id.uuidString)"
            case .repo(let id): return "repo-\(id.uuidString)"
            }
        }

        public init(
            target: AttentionTarget,
            hostSessionID: UUID,
            run: AgentRunState,
            lastEventAt: Date,
            lastAccessedAt: Date
        ) {
            self.target = target
            self.hostSessionID = hostSessionID
            self.run = run
            self.lastEventAt = lastEventAt
            self.lastAccessedAt = lastAccessedAt
        }
    }

    private struct AttentionEntry: Equatable {
        let target: AttentionTarget
        let status: AgentSessionStatus
        let lastAccessedAt: Date
    }

    @Published public private(set) var workspaceStatuses: [UUID: AgentSessionStatus] = [:]
    @Published public private(set) var repoStatuses: [UUID: AgentSessionStatus] = [:]
    /// Resolved repo or workspace targets currently demanding attention, ordered
    /// attention-first by `SessionActivity.severity`, then `lastAccessedAt` descending.
    @Published public private(set) var attentionItems: [AttentionItem] = []
    /// Repo or workspace targets currently demanding attention, ordered by
    /// `lastAccessedAt` descending.
    @Published public private(set) var attentionTargets: [AttentionTarget] = []
    /// Workspace IDs that currently demand the user's attention, ordered by
    /// `lastAccessedAt` descending.
    @Published public private(set) var attentionWorkspaces: [UUID] = []
    /// Repo-root terminal IDs that currently demand the user's attention, ordered by
    /// `lastAccessedAt` descending.
    @Published public private(set) var attentionRepos: [UUID] = []

    private var acknowledgedAttentionEventAtBySessionID: [UUID: Date] = [:]

    public var attentionCount: Int { attentionItems.count }

    public init() {}

    public func acknowledgeAttention(for status: AgentSessionStatus) {
        guard Self.demandsAttention(status.run) else { return }
        acknowledgedAttentionEventAtBySessionID[status.hostSessionID] = status.lastEventAt
    }

    public func acknowledgeAttention(for target: AttentionTarget) {
        for item in attentionItems where item.target == target {
            acknowledgedAttentionEventAtBySessionID[item.hostSessionID] = item.lastEventAt
        }
    }

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
            guard let status = input.status, shouldShowAttention(for: status) else { return nil }
            return AttentionEntry(
                target: .workspace(input.workspaceID),
                status: status,
                lastAccessedAt: input.lastAccessedAt
            )
        }
        let repoAttention = repos.compactMap { input -> AttentionEntry? in
            guard let status = input.status, shouldShowAttention(for: status) else { return nil }
            return AttentionEntry(
                target: .repo(input.repoID),
                status: status,
                lastAccessedAt: input.lastAccessedAt
            )
        }
        let attentionEntries =
            (workspaceAttention + repoAttention)
            .sorted { lhs, rhs in
                // Attention-first (the shared `SessionActivity` ladder), then recency, then a
                // stable key — so the pill leads with what most needs the user (#680 slice 2).
                let lhsSeverity = SessionActivity.from(lhs.status).severity
                let rhsSeverity = SessionActivity.from(rhs.status).severity
                if lhsSeverity != rhsSeverity {
                    return lhsSeverity > rhsSeverity
                }
                if lhs.lastAccessedAt != rhs.lastAccessedAt {
                    return lhs.lastAccessedAt > rhs.lastAccessedAt
                }
                return lhs.target.stableSortKey < rhs.target.stableSortKey
            }
        let attentionItems = attentionEntries.map { entry in
            AttentionItem(
                target: entry.target,
                hostSessionID: entry.status.hostSessionID,
                run: entry.status.run,
                lastEventAt: entry.status.lastEventAt,
                lastAccessedAt: entry.lastAccessedAt
            )
        }
        let attentionTargets = attentionItems.map(\.target)
        let attentionWorkspaces = attentionTargets.compactMap(\.workspaceID)
        let attentionRepos = attentionTargets.compactMap(\.repoID)

        if self.workspaceStatuses != workspaceStatuses {
            self.workspaceStatuses = workspaceStatuses
        }
        if self.repoStatuses != repoStatuses {
            self.repoStatuses = repoStatuses
        }
        if self.attentionItems != attentionItems {
            self.attentionItems = attentionItems
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

        pruneAcknowledgements(for: Array(workspaceStatuses.values) + Array(repoStatuses.values))
    }

    /// Whether a run state should surface in the attention list. Severity ordering (which
    /// bubbled state wins, and attention-list order) lives on `SessionActivity.severity`.
    public static func demandsAttention(_ state: AgentRunState) -> Bool {
        AgentChromeProjection.demandsAttention(state)
    }

    private static func mostSevere(among statuses: [AgentSessionStatus]) -> AgentSessionStatus? {
        statuses
            .max { lhs, rhs in
                let ls = SessionActivity.from(lhs).severity
                let rs = SessionActivity.from(rhs).severity
                if ls != rs { return ls < rs }
                return lhs.lastEventAt < rhs.lastEventAt
            }
    }

    private func shouldShowAttention(for status: AgentSessionStatus) -> Bool {
        guard Self.demandsAttention(status.run) else { return false }
        guard let acknowledgedAt = acknowledgedAttentionEventAtBySessionID[status.hostSessionID] else {
            return true
        }
        return status.lastEventAt > acknowledgedAt
    }

    private func pruneAcknowledgements(for activeStatuses: some Sequence<AgentSessionStatus>) {
        guard !acknowledgedAttentionEventAtBySessionID.isEmpty else { return }

        for status in activeStatuses {
            guard !Self.demandsAttention(status.run) else { continue }
            acknowledgedAttentionEventAtBySessionID.removeValue(forKey: status.hostSessionID)
        }
    }
}
