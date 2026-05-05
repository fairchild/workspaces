//
//  AgentSessionRegistryTests.swift
//  WorkspaceManagerTests
//
//  Pure state-machine tests for the AgentSessionRegistry. No I/O.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
@Suite("AgentSessionRegistry")
struct AgentSessionRegistryTests {

    @Test("Registers a host session with cwd and kind")
    func registersSession() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/foo", kind: .claudeCode)

        let status = registry.statuses[id]
        #expect(status != nil)
        #expect(status?.kind == .claudeCode)
        #expect(status?.run == .idle)
        #expect(status?.hookActive == false)
    }

    @Test("Happy path drives the full state machine")
    func happyPath() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/work", kind: .claudeCode)

        registry.ingest(
            .sessionStart(agentSessionID: "s-1", cwd: "/tmp/work", kind: .claudeCode),
            for: id,
            origin: .hook
        )
        #expect(registry.statuses[id]?.agentSessionID == "s-1")
        #expect(registry.statuses[id]?.hookActive == true)
        #expect(registry.statuses[id]?.run == .idle)

        registry.ingest(.userPrompt(prompt: "hi"), for: id, origin: .hook)
        #expect(registry.statuses[id]?.run == .thinking)

        registry.ingest(.toolStart(name: "Read", detail: "file.swift"), for: id, origin: .hook)
        if case .runningTool(let name, let detail) = registry.statuses[id]?.run {
            #expect(name == "Read")
            #expect(detail == "file.swift")
        } else {
            Issue.record("expected runningTool")
        }

        registry.ingest(.toolEnd(name: "Read", durationMS: 5), for: id, origin: .hook)
        #expect(registry.statuses[id]?.run == .thinking)

        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            for: id,
            origin: .hook
        )
        if case .awaitingInput(.permissionPrompt) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record("expected awaitingInput(.permissionPrompt)")
        }

        registry.ingest(.stopped(error: nil), for: id, origin: .hook)
        #expect(registry.statuses[id]?.run == .complete)
    }

    @Test("Tool failure routes to errored(toolFailure)")
    func toolFailureMapping() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/x", kind: .claudeCode)
        registry.ingest(.toolFailed(name: "Bash", error: "permission denied"), for: id, origin: .hook)
        if case .errored(let category, let message) = registry.statuses[id]?.run {
            #expect(category == .toolFailure)
            #expect(message == "permission denied")
        } else {
            Issue.record("expected errored")
        }
    }

    @Test("Stop with error → errored(unknown)")
    func stopWithError() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/x", kind: .claudeCode)
        registry.ingest(.stopped(error: "rate limited"), for: id, origin: .hook)
        if case .errored(let category, let msg) = registry.statuses[id]?.run {
            #expect(category == .unknown)
            #expect(msg == "rate limited")
        } else {
            Issue.record("expected errored")
        }
    }

    @Test("OSC dedup suppresses event when hook recently produced same state")
    func oscDedupSuppression() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/dedup", kind: .claudeCode)
        registry.ingest(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/dedup", kind: .claudeCode),
            for: id,
            origin: .hook
        )

        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            for: id,
            origin: .hook
        )
        let runAfterHook = registry.statuses[id]?.run

        // Advance 200ms; OSC event with same effective state should be suppressed.
        clock.advance(by: 0.2)
        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            for: id,
            origin: .osc(surfaceID: nil)
        )
        #expect(registry.statuses[id]?.run == runAfterHook)
    }

    @Test("OSC fall-through past dedup window applies the OSC state")
    func oscFallThroughAfterWindow() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/fall", kind: .claudeCode)
        registry.ingest(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/fall", kind: .claudeCode),
            for: id,
            origin: .hook
        )
        registry.ingest(.toolStart(name: "Read", detail: nil), for: id, origin: .hook)

        // Advance past the 750ms dedup window.
        clock.advance(by: 1.0)
        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            for: id,
            origin: .osc(surfaceID: nil)
        )
        if case .awaitingInput(.permissionPrompt) = registry.statuses[id]?.run {
            // ok — OSC fell through
        } else {
            Issue.record("expected OSC to override after dedup window")
        }
    }

    @Test("OSC applies normally when hookActive is false")
    func oscNoHookActive() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/no-hook", kind: .claudeCode)
        registry.ingest(
            .awaitingInput(reason: .idlePrompt, title: nil, message: nil),
            for: id,
            origin: .osc(surfaceID: nil)
        )
        if case .awaitingInput(.idlePrompt) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record("expected awaitingInput(.idlePrompt)")
        }
    }

    @Test("Clearing hookActive lets OSC events apply again")
    func hookActiveClearAllowsOSC() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/clear", kind: .claudeCode)
        registry.ingest(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/clear", kind: .claudeCode),
            for: id,
            origin: .hook
        )
        registry.ingest(.userPrompt(prompt: nil), for: id, origin: .hook)

        // Manually clear the flag (simulates 60s watchdog firing).
        registry.clearHookActive(for: id)
        #expect(registry.statuses[id]?.hookActive == false)

        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            for: id,
            origin: .osc(surfaceID: nil)
        )
        if case .awaitingInput(.permissionPrompt) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record("expected OSC to apply after hook-active clear")
        }
    }

    @Test("statusFields merges without changing run")
    func statusFieldsMergePreservesRun() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/sf", kind: .claudeCode)
        registry.ingest(.userPrompt(prompt: nil), for: id, origin: .hook)
        let run = registry.statuses[id]?.run
        registry.ingest(
            .statusFields(.init(modelDisplayName: "claude-opus", costUSD: 0.42)),
            for: id,
            origin: .statusLine
        )
        #expect(registry.statuses[id]?.modelDisplayName == "claude-opus")
        #expect(registry.statuses[id]?.costUSD == 0.42)
        #expect(registry.statuses[id]?.run == run)
    }

    @Test("Bell is a no-op for v1")
    func bellNoOp() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/b", kind: .claudeCode)
        registry.ingest(.userPrompt(prompt: nil), for: id, origin: .hook)
        let runBefore = registry.statuses[id]?.run
        registry.ingest(.bell, for: id, origin: .bell)
        #expect(registry.statuses[id]?.run == runBefore)
    }

    @Test("workingDirectory updates cwd")
    func workingDirectoryUpdatesCWD() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/old", kind: .claudeCode)
        registry.ingest(.workingDirectory("/tmp/new"), for: id, origin: .hook)
        #expect(registry.statuses[id]?.cwd == "/tmp/new")
    }

    @Test("resolveHostSession is agentSessionID-first, with cwd as SessionStart fallback")
    func resolveHostSession() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/resolve", kind: .claudeCode)

        // Before any binding: cwd matches an unbound entry → returns it.
        let preBindByCwd = registry.resolveHostSession(cwd: "/tmp/resolve", agentSessionID: nil)
        #expect(preBindByCwd == id)

        registry.ingest(
            .sessionStart(agentSessionID: "agent-x", cwd: "/tmp/resolve", kind: .claudeCode),
            for: id,
            origin: .hook
        )

        // After binding: agentSessionID is the canonical key.
        let byAgentID = registry.resolveHostSession(cwd: "/elsewhere", agentSessionID: "agent-x")
        #expect(byAgentID == id)

        // After binding: a cwd-only lookup (no agentSessionID) no longer matches the
        // bound entry — the binding takes it out of the unbound-candidate pool. This
        // is the defect 2 contract: cwd is only a SessionStart fallback, not a
        // routing key for events that already carry a session_id.
        let cwdOnlyAfterBind = registry.resolveHostSession(cwd: "/tmp/resolve", agentSessionID: nil)
        #expect(cwdOnlyAfterBind == nil)

        let miss = registry.resolveHostSession(cwd: "/none", agentSessionID: nil)
        #expect(miss == nil)
    }

    @Test("deregister removes a session entry")
    func deregisterRemoves() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/x", kind: .claudeCode)
        registry.deregister(hostSessionID: id)
        #expect(registry.statuses[id] == nil)
    }
}
