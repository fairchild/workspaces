//
//  StatusLinePayloadTests.swift
//  WorkspaceManagerTests
//
//  Decoder behaviour for the Channel 2 wire format. The decoder must be tolerant
//  — unknown keys and missing fields are silent; only a non-object body returns
//  nil. This keeps the host robust to schema additions in Claude Code.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("StatusLinePayload")
struct StatusLinePayloadTests {

    @Test("Canonical payload decodes every documented field")
    func canonicalDecode() throws {
        let json = """
            {
              "version": "1.2.80",
              "session_id": "abc-123",
              "model": { "id": "claude-sonnet", "display_name": "Claude Sonnet 4.5" },
              "workspace": {
                "current_dir": "/Users/m/code/repo",
                "project_dir": "/Users/m/code/repo",
                "git_worktree": "/Users/m/code/repo"
              },
              "cost": {
                "total_cost_usd": 0.42,
                "total_lines_added": 12,
                "total_lines_removed": 3
              },
              "context_window": {
                "used_percentage": 37.5,
                "context_window_size": 200000
              },
              "rate_limits": {
                "five_hour": {
                  "used_percentage": 14.2,
                  "resets_at": "2026-05-07T18:00:00Z"
                }
              },
              "output_style": { "name": "default" }
            }
            """
        let payload = try #require(StatusLinePayload.decode(from: Data(json.utf8)))
        #expect(payload.version == "1.2.80")
        #expect(payload.agentSessionID == "abc-123")
        #expect(payload.model?.id == "claude-sonnet")
        #expect(payload.model?.displayName == "Claude Sonnet 4.5")
        #expect(payload.workspace?.currentDir == "/Users/m/code/repo")
        #expect(payload.workspace?.gitWorktree == "/Users/m/code/repo")
        #expect(payload.cost?.totalCostUSD == 0.42)
        #expect(payload.cost?.totalLinesAdded == 12)
        #expect(payload.contextWindow?.usedPercentage == 37.5)
        #expect(payload.contextWindow?.contextWindowSize == 200000)
        #expect(payload.rateLimits?.fiveHour?.usedPercentage == 14.2)
        #expect(payload.rateLimits?.fiveHour?.resetsAt != nil)
        #expect(payload.outputStyle?.name == "default")

        let fields = payload.toStatusFields()
        #expect(fields.modelDisplayName == "Claude Sonnet 4.5")
        #expect(fields.contextUsedPercent == 37.5)
        #expect(fields.fiveHourLimitUsedPercent == 14.2)
        #expect(fields.costUSD == 0.42)
        #expect(fields.fiveHourLimitResetsAt != nil)

        #expect(payload.resolvedCwd() == "/Users/m/code/repo")
    }

    @Test("Unknown fields are ignored, missing fields decode to nil")
    func tolerantDecode() throws {
        let json = """
            {
              "model": { "display_name": "Sonnet" },
              "workspace": { "current_dir": "/tmp/x" },
              "future_field": { "anything": [1, 2, 3] },
              "extra_top_level": "ignored"
            }
            """
        let payload = try #require(StatusLinePayload.decode(from: Data(json.utf8)))
        #expect(payload.model?.displayName == "Sonnet")
        #expect(payload.workspace?.currentDir == "/tmp/x")
        #expect(payload.cost == nil)
        #expect(payload.contextWindow == nil)
        #expect(payload.rateLimits == nil)
    }

    @Test("Non-object JSON returns nil")
    func rejectNonObject() {
        #expect(StatusLinePayload.decode(from: Data("[1, 2, 3]".utf8)) == nil)
        #expect(StatusLinePayload.decode(from: Data("\"a string\"".utf8)) == nil)
        #expect(StatusLinePayload.decode(from: Data("not json".utf8)) == nil)
    }

    @Test("Type-mismatched scalars are coerced where possible, dropped where not")
    func tolerantScalarCoercion() throws {
        // Integer encoded as a JSON number — coerce to Double.
        // Percentage encoded as a string — coerce.
        // Cost encoded as a string-of-number — coerce.
        let json = """
            {
              "context_window": { "used_percentage": "42" },
              "cost": { "total_cost_usd": "0.123" },
              "rate_limits": {
                "five_hour": { "used_percentage": 88, "resets_at": 1746640800 }
              }
            }
            """
        let payload = try #require(StatusLinePayload.decode(from: Data(json.utf8)))
        #expect(payload.contextWindow?.usedPercentage == 42.0)
        #expect(payload.cost?.totalCostUSD == 0.123)
        #expect(payload.rateLimits?.fiveHour?.usedPercentage == 88.0)
        #expect(payload.rateLimits?.fiveHour?.resetsAt != nil)
    }

    @Test("Workspace.current_dir wins over top-level cwd for resolution")
    func workspaceCurrentDirWins() throws {
        let json = """
            {
              "cwd": "/old",
              "workspace": { "current_dir": "/new" }
            }
            """
        let payload = try #require(StatusLinePayload.decode(from: Data(json.utf8)))
        #expect(payload.resolvedCwd() == "/new")
    }

    @Test("Empty payload decodes to all-nil with no crash")
    func emptyObject() throws {
        let payload = try #require(StatusLinePayload.decode(from: Data("{}".utf8)))
        #expect(payload.cwd == nil)
        #expect(payload.model == nil)
        #expect(payload.toStatusFields() == AgentEvent.StatusFields())
        #expect(payload.resolvedCwd() == nil)
    }

    @Test("Fractional-second ISO dates parse")
    func fractionalSecondDate() throws {
        let json = """
            {
              "rate_limits": {
                "five_hour": { "resets_at": "2026-05-07T18:00:00.123Z" }
              }
            }
            """
        let payload = try #require(StatusLinePayload.decode(from: Data(json.utf8)))
        #expect(payload.rateLimits?.fiveHour?.resetsAt != nil)
    }
}
