//
//  RuntimeProcessWatchdog.swift
//  WorkspaceManager
//
//  Runs the process sampler on a slow cadence for the whole life of the app,
//  not just while the Diagnostics pane is open (#1368), and publishes the
//  processes that have grown past a threshold so the sidebar can say so. The
//  sweep spawns nothing, which is what makes always-on affordable.
//

import Darwin
import Foundation
import SwiftUI
import WorkspaceManagerCore

@MainActor
final class RuntimeProcessWatchdog: ObservableObject {
    static let shared = RuntimeProcessWatchdog()

    /// Processes currently over a footprint or growth threshold, worst first.
    @Published private(set) var alerts: [RuntimeProcessAlert] = []
    /// Processes the app asked to stop and could not. They stay on screen: a
    /// runaway that survived both signals is still eating the machine, and a
    /// banner that quietly disappeared would say the opposite.
    @Published private(set) var unstoppable: Set<Int32> = []
    /// When the last sweep completed. `nil` until the first one lands.
    @Published private(set) var lastSampledAt: Date?

    private let sampler: RuntimeDiagnosticsSampler
    private let cadence: TimeInterval
    private let stopProcess: @Sendable (RuntimeProcessIdentity) async -> Bool
    private var pollingTask: Task<Void, Never>?
    private var didStart = false

    init(
        sampler: RuntimeDiagnosticsSampler = .shared,
        cadence: TimeInterval = 30,
        stopProcess: @escaping @Sendable (RuntimeProcessIdentity) async -> Bool = { identity in
            await RuntimeProcessTerminator.stop(identity)
        }
    ) {
        self.sampler = sampler
        self.cadence = cadence
        self.stopProcess = stopProcess
    }

    /// Hooked at app startup from `WorkspaceManagerApp.init`. Idempotent, so a
    /// second window or a test harness calling it again is harmless.
    func start() {
        guard !didStart else { return }
        didStart = true

        // Fixture mode stages its own alerts and does not sweep, so a genuine
        // runaway on the dev machine cannot leak into a capture.
        if let fixtureAlerts = UIFixtureRuntimeAlertBootstrap.fixtureAlerts() {
            alerts = fixtureAlerts
            lastSampledAt = Date()
            return
        }

        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleOnce()
                guard let cadence = self?.cadence else { return }
                try? await Task.sleep(for: .seconds(cadence))
            }
        }
    }

    /// Establishes the scope the always-on sweep judges workspace processes
    /// against. Pushed from the main window as soon as it appears, and again
    /// whenever the model changes, so a cold launch that never opens Diagnostics
    /// still watches the workspaces the app manages.
    func updateWorkspaceScope(_ directories: [URL]) async {
        await sampler.setWorkspaceScope(directories)
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        didStart = false
    }

    /// The pane and the watchdog share one sampler, so the pane's own 5 s poll
    /// already feeds this ledger; the watchdog's job is to keep sampling when
    /// nobody is looking. It passes no directories — it has no view of the model
    /// store — which the sampler reads as "keep the scope the pane last set"
    /// rather than as "scope nothing".
    func sampleOnce(force: Bool = false) async {
        if force {
            // A stop has to be answered by a sweep that ran after it. The
            // rate-limited path would return the cached ledger, and the plain
            // path would join a sweep already in flight — both can still name the
            // process that just died, leaving it on screen until the next cadence
            // and letting a second Stop be aimed at a pid that is already gone.
            _ = await sampler.sampleFresh(workspaceDirectories: nil)
        } else {
            _ = await sampler.sampleIfNeeded(workspaceDirectories: nil)
        }
        let nextAlerts = await sampler.alerts()
        // Gated assignment, per #1347's publication discipline: a sweep that
        // finds the same processes must not invalidate anything that observes us.
        if nextAlerts != alerts {
            alerts = nextAlerts
        }
        let living = Set(nextAlerts.map(\.pid))
        if !unstoppable.isSubset(of: living) {
            unstoppable.formIntersection(living)
        }
        lastSampledAt = Date()
    }

    /// Stops the named process, then re-samples so the strip reflects the result
    /// rather than waiting out the cadence.
    func stop(alert: RuntimeProcessAlert) {
        Task {
            let stopped = await stopProcess(alert.identity)
            if stopped {
                unstoppable.remove(alert.pid)
            } else {
                // Not muted. A process the app could not stop is exactly the one
                // the user still needs to see.
                unstoppable.insert(alert.pid)
            }
            // A stopped pid leaves the candidate set on the next sweep, which
            // drops its series and clears the strip without special handling.
            await sampleOnce(force: true)
        }
    }

    /// Dismisses one alert without touching the process.
    func dismiss(alert: RuntimeProcessAlert) {
        Task {
            await sampler.mute(alert.identity)
            unstoppable.remove(alert.pid)
            alerts = await sampler.alerts()
        }
    }
}

/// Sends a runaway process the same two signals the app's own supervisor uses:
/// `SIGTERM`, a bounded grace period, then `SIGKILL`.
///
/// Every signal is preceded by an identity check. An alert can be half a minute
/// old and the process can exit during the grace period, so a pid taken on trust
/// is a pid that may by then belong to something else — and the whole point of
/// the affordance is that it is destructive.
enum RuntimeProcessTerminator {
    static func stop(
        _ identity: RuntimeProcessIdentity,
        gracePeriod: TimeInterval = 3,
        startTimeReader: @Sendable (Int32) -> Date? = { ProcessInventory.entry(pid: $0)?.startedAt }
    ) async -> Bool {
        guard identity.pid > 1 else { return false }
        guard stillTheSameProcess(identity, startTimeReader) else { return false }
        guard kill(identity.pid, SIGTERM) == 0 else { return errno == ESRCH }

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            if !stillTheSameProcess(identity, startTimeReader) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }

        guard stillTheSameProcess(identity, startTimeReader) else { return true }
        _ = kill(identity.pid, SIGKILL)
        for _ in 0..<20 {
            if !stillTheSameProcess(identity, startTimeReader) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !stillTheSameProcess(identity, startTimeReader)
    }

    /// True only when the pid is live *and* started at exactly the instant the
    /// alert recorded. An unknown start time on either side fails closed.
    ///
    /// Exactly, not approximately: both values are the same kernel field read
    /// through the same code, so there is no measurement error to absorb — and a
    /// tolerance is a window in which a recycled pid gets signalled.
    private static func stillTheSameProcess(
        _ identity: RuntimeProcessIdentity,
        _ startTimeReader: @Sendable (Int32) -> Date?
    ) -> Bool {
        guard let expected = identity.startedAt else { return false }
        guard let actual = startTimeReader(identity.pid) else { return false }
        return actual == expected
    }
}
