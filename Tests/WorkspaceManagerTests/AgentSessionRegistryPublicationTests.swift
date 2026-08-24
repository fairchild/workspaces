//
//  AgentSessionRegistryPublicationTests.swift
//  WorkspaceManagerTests
//
//  Publication-scoping contract for #1347: per-event truth updates must not
//  publish unless render-relevant state changed, and observation registered
//  via `observedStatus(for:)` must invalidate exactly on those changes.
//

import Combine
import Foundation
import Observation
import Testing

@testable import WorkspaceManagerCore

@MainActor
@Suite("AgentSessionRegistryPublication")
struct AgentSessionRegistryPublicationTests {

    private func makeRegistry(clock: TestClock) -> AgentSessionRegistry {
        AgentSessionRegistry(clock: clock.now)
    }

    @Test("register and deregister fire the change signal")
    func registerDeregisterSignal() async {
        let registry = AgentSessionRegistry()
        var signals = 0
        let cancellable = registry.statusesDidChange.sink { signals += 1 }
        defer { cancellable.cancel() }

        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/a", kind: .claudeCode)
        #expect(signals == 1)
        registry.deregister(hostSessionID: id)
        #expect(signals == 2)
    }

    @Test("no-op events advance truth lastEventAt without publishing")
    func noOpEventsDoNotPublish() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let registry = makeRegistry(clock: clock)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/noop", kind: .claudeCode)

        var signals = 0
        let cancellable = registry.statusesDidChange.sink { signals += 1 }
        defer { cancellable.cancel() }

        registry.apply(events: [.userPrompt(prompt: nil)], for: id, origin: .hook)
        #expect(signals == 1)
        let lastEventAtAfterPrompt = registry.status(for: id)?.lastEventAt

        // toolEnd settles on .thinking, which the session already is: truth
        // moves (lastEventAt, hook bookkeeping), publication must not.
        clock.advance(by: 5)
        registry.apply(events: [.toolEnd(name: "Read", durationMS: 3)], for: id, origin: .hook)
        #expect(signals == 1)
        #expect(registry.status(for: id)?.run == .thinking)
        #expect(registry.status(for: id)?.lastEventAt != lastEventAtAfterPrompt)
    }

    @Test("a batch collapses to at most one publication")
    func batchPublishesOnce() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/batch", kind: .claudeCode)

        var signals = 0
        let cancellable = registry.statusesDidChange.sink { signals += 1 }
        defer { cancellable.cancel() }

        registry.apply(
            events: [
                .userPrompt(prompt: nil),
                .toolStart(name: "Read", detail: "a.swift"),
                .toolEnd(name: "Read", durationMS: 2),
                .toolStart(name: "Edit", detail: "b.swift"),
            ],
            for: id,
            origin: .hook
        )
        #expect(signals == 1)
        if case .runningTool(let name, _) = registry.observedStatus(for: id)?.run {
            #expect(name == "Edit")
        } else {
            Issue.record("expected runningTool(Edit)")
        }
    }

    @Test("unchanged status-line tick does not publish; a changed one does")
    func statusFieldsGating() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/sl", kind: .claudeCode)

        var signals = 0
        let cancellable = registry.statusesDidChange.sink { signals += 1 }
        defer { cancellable.cancel() }

        let fields = AgentEvent.StatusFields(modelDisplayName: "claude-opus", costUSD: 0.42)
        registry.apply(events: [.statusFields(fields)], for: id, origin: .statusLine)
        #expect(signals == 1)

        registry.apply(events: [.statusFields(fields)], for: id, origin: .statusLine)
        #expect(signals == 1)

        let changed = AgentEvent.StatusFields(modelDisplayName: "claude-opus", costUSD: 0.43)
        registry.apply(events: [.statusFields(changed)], for: id, origin: .statusLine)
        #expect(signals == 2)
    }

    @Test("observedStatus registers observation that fires only on render change")
    func observedStatusObservation() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/obs", kind: .claudeCode)
        registry.apply(events: [.userPrompt(prompt: nil)], for: id, origin: .hook)

        let fired = PublicationLockedFlag()
        withObservationTracking {
            _ = registry.observedStatus(for: id)
        } onChange: {
            fired.set()
        }

        // No-op: thinking → thinking. Must not invalidate.
        registry.apply(events: [.toolEnd(name: "Read", durationMS: 1)], for: id, origin: .hook)
        #expect(fired.value == false)

        // Render change: thinking → runningTool. Must invalidate.
        registry.apply(events: [.toolStart(name: "Bash", detail: nil)], for: id, origin: .hook)
        #expect(fired.value == true)
    }

    @Test("hookActive expiry mutates truth without publishing")
    func hookActiveExpiryDoesNotPublish() async {
        let registry = AgentSessionRegistry()
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/exp", kind: .claudeCode)
        registry.apply(events: [.userPrompt(prompt: nil)], for: id, origin: .hook)

        var signals = 0
        let cancellable = registry.statusesDidChange.sink { signals += 1 }
        defer { cancellable.cancel() }

        registry.clearHookActive(for: id)
        #expect(signals == 0)
        #expect(registry.status(for: id)?.hookActive == false)
    }

    @Test("repeated identical attention events still publish, refreshing render lastEventAt")
    func repeatedAttentionEventsPublish() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let registry = makeRegistry(clock: clock)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/attn", kind: .claudeCode)

        var signals = 0
        let cancellable = registry.statusesDidChange.sink { signals += 1 }
        defer { cancellable.cancel() }

        registry.apply(
            events: [.awaitingInput(reason: .permissionPrompt, title: nil, message: nil)],
            for: id, origin: .hook)
        #expect(signals == 1)
        let firstRenderTimestamp = registry.renderStatuses[id]?.lastEventAt

        // Identical repeat: run state unchanged, but acknowledged attention UI
        // compares event timestamps, so the fresh lastEventAt must publish.
        clock.advance(by: 45)
        registry.apply(
            events: [.awaitingInput(reason: .permissionPrompt, title: nil, message: nil)],
            for: id, origin: .hook)
        #expect(signals == 2)
        #expect(registry.renderStatuses[id]?.lastEventAt != firstRenderTimestamp)
    }

    @Test("observedStatus carries live truth bookkeeping fields")
    func observedStatusCarriesTruth() async {
        let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
        let registry = makeRegistry(clock: clock)
        let id = UUID()
        registry.register(hostSessionID: id, cwd: "/tmp/truth", kind: .claudeCode)
        registry.apply(events: [.userPrompt(prompt: nil)], for: id, origin: .hook)

        clock.advance(by: 30)
        registry.apply(events: [.toolEnd(name: "Read", durationMS: 1)], for: id, origin: .hook)

        // The no-op apply moved truth lastEventAt; a fresh observed read must
        // reflect it even though nothing published.
        #expect(registry.observedStatus(for: id)?.lastEventAt == registry.status(for: id)?.lastEventAt)
    }
}

/// Tiny synchronization shim: `withObservationTracking`'s onChange is
/// @Sendable, so the flag it flips has to be safe to touch off-actor.
private final class PublicationLockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
