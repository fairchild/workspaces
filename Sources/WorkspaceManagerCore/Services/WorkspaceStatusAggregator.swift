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
        public let status: AgentSessionStatus?

        public init(repoID: UUID, status: AgentSessionStatus?) {
            self.repoID = repoID
            self.status = status
        }
    }

    @Published public private(set) var workspaceStatuses: [UUID: AgentSessionStatus] = [:]
    @Published public private(set) var repoStatuses: [UUID: AgentSessionStatus] = [:]

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

        if self.workspaceStatuses != workspaceStatuses {
            self.workspaceStatuses = workspaceStatuses
        }
        if self.repoStatuses != repoStatuses {
            self.repoStatuses = repoStatuses
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
