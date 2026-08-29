//
//  RuntimeDiagnosticsViewModel.swift
//  WorkspaceManager
//
//  Main-actor bridge between the Detail Pane UI and core runtime diagnostics sampler.
//

import Foundation
import SwiftUI
import WorkspaceManagerCore

enum RuntimeDiagnosticsRange: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1_800
        case .oneHour: return 3_600
        }
    }
}

@MainActor
final class RuntimeDiagnosticsViewModel: ObservableObject {
    @Published private(set) var snapshot: RuntimeDiagnosticsSnapshot?
    @Published private(set) var history = RuntimeProcessHistory(snapshots: [])
    @Published private(set) var summary = RuntimeDiagnosticsSummary.make(events: [], agentStatuses: [])
    @Published private(set) var localStateSnapshot = LocalStateStoreStatusSnapshot(
        mode: .unavailable,
        bootstrapErrors: []
    )
    @Published private(set) var localStateSummary: LocalStateStoreSummary?
    @Published private(set) var localStateSummaryError: String?
    /// Hook-ingest counters read from the live listener, or `nil` when no listener
    /// is running (previews, tests, a launch where the socket lock went to another
    /// instance). Carries the dropped-event counters that make a silently
    /// disconnected agent session visible (#1397).
    @Published private(set) var hookIngest: AgentHookListener.Statistics?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastCheckedAt: Date?

    private let sampler: RuntimeDiagnosticsSampler
    private var pollingTask: Task<Void, Never>?
    private var workspaceDirectories: [URL] = []
    private var agentStatuses: [AgentSessionStatus] = []
    private var selectedRange: RuntimeDiagnosticsRange = .fifteenMinutes

    init(sampler: RuntimeDiagnosticsSampler = .shared) {
        self.sampler = sampler
    }

    func start(
        workspaceDirectories: [URL],
        agentStatuses: [AgentSessionStatus],
        selectedRange: RuntimeDiagnosticsRange
    ) {
        updateContext(
            workspaceDirectories: workspaceDirectories,
            agentStatuses: agentStatuses,
            selectedRange: selectedRange
        )

        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(forceSample: false)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func updateContext(
        workspaceDirectories: [URL],
        agentStatuses: [AgentSessionStatus],
        selectedRange: RuntimeDiagnosticsRange
    ) {
        self.workspaceDirectories = workspaceDirectories
        self.agentStatuses = agentStatuses
        self.selectedRange = selectedRange
        Task { await refreshSummaryAndHistory() }
    }

    func refreshNow() {
        Task { await refresh(forceSample: true) }
    }

    private func refresh(forceSample: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }

        let nextSnapshot: RuntimeDiagnosticsSnapshot?
        if forceSample {
            nextSnapshot = await sampler.sample(workspaceDirectories: workspaceDirectories)
        } else {
            nextSnapshot = await sampler.sampleIfNeeded(workspaceDirectories: workspaceDirectories)
        }

        if let nextSnapshot {
            snapshot = RuntimeDiagnosticsSampler.rescopeWorkspaceProcesses(
                in: nextSnapshot,
                workspaceDirectories: workspaceDirectories
            )
        }
        lastCheckedAt = Date()
        await refreshSummaryAndHistory()
    }

    private func refreshSummaryAndHistory() async {
        history = await sampler.history(duration: selectedRange.duration)
        if let latestSnapshot = await sampler.latestSnapshot() {
            snapshot = RuntimeDiagnosticsSampler.rescopeWorkspaceProcesses(
                in: latestSnapshot,
                workspaceDirectories: workspaceDirectories
            )
        }

        let events = await StartupDiagnosticsStore.shared.allEvents()
        summary = RuntimeDiagnosticsSummary.make(events: events, agentStatuses: agentStatuses)
        // Gated assignment: this runs on every poll and on every render-relevant
        // agent event, and a counter that did not move must not invalidate the
        // pane (#1347's publication discipline).
        let nextHookIngest = await ClaudeIntegrationLifecycle.shared.listener?.currentStatistics()
        if nextHookIngest != hookIngest {
            hookIngest = nextHookIngest
        }
        await refreshLocalStateSummary()
    }

    private func refreshLocalStateSummary() async {
        localStateSnapshot = LocalStateStoreController.shared.snapshot
        guard let localStateStore = LocalStateStoreController.shared.store else {
            localStateSummary = nil
            localStateSummaryError = nil
            return
        }

        do {
            localStateSummary = try await localStateStore.summary()
            localStateSummaryError = nil
        } catch {
            localStateSummary = nil
            localStateSummaryError = String(describing: error)
        }
    }
}
