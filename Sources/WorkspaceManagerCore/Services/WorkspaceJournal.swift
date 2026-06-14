//
//  WorkspaceJournal.swift
//  WorkspaceManagerCore
//
//  Read-side repository over `agent_status_events`, exposing a per-workspace
//  list of `WorkspaceEvent` values ordered newest first. The Detail Pane
//  Timeline observes this; refresh is explicit so views can scope SQL load to the
//  active workspace.
//

import Combine
import Foundation

@MainActor
public final class WorkspaceJournal: ObservableObject {
    /// Per-workspace event lists, newest first.
    @Published public private(set) var events: [UUID: [WorkspaceEvent]] = [:]

    private let store: LocalStateStore?

    public init(store: LocalStateStore?) {
        self.store = store
    }

    /// Fetch the latest events for `workspaceID` keyed off `hostSessionID`,
    /// then publish them newest first. No-op when no backing store is wired.
    public func refresh(
        workspaceID: UUID,
        hostSessionID: UUID,
        limit: Int = 200
    ) async {
        guard let store else { return }
        do {
            let rows = try await store.fetchAgentStatusEvents(
                hostSessionID: hostSessionID,
                limit: limit
            )
            let mapped = Self.map(rows: rows, workspaceID: workspaceID)
            if events[workspaceID] != mapped {
                events[workspaceID] = mapped
            }
        } catch {
            // Read errors are non-fatal for the journal; surface empty rather
            // than crashing the UI.
            if events[workspaceID] != nil {
                events[workspaceID] = []
            }
        }
    }

    public func events(for workspaceID: UUID) -> [WorkspaceEvent] {
        events[workspaceID] ?? []
    }

    /// Pure mapping from rows (any order) to ordered `WorkspaceEvent`s, newest
    /// first. Public for testability; callers should normally go through
    /// `refresh(workspaceID:hostSessionID:limit:)`.
    public nonisolated static func map(
        rows: [AgentStatusEventRow],
        workspaceID: UUID
    ) -> [WorkspaceEvent] {
        let chronological = rows.sorted { lhs, rhs in
            if lhs.eventAt != rhs.eventAt { return lhs.eventAt < rhs.eventAt }
            return lhs.id < rhs.id
        }
        var result: [WorkspaceEvent] = []
        result.reserveCapacity(chronological.count)
        var previousRunState: AgentRunState?
        for row in chronological {
            let runState = Self.parseRunState(row)
            let kind = Self.kind(for: row, runState: runState, previousRunState: previousRunState)
            previousRunState = runState
            result.append(
                WorkspaceEvent(
                    workspaceID: workspaceID,
                    hostSessionID: row.hostSessionID,
                    timestamp: row.eventAt,
                    kind: kind,
                    rowID: row.id
                )
            )
        }
        return result.reversed()
    }

    private nonisolated static func kind(
        for row: AgentStatusEventRow,
        runState: AgentRunState,
        previousRunState: AgentRunState?
    ) -> WorkspaceEvent.Kind {
        switch row.eventName {
        case "session_start":
            return .started
        case "stopped":
            return .completed
        case "errored", "tool_failed":
            let category =
                row.errorCategory.flatMap(AgentErrorCategory.init(rawValue:))
                ?? .unknown
            return .error(category: category, message: row.errorMessage)
        case "tool_start":
            let name = row.toolName ?? "unknown"
            return .toolRun(name: name)
        default:
            return .stateTransition(from: previousRunState, to: runState)
        }
    }

    private nonisolated static func parseRunState(_ row: AgentStatusEventRow) -> AgentRunState {
        switch row.runState {
        case "idle":
            return .idle
        case "thinking":
            return .thinking
        case "running_tool":
            return .runningTool(name: row.toolName ?? "unknown", detail: row.toolDetail)
        case "awaiting_input":
            let reason =
                row.awaitingReason.flatMap(AwaitingReason.init(rawValue:))
                ?? .custom
            return .awaitingInput(reason: reason)
        case "complete":
            return .complete
        case "errored":
            let category =
                row.errorCategory.flatMap(AgentErrorCategory.init(rawValue:))
                ?? .unknown
            return .errored(category: category, message: row.errorMessage)
        default:
            return .idle
        }
    }
}
