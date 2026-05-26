//
//  WorkspaceEvent.swift
//  WorkspaceManagerCore
//
//  Value-type domain model over rows in the SQLite `agent_status_events`
//  table. The Timeline inspector consumes these via `WorkspaceJournal`; the
//  shape collapses the storage event_name / run_state pair into a small set
//  of cases keyed for display.
//
//  New cases must be additive — never rename or repurpose without a
//  migration. Mapping from raw rows lives in `WorkspaceJournal.map(rows:)`.
//

import Foundation

public struct WorkspaceEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case started
        case stateTransition(from: AgentRunState?, to: AgentRunState)
        case toolRun(name: String)
        case error(category: AgentErrorCategory, message: String?)
        case completed
    }

    public let workspaceID: UUID
    public let hostSessionID: UUID
    public let timestamp: Date
    public let kind: Kind
    /// Stable identifier for the underlying `agent_status_events` row.
    public let rowID: String

    public init(
        workspaceID: UUID,
        hostSessionID: UUID,
        timestamp: Date,
        kind: Kind,
        rowID: String
    ) {
        self.workspaceID = workspaceID
        self.hostSessionID = hostSessionID
        self.timestamp = timestamp
        self.kind = kind
        self.rowID = rowID
    }

    public var id: String { rowID }
}
