//
//  RuntimeProcessWatchdogTests.swift
//  WorkspaceManagerAppTests
//
//  The always-on watchdog's contract (#1368): it publishes what the sampler
//  found, dismissing an alert keeps it dismissed across the next sweep, and
//  stopping a process that will not die stops nagging about it.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("RuntimeProcessWatchdog")
@MainActor
struct RuntimeProcessWatchdogTests {
    private let gigabyte: Int64 = 1_024 * 1_024 * 1_024

    @Test("Publishes the alerts the sampler found")
    func publishesSamplerAlerts() async {
        let watchdog = RuntimeProcessWatchdog(
            sampler: makeSampler(runawayFootprint: 9 * gigabyte),
            cadence: 3_600,
            stopProcess: { _ in true }
        )

        await watchdog.sampleOnce()

        #expect(watchdog.alerts.map(\.pid) == [101])
        #expect(watchdog.alerts.first?.trigger == .footprintCeiling)
        #expect(watchdog.lastSampledAt != nil)
    }

    @Test("A quiet machine publishes nothing")
    func quietMachinePublishesNothing() async {
        let watchdog = RuntimeProcessWatchdog(
            sampler: makeSampler(runawayFootprint: 64 * 1_024 * 1_024),
            cadence: 3_600,
            stopProcess: { _ in true }
        )

        await watchdog.sampleOnce()

        #expect(watchdog.alerts.isEmpty)
    }

    @Test("A dismissed alert stays dismissed across the next sweep")
    func dismissedAlertStaysDismissed() async {
        let watchdog = RuntimeProcessWatchdog(
            sampler: makeSampler(runawayFootprint: 9 * gigabyte),
            cadence: 3_600,
            stopProcess: { _ in true }
        )
        await watchdog.sampleOnce()
        guard let alert = watchdog.alerts.first else {
            Issue.record("expected an alert to dismiss")
            return
        }

        watchdog.dismiss(alert: alert)
        await settle(until: { await MainActor.run { watchdog.alerts.isEmpty } })
        #expect(watchdog.alerts.isEmpty)

        await watchdog.sampleOnce()
        #expect(watchdog.alerts.isEmpty)
    }

    @Test("Stopping asks the terminator for that pid and re-samples")
    func stoppingAsksTheTerminator() async {
        let stopped = StoppedIdentities()
        let watchdog = RuntimeProcessWatchdog(
            sampler: makeSampler(runawayFootprint: 9 * gigabyte),
            cadence: 3_600,
            stopProcess: { identity in
                await stopped.record(identity)
                return true
            }
        )
        await watchdog.sampleOnce()
        guard let alert = watchdog.alerts.first else {
            Issue.record("expected an alert to stop")
            return
        }

        watchdog.stop(alert: alert)
        await settle(until: { await !stopped.all.isEmpty })

        // The pid alone is not what gets signalled: the start time travels with
        // it so a recycled pid cannot be mistaken for the runaway.
        #expect(await stopped.all == [RuntimeProcessIdentity(pid: 101, startedAt: Self.started)])
    }

    @Test("A process that refuses to stop stays visible, marked as unstoppable")
    func unstoppableProcessStaysVisible() async {
        let watchdog = RuntimeProcessWatchdog(
            sampler: makeSampler(runawayFootprint: 9 * gigabyte),
            cadence: 3_600,
            stopProcess: { _ in false }
        )
        await watchdog.sampleOnce()
        guard let alert = watchdog.alerts.first else {
            Issue.record("expected an alert to stop")
            return
        }

        watchdog.stop(alert: alert)
        await settle(until: { await MainActor.run { !watchdog.unstoppable.isEmpty } })

        // A runaway that survived both signals is still eating the machine, so
        // it stays on screen rather than being quietly dismissed.
        #expect(watchdog.alerts.map(\.pid) == [101])
        #expect(watchdog.unstoppable == [101])
    }

    @Test("Stopping refuses to signal launchd, the kernel, or an unidentified pid")
    func terminatorRefusesReservedPIDs() async {
        let started = Date(timeIntervalSince1970: 1_000)
        #expect(await RuntimeProcessTerminator.stop(.init(pid: 0, startedAt: started)) == false)
        #expect(await RuntimeProcessTerminator.stop(.init(pid: 1, startedAt: started)) == false)
        // No recorded start time means no way to tell the process from a
        // successor holding the same pid, so nothing is signalled.
        #expect(await RuntimeProcessTerminator.stop(.init(pid: 4_242, startedAt: nil)) == false)
    }

    @Test("Stopping refuses a pid whose start time no longer matches")
    func terminatorRefusesRecycledPID() async {
        let stopped = await RuntimeProcessTerminator.stop(
            .init(pid: 4_242, startedAt: Date(timeIntervalSince1970: 1_000)),
            startTimeReader: { _ in Date(timeIntervalSince1970: 9_000) }
        )

        #expect(stopped == false)
    }

    @Test("Identity matching is exact, not approximate")
    func terminatorRefusesNearbyStartTime() async {
        // Both values are the same kernel field read through the same code, so
        // there is no measurement error to absorb — and any tolerance is a window
        // in which a recycled pid gets signalled. A millisecond apart is a
        // different process.
        let expected = Date(timeIntervalSince1970: 1_000)
        for offset in [0.001, 0.1, 0.5, 0.999] {
            let stopped = await RuntimeProcessTerminator.stop(
                .init(pid: 4_242, startedAt: expected),
                startTimeReader: { _ in expected.addingTimeInterval(offset) }
            )
            #expect(stopped == false, "a start time \(offset)s away must not be signalled")
        }
    }

    fileprivate static let started = Date(timeIntervalSince1970: 1_000)

    private func makeSampler(runawayFootprint: Int64) -> RuntimeDiagnosticsSampler {
        RuntimeDiagnosticsSampler(
            provider: FixedRuntimeProcessProvider(
                processes: [
                    RuntimeProcessSample(
                        pid: 100, parentPID: 1, name: "WorkSpaces", command: "WorkSpaces",
                        cpuPercent: 0, residentMemoryBytes: 512 * 1_024 * 1_024,
                        startedAt: Self.started),
                    RuntimeProcessSample(
                        pid: 101, parentPID: 100, name: "codex", command: "codex",
                        cpuPercent: 0, residentMemoryBytes: runawayFootprint,
                        startedAt: Self.started),
                ]
            ),
            processIdentifier: { 100 },
            minimumSampleInterval: 0
        )
    }

    /// Waits on the observable change rather than a tuned sleep. The watchdog's
    /// actions are fire-and-forget `Task`s, so the test yields until the state it
    /// is asserting on has actually moved.
    private func settle(until condition: @Sendable () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor StoppedIdentities {
    private(set) var all: [RuntimeProcessIdentity] = []

    func record(_ identity: RuntimeProcessIdentity) {
        all.append(identity)
    }
}

private struct FixedRuntimeProcessProvider: RuntimeProcessSnapshotProviding {
    let processes: [RuntimeProcessSample]

    func processes() async throws -> [RuntimeProcessSample] {
        processes
    }
}
