//
//  AgentSessionRegistry.swift
//  WorkspaceManagerCore
//
//  Live registry of agent session statuses keyed by host session ID. Consumes
//  AgentEvent values from hook, status-line, and OSC inputs, then produces a
//  normalized AgentRunState for the UI.
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

    public func apply(events: [AgentEvent], for hostSessionID: UUID, origin: AgentEventOrigin) {
        guard !events.isEmpty else { return }
        guard var status = statuses[hostSessionID] else { return }
        var book = bookkeeping[hostSessionID] ?? Bookkeeping()
        let now = clock()

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

            case .awaitingInput(let reason, _, _):
                status.run = .awaitingInput(reason: reason)

            case .stopped(let error):
                status.run = error == nil ? .complete : .errored(category: .unknown, message: error)

            case .errored(let category, let message):
                status.run = .errored(category: category, message: message)

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
