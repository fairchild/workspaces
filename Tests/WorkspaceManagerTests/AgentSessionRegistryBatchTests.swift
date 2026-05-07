//
//  AgentSessionRegistryBatchTests.swift
//  WorkspaceManagerTests
//
//  Verifies that `ingestBatch` fires the registry's @Published exactly once per
//  call, regardless of batch size. This is the perf gate for Channel 4 cold-
//  start replay — see `.context/claude-integration/perf-audit-pr443-final.md`.
//

import Combine
import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
@Suite("AgentSessionRegistryBatch")
struct AgentSessionRegistryBatchTests {

    @Test func batchOf100EventsFiresPublisherOnce() async throws {
        let registry = AgentSessionRegistry()
        let host = UUID()
        registry.register(hostSessionID: host, cwd: "/tmp", kind: .claudeCode)

        // Subscribe AFTER registration so we count only batch-driven mutations.
        var fireCount = 0
        let cancellable = registry.$statuses
            .dropFirst()  // CurrentValueSubject fires the initial value on subscribe.
            .sink { _ in fireCount += 1 }

        var batch: [AgentEvent] = []
        for i in 0..<100 {
            batch.append(.toolStart(name: "Tool\(i)", detail: nil))
        }

        registry.ingestBatch(events: batch, for: host, origin: .transcript)

        // Combine on MainActor delivers synchronously for direct sink subscription —
        // a yield is enough to flush.
        await Task.yield()

        #expect(fireCount == 1, "batch must fire @Published exactly once, got \(fireCount)")

        // End-state: last event was `.toolStart(name: "Tool99", ...)`, which the
        // ingest path maps to `.runningTool`.
        let final = registry.statuses[host]
        #expect(final != nil)
        if case .runningTool(let name, _) = final?.run {
            #expect(name == "Tool99")
        } else {
            Issue.record("expected .runningTool for last batch event, got \(String(describing: final?.run))")
        }

        cancellable.cancel()
    }

    @Test func batchEndStateMatchesSequentialIngest() async throws {
        let host = UUID()
        let events: [AgentEvent] = [
            .sessionStart(agentSessionID: "session-abc", cwd: "/tmp/x", kind: .claudeCode),
            .userPrompt(prompt: "hi"),
            .toolStart(name: "Read", detail: "file.swift"),
            .toolEnd(name: "Read", durationMS: 12),
            .stopped(error: nil),
        ]

        let sequential = AgentSessionRegistry()
        sequential.register(hostSessionID: host, cwd: "/tmp", kind: .claudeCode)
        for e in events { sequential.ingest(e, for: host, origin: .transcript) }

        let batched = AgentSessionRegistry()
        batched.register(hostSessionID: host, cwd: "/tmp", kind: .claudeCode)
        batched.ingestBatch(events: events, for: host, origin: .transcript)

        let seqStatus = sequential.statuses[host]
        let batchStatus = batched.statuses[host]
        #expect(seqStatus?.run == batchStatus?.run)
        #expect(seqStatus?.agentSessionID == batchStatus?.agentSessionID)
        #expect(seqStatus?.kind == batchStatus?.kind)
        #expect(seqStatus?.cwd == batchStatus?.cwd)
    }

    @Test func emptyBatchIsNoop() async throws {
        let registry = AgentSessionRegistry()
        let host = UUID()
        registry.register(hostSessionID: host, cwd: "/tmp", kind: .claudeCode)

        var fireCount = 0
        let cancellable = registry.$statuses.dropFirst().sink { _ in fireCount += 1 }

        registry.ingestBatch(events: [], for: host, origin: .transcript)
        await Task.yield()

        #expect(fireCount == 0)
        cancellable.cancel()
    }

    @Test func batchForUnknownSessionIsDropped() async throws {
        let registry = AgentSessionRegistry()
        let unknown = UUID()
        registry.ingestBatch(
            events: [.userPrompt(prompt: "x")],
            for: unknown,
            origin: .transcript
        )
        #expect(registry.statuses.isEmpty)
    }
}
