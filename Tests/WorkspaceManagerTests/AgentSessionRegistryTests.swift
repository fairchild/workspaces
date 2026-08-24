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
    private func apply(
        _ event: AgentEvent,
        to registry: AgentSessionRegistry,
        hostSessionID: UUID,
        origin: AgentEventOrigin
    ) {
        registry.apply(events: [event], for: hostSessionID, origin: origin)
    }

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

    @Test("Happy path drives the full state machine through apply(events:)")
    func happyPath() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/work", kind: .claudeCode)

        registry.apply(
            events: [
                .sessionStart(agentSessionID: "s-1", cwd: "/tmp/work", kind: .claudeCode),
                .userPrompt(prompt: "hi"),
                .toolStart(name: "Read", detail: "file.swift"),
            ],
            for: id,
            origin: .hook
        )

        #expect(registry.statuses[id]?.agentSessionID == "s-1")
        #expect(registry.statuses[id]?.hookActive == true)
        if case .runningTool(let name, let detail) = registry.statuses[id]?.run {
            #expect(name == "Read")
            #expect(detail == "file.swift")
        } else {
            Issue.record("expected runningTool")
        }

        registry.apply(
            events: [
                .toolEnd(name: "Read", durationMS: 5),
                .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
                .stopped(error: nil),
            ],
            for: id,
            origin: .hook
        )
        #expect(registry.statuses[id]?.run == .complete)
    }

    @Test("Failure events map to errored states")
    func failureMapping() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/x", kind: .claudeCode)

        apply(
            .toolFailed(name: "Bash", error: "permission denied"),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        if case .errored(let category, let message) = registry.statuses[id]?.run {
            #expect(category == .toolFailure)
            #expect(message == "permission denied")
        } else {
            Issue.record("expected toolFailure")
        }

        apply(.stopped(error: "rate limited"), to: registry, hostSessionID: id, origin: .hook)
        if case .errored(let category, let msg) = registry.statuses[id]?.run {
            #expect(category == .unknown)
            #expect(msg == "rate limited")
        } else {
            Issue.record("expected stopped error")
        }
    }

    @Test("OSC dedup suppresses event when hook recently produced same state")
    func oscDedupSuppression() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/dedup", kind: .claudeCode)
        apply(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/dedup", kind: .claudeCode),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        apply(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        let runAfterHook = registry.statuses[id]?.run

        clock.advance(by: 0.2)
        apply(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            to: registry,
            hostSessionID: id,
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
        apply(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/fall", kind: .claudeCode),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        apply(.toolStart(name: "Read", detail: nil), to: registry, hostSessionID: id, origin: .hook)

        clock.advance(by: 1.0)
        apply(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            to: registry,
            hostSessionID: id,
            origin: .osc(surfaceID: nil)
        )
        if case .awaitingInput(.permissionPrompt) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record("expected OSC to override after dedup window")
        }
    }

    @Test("Clearing hookActive lets OSC events apply again")
    func hookActiveClearAllowsOSC() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/clear", kind: .claudeCode)
        apply(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/clear", kind: .claudeCode),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        apply(.userPrompt(prompt: nil), to: registry, hostSessionID: id, origin: .hook)

        registry.clearHookActive(for: id)
        #expect(registry.statuses[id]?.hookActive == false)

        apply(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            to: registry,
            hostSessionID: id,
            origin: .osc(surfaceID: nil)
        )
        if case .awaitingInput(.permissionPrompt) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record("expected OSC to apply after hook-active clear")
        }
    }

    @Test("statusFields merge without changing run")
    func statusFieldsMergePreservesRun() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/sf", kind: .claudeCode)
        apply(.userPrompt(prompt: nil), to: registry, hostSessionID: id, origin: .hook)
        let run = registry.statuses[id]?.run

        apply(
            .statusFields(.init(modelDisplayName: "claude-opus", costUSD: 0.42)),
            to: registry,
            hostSessionID: id,
            origin: .statusLine
        )
        #expect(registry.statuses[id]?.modelDisplayName == "claude-opus")
        #expect(registry.statuses[id]?.costUSD == 0.42)
        #expect(registry.statuses[id]?.run == run)
    }

    @Test("Bell is a no-op and workingDirectory updates cwd")
    func bellAndWorkingDirectory() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/old", kind: .claudeCode)
        apply(.userPrompt(prompt: nil), to: registry, hostSessionID: id, origin: .hook)
        let runBefore = registry.statuses[id]?.run

        apply(.bell, to: registry, hostSessionID: id, origin: .bell)
        #expect(registry.statuses[id]?.run == runBefore)

        apply(.workingDirectory("/tmp/new"), to: registry, hostSessionID: id, origin: .hook)
        #expect(registry.statuses[id]?.cwd == "/tmp/new")
    }

    @Test("stale hook-expiration generation cannot clear a successor registration")
    func staleExpirationGenerationNoOps() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/aba", kind: .claudeCode)
        registry.apply(events: [.userPrompt(prompt: nil)], for: id, origin: .hook)
        #expect(registry.statuses[id]?.hookActive == true)

        // Deregister and re-register the same UUID — the ABA shape a watchdog
        // task can outlive.
        registry.deregister(hostSessionID: id)
        registry.register(hostSessionID: id, cwd: "/tmp/aba", kind: .claudeCode)
        registry.apply(events: [.userPrompt(prompt: nil)], for: id, origin: .hook)
        #expect(registry.statuses[id]?.hookActive == true)

        // The first registration's watchdog carried generation 1; firing it
        // now must not touch the successor.
        registry.expireHookActivity(for: id, generation: 1)
        #expect(registry.statuses[id]?.hookActive == true)

        // The live generation (2) still expires normally.
        registry.expireHookActivity(for: id, generation: 2)
        #expect(registry.statuses[id]?.hookActive == false)
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
