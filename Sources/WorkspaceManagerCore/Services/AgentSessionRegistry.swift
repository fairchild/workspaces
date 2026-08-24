//
//  AgentSessionRegistry.swift
//  WorkspaceManagerCore
//
//  Live registry of agent session statuses keyed by host session ID. Consumes
//  AgentEvent values from hook, status-line, and terminal attention inputs,
//  then produces a normalized AgentRunState for the UI. Publication is scoped:
//  each session owns an @Observable render model that updates only when
//  render-relevant state changes, so one event invalidates one row, not the
//  whole window (#1347).
//

import Combine
import Foundation
import Observation

/// Per-session observable render state. Views register Observation-tracked
/// dependencies by reading ``status`` inside `body`; the registry writes it
/// only when render-relevant fields change (`lastEventAt` and `hookActive`
/// ticks stay in the registry's unobserved truth store).
@MainActor
@Observable
public final class AgentSessionStatusModel {
    public internal(set) var status: AgentSessionStatus

    init(status: AgentSessionStatus) {
        self.status = status
    }
}

/// Adapter-agnostic state container. Function-context callers read ``statuses``
/// / ``status(for:)`` (always-fresh truth, never observed); SwiftUI bodies read
/// ``observedStatus(for:)`` so invalidation scopes to the sessions they render.
@MainActor
public final class AgentSessionRegistry: ObservableObject, AgentSessionRegistryProtocol {
    /// Unobserved truth, including per-event bookkeeping fields (`lastEventAt`,
    /// `hookActive`). Reads register no SwiftUI dependency; `objectWillChange`
    /// fires only on register/deregister, never per event.
    public private(set) var statuses: [UUID: AgentSessionStatus] = [:]

    /// Fires once per applied change that is render-relevant (and on
    /// register/deregister). Event-driven consumers (aggregator refresh,
    /// presented-snapshot rebuilds) subscribe via `onReceive` instead of
    /// observing `statuses`, which keeps `ContentView.body` off the per-event
    /// path.
    public let statusesDidChange = PassthroughSubject<Void, Never>()

    /// Window inside which a hook event suppresses an OSC event with the same effective state.
    static let oscDedupWindow: TimeInterval = 0.750

    /// If no hook events arrive for this long, clear the hookActive flag so OSC can fall through.
    static let hookActivityTimeout: TimeInterval = 60

    /// Tracks per-session telemetry for OSC dedup. Mirror of the published state, but
    /// holds bookkeeping fields that don't need to drive UI.
    private struct Bookkeeping {
        var lastHookRunStateApplied: AgentRunState?
        var lastHookEventAt: Date?
        var hookExpirationTask: Task<Void, Never>?
    }

