//
//  OSCDedupIntegrationTests.swift
//  WorkspaceManagerTests
//
//  Channel 3 dedup: when a hook event has been applied recently, an OSC event
//  with the same effective state is suppressed; once the 750ms window elapses
//  the OSC event applies.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
@Suite("Channel 3 OSC dedup integration")
struct OSCDedupIntegrationTests {

    @Test("Hook then OSC within 750ms: OSC suppressed")
    func hookThenOscWithinWindow() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/dedup-int", kind: .claudeCode)

        // Hook: SessionStart binds the agent id and sets hookActive=true.
        registry.ingest(
            .sessionStart(agentSessionID: "session-A", cwd: "/tmp/dedup-int", kind: .claudeCode),
            for: id,
            origin: .hook
        )
        // Hook fires permission prompt. Registry caches lastHookRunStateApplied.
        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: "perm", message: "msg"),
            for: id,
            origin: .hook
        )
        let runAfterHook = registry.statuses[id]?.run

        // Adapter maps the OSC payload identically.
        let adapter = AgentAdapterRegistry().adapter(for: .claudeCode)
        let oscEvent = adapter.mapOSCNotification(title: "perm", body: "permission requested")

        // Within 750ms: OSC suppressed, run state unchanged.
        clock.advance(by: 0.300)
        registry.ingest(oscEvent, for: id, origin: .osc(surfaceID: 0xDEAD_BEEF))
        #expect(registry.statuses[id]?.run == runAfterHook)
    }

    @Test("Hook then OSC after 1s: OSC applies (window elapsed)")
    func hookThenOscAfterWindow() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/dedup-after", kind: .claudeCode)
        registry.ingest(
            .sessionStart(agentSessionID: "session-B", cwd: "/tmp/dedup-after", kind: .claudeCode),
            for: id,
            origin: .hook
        )
        // Hook drives a tool — registry remembers lastHookRunStateApplied=runningTool.
        registry.ingest(.toolStart(name: "Read", detail: nil), for: id, origin: .hook)

        // Wait past the window. OSC `awaitingInput` differs from runningTool, but
        // even if it didn't, the timestamp branch should let it through.
        clock.advance(by: 1.0)
        let adapter = AgentAdapterRegistry().adapter(for: .claudeCode)
        let oscEvent = adapter.mapOSCNotification(
            title: "permission",
            body: "Tool needs permission"
        )
        registry.ingest(oscEvent, for: id, origin: .osc(surfaceID: 0xCAFE))

        if case .awaitingInput(.permissionPrompt) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record(
                "expected OSC permissionPrompt to override after dedup window; got \(String(describing: registry.statuses[id]?.run))"
            )
        }
    }

    @Test("Generic adapter OSC also routes via the registry")
    func genericAdapterOSCApplies() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/opencode", kind: .opencode)
        let adapter = AgentAdapterRegistry().adapter(for: .opencode)
        let event = adapter.mapOSCNotification(title: "ready", body: "agent finished")
        registry.ingest(event, for: id, origin: .osc(surfaceID: nil))

        if case .awaitingInput(.custom) = registry.statuses[id]?.run {
            // ok — generic adapter maps everything to custom awaiting input
        } else {
            Issue.record("expected generic adapter to map OSC to custom awaitingInput")
        }
    }

    @Test("OSC dedup uses .osc origin (hook origin still applies even within window)")
    func dedupSpecificToOSCOrigin() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/origin", kind: .claudeCode)
        registry.ingest(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/origin", kind: .claudeCode),
            for: id,
            origin: .hook
        )
        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            for: id,
            origin: .hook
        )
        clock.advance(by: 0.100)
        // A second *hook* event with identical state still applies (timestamp updates).
        let lastEventBefore = registry.statuses[id]?.lastEventAt
        clock.advance(by: 0.050)
        registry.ingest(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            for: id,
            origin: .hook
        )
        // The hook-vs-hook path is not deduped — it just refreshes lastEventAt.
        #expect(registry.statuses[id]?.lastEventAt != lastEventBefore)
    }
}
