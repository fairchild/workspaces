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
    private func apply(
        _ event: AgentEvent,
        to registry: AgentSessionRegistry,
        hostSessionID: UUID,
        origin: AgentEventOrigin
    ) {
        registry.apply(events: [event], for: hostSessionID, origin: origin)
    }

    @Test("Hook then OSC within 750ms: OSC suppressed")
    func hookThenOscWithinWindow() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/dedup-int", kind: .claudeCode)

        apply(
            .sessionStart(agentSessionID: "session-A", cwd: "/tmp/dedup-int", kind: .claudeCode),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        apply(
            .awaitingInput(reason: .permissionPrompt, title: "perm", message: "msg"),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        let runAfterHook = registry.statuses[id]?.run

        let oscEvent = AgentOSCEventMapper.mapNotification(
            kind: .claudeCode,
            title: "perm",
            body: "permission requested"
        )

        clock.advance(by: 0.300)
        apply(oscEvent, to: registry, hostSessionID: id, origin: .osc(surfaceID: 0xDEAD_BEEF))
        #expect(registry.statuses[id]?.run == runAfterHook)
    }

    @Test("Hook then OSC after 1s: OSC applies")
    func hookThenOscAfterWindow() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/dedup-after", kind: .claudeCode)
        apply(
            .sessionStart(agentSessionID: "session-B", cwd: "/tmp/dedup-after", kind: .claudeCode),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )
        apply(.toolStart(name: "Read", detail: nil), to: registry, hostSessionID: id, origin: .hook)

        clock.advance(by: 1.0)
        let oscEvent = AgentOSCEventMapper.mapNotification(
            kind: .claudeCode,
            title: "permission",
            body: "Tool needs permission"
        )
        apply(oscEvent, to: registry, hostSessionID: id, origin: .osc(surfaceID: 0xCAFE))

        if case .awaitingInput(.permissionPrompt) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record(
                "expected OSC permissionPrompt to override after dedup window; got \(String(describing: registry.statuses[id]?.run))"
            )
        }
    }

    @Test("Generic OSC mapping routes via the registry")
    func genericOSCApplies() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/opencode", kind: .opencode)
        let event = AgentOSCEventMapper.mapNotification(
            kind: .opencode,
            title: "ready",
            body: "agent finished"
        )
        apply(event, to: registry, hostSessionID: id, origin: .osc(surfaceID: nil))

        if case .awaitingInput(.custom) = registry.statuses[id]?.run {
            // ok
        } else {
            Issue.record("expected generic OSC to map to custom awaitingInput")
        }
    }

    @Test("OSC dedup uses .osc origin")
    func dedupSpecificToOSCOrigin() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = AgentSessionRegistry(clock: clock.now)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/origin", kind: .claudeCode)
        apply(
            .sessionStart(agentSessionID: "s", cwd: "/tmp/origin", kind: .claudeCode),
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

        clock.advance(by: 0.150)
        let lastEventBefore = registry.statuses[id]?.lastEventAt
        apply(
            .awaitingInput(reason: .permissionPrompt, title: nil, message: nil),
            to: registry,
            hostSessionID: id,
            origin: .hook
        )

        #expect(registry.statuses[id]?.lastEventAt != lastEventBefore)
    }
}