    private var models: [UUID: AgentSessionStatusModel] = [:]
    private var bookkeeping: [UUID: Bookkeeping] = [:]
    private let clock: @Sendable () -> Date
    private let localStateStore: LocalStateStore?

    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        localStateStore: LocalStateStore? = nil
    ) {
        self.clock = clock
        self.localStateStore = localStateStore
    }

    // MARK: - Public surface

    public func register(hostSessionID: UUID, cwd: String, kind: AgentKind) {
        if statuses[hostSessionID] != nil { return }
        let now = clock()
        let status = AgentSessionStatus(
            hostSessionID: hostSessionID,
            kind: kind,
            cwd: Self.normalizePath(cwd),
            run: .idle,
            lastEventAt: now,
            hookActive: false,
            createdAt: now
        )
        objectWillChange.send()
        statuses[hostSessionID] = status
        models[hostSessionID] = AgentSessionStatusModel(status: status)
        bookkeeping[hostSessionID] = Bookkeeping()
        statusesDidChange.send()
    }

    public func deregister(hostSessionID: UUID) {
        guard statuses[hostSessionID] != nil else { return }
        bookkeeping[hostSessionID]?.hookExpirationTask?.cancel()
        bookkeeping.removeValue(forKey: hostSessionID)
        objectWillChange.send()
        statuses.removeValue(forKey: hostSessionID)
        models.removeValue(forKey: hostSessionID)
        statusesDidChange.send()
    }

    /// Always-fresh truth for one session; registers no SwiftUI dependency.
    public func status(for hostSessionID: UUID) -> AgentSessionStatus? {
        statuses[hostSessionID]
    }

    /// Truth for one session, read in a way that registers an Observation
    /// dependency on that session's render-relevant state. SwiftUI bodies use
    /// this so a session's change invalidates exactly the views that rendered
    /// it; the returned value still carries live `lastEventAt`/`hookActive`.
    public func observedStatus(for hostSessionID: UUID) -> AgentSessionStatus? {
        guard let model = models[hostSessionID] else { return nil }
        _ = model.status
        return statuses[hostSessionID]
    }

    /// Render-state snapshot for aggregation surfaces: each session's value as
    /// of its last render-relevant change (`lastEventAt`/`hookActive` stale by
    /// design). Feeding aggregators these instead of ``statuses`` keeps their
    /// own equality gates closed through no-op ticks, so a quiet bus publishes
    /// nothing anywhere downstream.
    public var renderStatuses: [UUID: AgentSessionStatus] {
        models.mapValues(\.status)
    }

    public func apply(events: [AgentEvent], for hostSessionID: UUID, origin: AgentEventOrigin) {
        guard !events.isEmpty else { return }
        guard var status = statuses[hostSessionID] else { return }
        var book = bookkeeping[hostSessionID] ?? Bookkeeping()
        let now = clock()
        var containsAttentionEvent = false

        for event in events {
            let mappedRun = Self.runState(for: event)

            // OSC dedup: if a hook recently produced the same effective run state
            // for this session, suppress this OSC event.
            if case .osc = origin, status.hookActive {
                if let lastRun = book.lastHookRunStateApplied,
                    let lastAt = book.lastHookEventAt,
                    lastRun == mappedRun,
                    now.timeIntervalSince(lastAt) < Self.oscDedupWindow
                {
                    continue
                }
            }

            switch event {
            case .sessionStart(let agentSessionID, let cwd, let kind):
                status.agentSessionID = agentSessionID
                status.kind = kind
                status.cwd = Self.normalizePath(cwd)
                status.run = .idle

            case .userPrompt:
                status.run = .thinking

            case .toolStart(let name, let detail):
                status.run = .runningTool(name: name, detail: detail)

            case .toolEnd, .toolBatchEnd:
                // Assume more tools are likely; settle on `.thinking` until a Stop arrives.
                status.run = .thinking

            case .toolFailed(let name, let error):
                status.run = .errored(
                    category: .toolFailure,
                    message: error ?? "tool '\(name)' failed"
                )
                containsAttentionEvent = true

            case .awaitingInput(let reason, _, _):
                status.run = .awaitingInput(reason: reason)
                containsAttentionEvent = true

            case .stopped(let error):
                status.run = error == nil ? .complete : .errored(category: .unknown, message: error)
                containsAttentionEvent = containsAttentionEvent || error != nil

            case .errored(let category, let message):
                status.run = .errored(category: category, message: message)
                containsAttentionEvent = true

            case .statusFields(let fields):
                // Intentionally do not touch status.run.
                mergeStatusFields(fields, into: &status)

            case .workingDirectory(let path):
                status.cwd = Self.normalizePath(path)

            case .bell:
                // Bell is a no-op for v1; notifications come from awaitingInput.
                continue
            }

            if case .hook = origin {
                book.lastHookRunStateApplied = status.run
                book.lastHookEventAt = now
                status.hookActive = true
            }
        }

        status.lastEventAt = now
        if case .hook = origin {
            book.hookExpirationTask?.cancel()
            book.hookExpirationTask = scheduleHookExpiration(
                for: hostSessionID,
                timeout: Self.hookActivityTimeout
            )
        }
        statuses[hostSessionID] = status
        bookkeeping[hostSessionID] = book

        // Gate publication: a batch that only moved `lastEventAt`/`hookActive`
        // (an unchanged status-line tick, toolEnd while already thinking) must
        // not invalidate any view. Attention events are the exception: a
        // repeated identical prompt must re-arm acknowledged attention UI,
        // whose acknowledgment model compares event timestamps — so the fresh
        // `lastEventAt` has to reach the render snapshot even when nothing
        // else changed.
        if let model = models[hostSessionID],
            containsAttentionEvent || !Self.isRenderEquivalent(model.status, status)
        {
            model.status = status
            statusesDidChange.send()
        }

        if let localStateStore {
            let persistedEvents = events
            let persistedStatus = status
            Task {
                try? await localStateStore.recordAgentEvents(
                    persistedEvents,
                    hostSessionID: hostSessionID,
                    origin: origin,
                    status: persistedStatus,
                    occurredAt: now
                )
            }
        }
    }

    // MARK: - Internal

    /// True when the two statuses differ only in non-render bookkeeping fields.
    static func isRenderEquivalent(_ lhs: AgentSessionStatus, _ rhs: AgentSessionStatus) -> Bool {
        var normalizedLHS = lhs
        normalizedLHS.lastEventAt = rhs.lastEventAt
        normalizedLHS.hookActive = rhs.hookActive
        return normalizedLHS == rhs
    }

    /// Test seam: directly clear `hookActive` flag (simulates the 60s watchdog firing).
    func clearHookActive(for hostSessionID: UUID) {
        guard var status = statuses[hostSessionID] else { return }
        status.hookActive = false
        statuses[hostSessionID] = status
        bookkeeping[hostSessionID]?.hookExpirationTask?.cancel()
        bookkeeping[hostSessionID]?.hookExpirationTask = nil
    }

    private func scheduleHookExpiration(
        for hostSessionID: UUID,
        timeout: TimeInterval
    ) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.clearHookActive(for: hostSessionID)
            }
        }
    }

    private static func runState(for event: AgentEvent) -> AgentRunState? {
        switch event {
        case .userPrompt: return .thinking
        case .toolStart(let name, let detail): return .runningTool(name: name, detail: detail)
        case .toolEnd, .toolBatchEnd: return .thinking
        case .toolFailed(let name, let error):
            return .errored(category: .toolFailure, message: error ?? "tool '\(name)' failed")
        case .awaitingInput(let reason, _, _): return .awaitingInput(reason: reason)
        case .stopped(let error):
            return error == nil ? .complete : .errored(category: .unknown, message: error)
        case .errored(let category, let message):
            return .errored(category: category, message: message)
        case .sessionStart, .statusFields, .workingDirectory, .bell:
            return nil
        }
    }

    private func mergeStatusFields(
        _ fields: AgentEvent.StatusFields,
        into status: inout AgentSessionStatus
    ) {
        if let v = fields.modelDisplayName { status.modelDisplayName = v }
        if let v = fields.contextUsedPercent { status.contextUsedPercent = v }
        if let v = fields.fiveHourLimitUsedPercent { status.fiveHourLimitUsedPercent = v }
        if let v = fields.fiveHourLimitResetsAt { status.fiveHourLimitResetsAt = v }
        if let v = fields.costUSD { status.costUSD = v }
    }

    private static func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
