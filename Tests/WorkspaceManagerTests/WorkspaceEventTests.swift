// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
//
//  WorkspaceEventTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("WorkspaceEvent")
struct WorkspaceEventTests {
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let hostSessionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func row(
        id: String,
        eventName: String,
        runState: String,
        toolName: String? = nil,
        awaitingReason: String? = nil,
        errorCategory: String? = nil,
        errorMessage: String? = nil,
        at offset: TimeInterval
    ) -> AgentStatusEventRow {
        AgentStatusEventRow(
            id: id,
            hostSessionID: hostSessionID,
            agentSessionID: "agent-1",
            agentKind: "claudeCode",
            origin: "hook",
            originDetail: nil,
            eventName: eventName,
            runState: runState,
            cwd: "/tmp/w",
            toolName: toolName,
            toolDetail: nil,
            awaitingReason: awaitingReason,
            errorCategory: errorCategory,
            errorMessage: errorMessage,
            modelDisplayName: "Claude",
            eventAt: Date(timeIntervalSince1970: 1_700_000_000 + offset)
        )
    }

    @Test("Empty input yields empty output")
    func emptyMapping() {
        let mapped = WorkspaceJournal.map(rows: [], workspaceID: workspaceID)
        #expect(mapped.isEmpty)
    }

    @Test("session_start row maps to .started")
    func sessionStartMaps() {
        let mapped = WorkspaceJournal.map(
            rows: [row(id: "a", eventName: "session_start", runState: "idle", at: 0)],
            workspaceID: workspaceID
        )
        #expect(mapped.count == 1)
        #expect(mapped[0].kind == .started)
        #expect(mapped[0].workspaceID == workspaceID)
        #expect(mapped[0].hostSessionID == hostSessionID)
        #expect(mapped[0].rowID == "a")
    }

    @Test("tool_start row maps to .toolRun with the tool name")
    func toolStartMaps() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(
                    id: "a",
                    eventName: "tool_start",
                    runState: "running_tool",
                    toolName: "Bash",
                    at: 0
                )
            ],
            workspaceID: workspaceID
        )
        #expect(mapped[0].kind == .toolRun(name: "Bash"))
    }

    @Test("errored row maps to .error with category + message")
    func erroredMaps() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(
                    id: "a",
                    eventName: "errored",
                    runState: "errored",
                    errorCategory: "rateLimit",
                    errorMessage: "slow down",
                    at: 0
                )
            ],
            workspaceID: workspaceID
        )
        #expect(mapped[0].kind == .error(category: .rateLimit, message: "slow down"))
    }

    @Test("tool_failed row maps to .error using toolFailure-style category")
    func toolFailedMaps() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(
                    id: "a",
                    eventName: "tool_failed",
                    runState: "thinking",
                    toolName: "Bash",
                    errorCategory: "toolFailure",
                    errorMessage: "exit 1",
                    at: 0
                )
            ],
            workspaceID: workspaceID
        )
        #expect(mapped[0].kind == .error(category: .toolFailure, message: "exit 1"))
    }

    @Test("Unknown error category falls back to .unknown")
    func unknownErrorCategoryFallback() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(
                    id: "a",
                    eventName: "errored",
                    runState: "errored",
                    errorCategory: "what-is-this",
                    errorMessage: nil,
                    at: 0
                )
            ],
            workspaceID: workspaceID
        )
        #expect(mapped[0].kind == .error(category: .unknown, message: nil))
    }

    @Test("stopped row maps to .completed")
    func stoppedMaps() {
        let mapped = WorkspaceJournal.map(
            rows: [row(id: "a", eventName: "stopped", runState: "complete", at: 0)],
            workspaceID: workspaceID
        )
        #expect(mapped[0].kind == .completed)
    }

    @Test("Other rows map to .stateTransition with previous run state")
    func stateTransitionUsesPriorRun() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(id: "a", eventName: "session_start", runState: "idle", at: 0),
                row(
                    id: "b",
                    eventName: "awaiting_input",
                    runState: "awaiting_input",
                    awaitingReason: "permissionPrompt",
                    at: 1
                ),
            ],
            workspaceID: workspaceID
        )
        // Newest first
        #expect(mapped[0].rowID == "b")
        #expect(mapped[1].rowID == "a")
        #expect(mapped[0].kind == .stateTransition(from: .idle, to: .awaitingInput(reason: .permissionPrompt)))
        #expect(mapped[1].kind == .started)
    }

    @Test("First stateTransition has nil from")
    func firstStateTransitionFromIsNil() {
        let mapped = WorkspaceJournal.map(
            rows: [row(id: "a", eventName: "status_fields", runState: "thinking", at: 0)],
            workspaceID: workspaceID
        )
        #expect(mapped[0].kind == .stateTransition(from: nil, to: .thinking))
    }

    @Test("running_tool transitions carry the tool name in the new state")
    func runningToolTransitionCarriesToolName() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(
                    id: "a",
                    eventName: "tool_end",
                    runState: "running_tool",
                    toolName: "Read",
                    at: 0
                )
            ],
            workspaceID: workspaceID
        )
        if case .stateTransition(_, .runningTool(let name, _)) = mapped[0].kind {
            #expect(name == "Read")
        } else {
            Issue.record("expected stateTransition to runningTool, got \(mapped[0].kind)")
        }
    }

    @Test("Events come out newest first regardless of input ordering")
    func newestFirstOrdering() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(id: "newest", eventName: "session_start", runState: "idle", at: 100),
                row(id: "oldest", eventName: "session_start", runState: "idle", at: 0),
                row(id: "middle", eventName: "session_start", runState: "idle", at: 50),
            ],
            workspaceID: workspaceID
        )
        #expect(mapped.map(\.rowID) == ["newest", "middle", "oldest"])
    }

    @Test("Ties on timestamp break by id ascending so ordering is deterministic")
    func tiebreakerByID() {
        let mapped = WorkspaceJournal.map(
            rows: [
                row(id: "b", eventName: "session_start", runState: "idle", at: 0),
                row(id: "a", eventName: "session_start", runState: "idle", at: 0),
            ],
            workspaceID: workspaceID
        )
        // Same timestamp, so we sort chronologically by id ASC then reverse.
        #expect(mapped.map(\.rowID) == ["b", "a"])
    }

    @Test("WorkspaceEvent id matches the row id")
    func identifiableStableAcrossInstances() {
        let event = WorkspaceEvent(
            workspaceID: workspaceID,
            hostSessionID: hostSessionID,
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .started,
            rowID: "row-1"
        )
        #expect(event.id == "row-1")
    }
}
