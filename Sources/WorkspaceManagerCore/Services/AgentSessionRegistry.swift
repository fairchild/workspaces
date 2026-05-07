//
//  AgentSessionRegistry.swift
//  WorkspaceManagerCore
//
//  Live registry of agent session statuses keyed by host session ID. Consumes
//  AgentEvent values from any input channel (HTTP hooks, OSC fallback, transcript
//  replay, headless stream) and produces a normalized AgentRunState for the UI.
//
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 1, Channel 3 ("Dedup with hooks").
//

import Combine
import Foundation

/// Adapter-agnostic state container. The UI binds to ``statuses`` and reads the
/// current ``AgentRunState`` for any session it owns.
@MainActor
public final class AgentSessionRegistry: ObservableObject, AgentSessionRegistryProtocol {
    @Published public private(set) var statuses: [UUID: AgentSessionStatus] = [:]

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

    private var bookkeeping: [UUID: Bookkeeping] = [:]
    private let clock: @Sendable () -> Date

    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: - Public surface

    public func register(hostSessionID: UUID, cwd: String, kind: AgentKind) {
        if statuses[hostSessionID] != nil { return }
        let now = clock()
        statuses[hostSessionID] = AgentSessionStatus(
            hostSessionID: hostSessionID,
            kind: kind,
            cwd: Self.normalizePath(cwd),
            run: .idle,
            lastEventAt: now,
            hookActive: false,
            createdAt: now
        )
        bookkeeping[hostSessionID] = Bookkeeping()
    }

    public func deregister(hostSessionID: UUID) {
        bookkeeping[hostSessionID]?.hookExpirationTask?.cancel()
        bookkeeping.removeValue(forKey: hostSessionID)
        statuses.removeValue(forKey: hostSessionID)
    }

    public func ingest(_ event: AgentEvent, for hostSessionID: UUID, origin: AgentEventOrigin) {
        guard var status = statuses[hostSessionID] else { return }
        var book = bookkeeping[hostSessionID] ?? Bookkeeping()

        let now = clock()
        let mappedRun = Self.runState(for: event)

        // OSC dedup: if a hook recently produced the same effective run state for this session,
        // suppress this OSC event.
        if case .osc = origin, status.hookActive {
            if let lastRun = book.lastHookRunStateApplied,
                let lastAt = book.lastHookEventAt,
                lastRun == mappedRun,
                now.timeIntervalSince(lastAt) < Self.oscDedupWindow
            {
                return
            }
        }

        status.lastEventAt = now

        switch event {
        case .sessionStart(let agentSessionID, let cwd, let kind):
            status.agentSessionID = agentSessionID
            status.kind = kind
            status.cwd = Self.normalizePath(cwd)
            status.run = .idle
            if case .hook = origin {
                status.hookActive = true
                book.hookExpirationTask?.cancel()
                book.hookExpirationTask = scheduleHookExpiration(
                    for: hostSessionID,
                    timeout: Self.hookActivityTimeout
                )
            }

        case .userPrompt:
            status.run = .thinking

        case .toolStart(let name, let detail):
            status.run = .runningTool(name: name, detail: detail)

        case .toolEnd, .toolBatchEnd:
            // Assume more tools are likely; settle on `.thinking` until a Stop arrives.
            status.run = .thinking

        case .toolFailed(let name, let error):
            status.run = .errored(category: .toolFailure, message: error ?? "tool '\(name)' failed")

        case .awaitingInput(let reason, _, _):
            status.run = .awaitingInput(reason: reason)

        case .stopped(let error):
            status.run = error == nil ? .complete : .errored(category: .unknown, message: error)

        case .errored(let category, let message):
            status.run = .errored(category: category, message: message)

        case .statusFields(let fields):
            mergeStatusFields(fields, into: &status)
            // intentionally do not touch status.run
            statuses[hostSessionID] = status
            bookkeeping[hostSessionID] = book
            return

        case .workingDirectory(let path):
            status.cwd = Self.normalizePath(path)
            statuses[hostSessionID] = status
            bookkeeping[hostSessionID] = book
            return

        case .bell:
            // PR #1: bell is a no-op for v1 — notifications come from awaitingInput.
            statuses[hostSessionID] = status
            bookkeeping[hostSessionID] = book
            return
        }

        if case .hook = origin {
            book.lastHookRunStateApplied = status.run
            book.lastHookEventAt = now
            status.hookActive = true
            book.hookExpirationTask?.cancel()
            book.hookExpirationTask = scheduleHookExpiration(
                for: hostSessionID,
                timeout: Self.hookActivityTimeout
            )
        }

        statuses[hostSessionID] = status
        bookkeeping[hostSessionID] = book
    }

    public func updateStatusFields(_ fields: AgentEvent.StatusFields, for hostSessionID: UUID) {
        guard var status = statuses[hostSessionID] else { return }
        mergeStatusFields(fields, into: &status)
        status.lastEventAt = clock()
        statuses[hostSessionID] = status
    }

    /// Resolve a host session for a hook payload. The rule is `agentSessionID`-first
    /// — once a host session has been bound to a Claude session id, that binding is
    /// canonical for the rest of the session. Cwd is only consulted as a *fallback*
    /// for the very first event in a session (which is always a `SessionStart` and
    /// therefore arrives before any binding exists).
    ///
    /// Behaviour:
    ///   1. If `agentSessionID` is non-nil and matches a bound entry → return it.
    ///   2. Otherwise, collect host sessions whose cwd matches AND that have no
    ///      agentSessionID bound yet. Pick the most recently-registered one.
    ///   3. If no candidate, return nil; the listener will drop the event.
    ///
    /// This is what makes the registry safe for duplicate tabs and split panes on
    /// the same workspace — two `HostTerminalSession`s with the same cwd no longer
    /// collapse onto a single entry. See defect 2 from the round-2 review.
    public func resolveHostSession(cwd: String, agentSessionID: String?) -> UUID? {
        if let agentSessionID {
            for (hostID, status) in statuses where status.agentSessionID == agentSessionID {
                return hostID
            }
        }

        let normalized = Self.normalizePath(cwd)
        let unboundCandidates = statuses.values.filter {
            $0.cwd == normalized && $0.agentSessionID == nil
        }
        guard !unboundCandidates.isEmpty else { return nil }
        // Most recently registered wins — matches the user's expectation that the
        // newest terminal owns the next SessionStart.
        return
            unboundCandidates
            .sorted { $0.createdAt > $1.createdAt }
            .first?
            .hostSessionID
    }

    // MARK: - Internal

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
