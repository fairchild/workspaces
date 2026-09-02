//
//  RuntimeProcessAlertTests.swift
//  WorkspaceManagerTests
//
//  The growth detector's rules (#1368): what earns an alert, what stays quiet,
//  and the two runaways from 2026-08-23 replayed against it.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("RuntimeProcessAlerts")
struct RuntimeProcessAlertTests {
    private let gigabyte: Int64 = 1_024 * 1_024 * 1_024
    private let megabyte: Int64 = 1_024 * 1_024

    @Test("A process over the ceiling alerts on its first sample")
    func ceilingAlertsImmediately() {
        var ledger = RuntimeProcessGrowthLedger()
        ledger.record(
            candidates: [process(pid: 42, name: "codex", footprint: 7 * gigabyte)],
            appDescendantPIDs: [42],
            at: Date(timeIntervalSinceReferenceDate: 0)
        )

        let alerts = ledger.alerts()

        #expect(alerts.count == 1)
        #expect(alerts.first?.trigger == .footprintCeiling)
        #expect(alerts.first?.pid == 42)
        #expect(alerts.first?.isAppDescendant == true)
        #expect(alerts.first?.sampleCount == 1)
    }

    @Test("The 2026-08-23 codex runaway trips the growth rule below the ceiling")
    func codexRunawayTripsGrowthRule() {
        // The real numbers: 2.7 GB → 7.5 GB over 30 hours is about 164 MB/h,
        // replayed here at a 30 s cadence over the one-hour window. It stays far
        // under the 6 GB ceiling throughout, which is the point — the growth rule
        // is what catches this leak, a day before the footprint rule would.
        let bytesPerHour = (7.5 - 2.7) * Double(gigabyte) / 30
        var ledger = RuntimeProcessGrowthLedger()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let startedAt = Date(timeIntervalSince1970: 1_000)
        for step in 0...120 {
            let elapsed = TimeInterval(step) * 30
            let footprint = Int64(2.7 * Double(gigabyte) + bytesPerHour * elapsed / 3_600)
            ledger.record(
                candidates: [
                    process(pid: 7, name: "codex", footprint: footprint, startedAt: startedAt)
                ],
                appDescendantPIDs: [7],
                at: start.addingTimeInterval(elapsed)
            )
        }

        let alerts = ledger.alerts()

        #expect(alerts.count == 1)
        #expect(alerts.first?.trigger == .growthRate)
        #expect(alerts.first?.sampleCount == 121)
        let rate = Double(alerts.first?.growthBytesPerHour ?? 0)
        #expect(rate > bytesPerHour * 0.99)
        #expect(rate < bytesPerHour * 1.01)
        // And the reading the doc comment claims: about 164 MB/h.
        #expect(rate / Double(megabyte) > 160)
        #expect(rate / Double(megabyte) < 170)
    }

    @Test("A flat large-but-below-ceiling process stays quiet")
    func flatProcessStaysQuiet() {
        var ledger = RuntimeProcessGrowthLedger()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for step in 0...40 {
            ledger.record(
                candidates: [process(pid: 7, name: "node", footprint: 2 * gigabyte)],
                appDescendantPIDs: [7],
                at: start.addingTimeInterval(TimeInterval(step) * 30)
            )
        }

        #expect(ledger.alerts().isEmpty)
    }

    @Test("A short burst is not extrapolated into an hourly rate")
    func shortBurstDoesNotAlert() {
        // Five samples 30 s apart span 2 minutes. Naively extrapolated that is
        // 6 GB/h; the observation-span floor is what stops the detector saying so.
        var ledger = RuntimeProcessGrowthLedger()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for step in 0...4 {
            ledger.record(
                candidates: [
                    process(pid: 7, name: "node", footprint: 2 * gigabyte + Int64(step) * 50 * megabyte)
                ],
                appDescendantPIDs: [7],
                at: start.addingTimeInterval(TimeInterval(step) * 30)
            )
        }

        #expect(ledger.alerts().isEmpty)
    }

    @Test("A small process growing fast in relative terms stays quiet")
    func smallProcessStaysQuiet() {
        var ledger = RuntimeProcessGrowthLedger()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for step in 0...40 {
            ledger.record(
                candidates: [
                    process(pid: 7, name: "zsh", footprint: Int64(step + 1) * 8 * megabyte)
                ],
                appDescendantPIDs: [7],
                at: start.addingTimeInterval(TimeInterval(step) * 30)
            )
        }

        // Roughly 960 MB/h, over the rate threshold, but the process is still
        // under a gigabyte — a rate alone is not a runaway.
        #expect(ledger.alerts().isEmpty)
    }

    @Test("Readings outside the window are forgotten")
    func readingsOutsideWindowAreForgotten() {
        var ledger = RuntimeProcessGrowthLedger()
        let policy = RuntimeProcessAlertPolicy(observationWindow: 300)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        for step in 0...20 {
            ledger.record(
                candidates: [process(pid: 7, name: "node", footprint: gigabyte)],
                appDescendantPIDs: [7],
                at: start.addingTimeInterval(TimeInterval(step) * 30),
                policy: policy
            )
        }

        #expect(ledger.alerts(policy: policy).isEmpty)
        #expect(ledger.series[7]?.readings.count == 11)
    }

    @Test("A pid that leaves the candidate set loses its history")
    func departedPIDLosesHistory() {
        var ledger = RuntimeProcessGrowthLedger()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        ledger.record(
            candidates: [process(pid: 7, name: "codex", footprint: 7 * gigabyte)],
            appDescendantPIDs: [7],
            at: start
        )
        ledger.record(
            candidates: [process(pid: 8, name: "node", footprint: megabyte)],
            appDescendantPIDs: [8],
            at: start.addingTimeInterval(30)
        )

        #expect(ledger.series[7] == nil)
        #expect(ledger.alerts().isEmpty)
    }

    @Test("A recycled pid does not inherit its predecessor's slope")
    func recycledPIDStartsFresh() {
        var ledger = RuntimeProcessGrowthLedger()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let firstStart = Date(timeIntervalSince1970: 1_000)
        for step in 0...40 {
            ledger.record(
                candidates: [
                    process(
                        pid: 7, name: "codex",
                        footprint: 2 * gigabyte + Int64(step) * 20 * megabyte,
                        startedAt: firstStart)
                ],
                appDescendantPIDs: [7],
                at: start.addingTimeInterval(TimeInterval(step) * 30)
            )
        }
        #expect(ledger.alerts().count == 1)

        // Same pid, different process. Its history starts here.
        ledger.record(
            candidates: [
                process(
                    pid: 7, name: "node", footprint: 2 * gigabyte,
                    startedAt: Date(timeIntervalSince1970: 9_000))
            ],
            appDescendantPIDs: [7],
            at: start.addingTimeInterval(1_230)
        )

        #expect(ledger.alerts().isEmpty)
        #expect(ledger.series[7]?.readings.count == 1)
    }

    @Test("The app never alerts about itself, so it can never offer to stop itself")
    func appRootIsNotACandidate() async {
        // The app is the root of its own tree, not a descendant of it. Left in
        // the candidate set, an app over the ceiling would put a Stop button in
        // the sidebar wired to the app's own pid.
        let sampler = RuntimeDiagnosticsSampler(
            provider: FixedRuntimeProcessProvider(
                processes: [
                    RuntimeProcessSample(
                        pid: 100, parentPID: 1, name: "WorkSpaces", command: "WorkSpaces",
                        cpuPercent: 0, residentMemoryBytes: 12 * gigabyte,
                        startedAt: Date(timeIntervalSince1970: 1_000)),
                    RuntimeProcessSample(
                        pid: 101, parentPID: 100, name: "codex", command: "codex",
                        cpuPercent: 0, residentMemoryBytes: 9 * gigabyte,
                        startedAt: Date(timeIntervalSince1970: 1_000)),
                ]
            ),
            processIdentifier: { 100 },
            minimumSampleInterval: 0
        )

        _ = await sampler.sample(workspaceDirectories: [])

        // The app is the larger of the two and would otherwise sort first.
        #expect(await sampler.alerts().map(\.pid) == [101])
    }

    @Test("A workspace-scoped process that happens to be the app is still not a candidate")
    func appRootIsNotACandidateEvenWhenWorkspaceScoped() async {
        let workspace = URL(fileURLWithPath: "/Users/fairchild/code/project")
        let sampler = RuntimeDiagnosticsSampler(
            provider: FixedRuntimeProcessProvider(
                processes: [
                    RuntimeProcessSample(
                        pid: 100, parentPID: 1, name: "WorkSpaces", command: "WorkSpaces",
                        cpuPercent: 0, residentMemoryBytes: 12 * gigabyte,
                        currentDirectory: "/Users/fairchild/code/project",
                        startedAt: Date(timeIntervalSince1970: 1_000))
                ]
            ),
            processIdentifier: { 100 },
            minimumSampleInterval: 0
        )

        _ = await sampler.sample(workspaceDirectories: [workspace])

        #expect(await sampler.alerts().isEmpty)
    }

    @Test("An always-on sweep can be given a scope before the pane ever opens")
    func scopeCanBeSetWithoutSampling() async {
        let workspace = URL(fileURLWithPath: "/Users/fairchild/code/project")
        let sampler = RuntimeDiagnosticsSampler(
            provider: FixedRuntimeProcessProvider(
                processes: [
                    RuntimeProcessSample(
                        pid: 100, parentPID: 1, name: "WorkSpaces", command: "WorkSpaces",
                        cpuPercent: 0, residentMemoryBytes: megabyte,
                        startedAt: Date(timeIntervalSince1970: 1_000)),
                    RuntimeProcessSample(
                        pid: 200, parentPID: 1, name: "claude", command: "claude",
                        cpuPercent: 0, residentMemoryBytes: 9 * gigabyte,
                        currentDirectory: "/Users/fairchild/code/project",
                        startedAt: Date(timeIntervalSince1970: 1_000)),
                ]
            ),
            processIdentifier: { 100 },
            minimumSampleInterval: 0
        )

        // Nil preserves a scope; it does not establish one. Without this call the
        // watchdog watches nothing outside the app's own tree until somebody
        // opens the Diagnostics pane.
        await sampler.setWorkspaceScope([workspace])
        _ = await sampler.sampleIfNeeded(workspaceDirectories: nil)

        #expect(await sampler.alerts().map(\.pid) == [200])
        #expect(await sampler.alerts().first?.isAppDescendant == false)
    }

    @Test("A muted pid is not reported")
    func mutedPIDIsNotReported() {
        var ledger = RuntimeProcessGrowthLedger()
        ledger.record(
            candidates: [
                process(pid: 42, name: "codex", footprint: 7 * gigabyte),
                process(pid: 43, name: "node", footprint: 9 * gigabyte),
            ],
            appDescendantPIDs: [42, 43],
            at: Date(timeIntervalSinceReferenceDate: 0)
        )

        let muted = RuntimeProcessIdentity(pid: 43, startedAt: Date(timeIntervalSince1970: 1_000))
        #expect(ledger.alerts(muted: [muted]).map(\.pid) == [42])
    }

    @Test("Alerts are ordered by footprint, worst first")
    func alertsOrderedByFootprint() {
        var ledger = RuntimeProcessGrowthLedger()
        ledger.record(
            candidates: [
                process(pid: 1, name: "a", footprint: 7 * gigabyte),
                process(pid: 2, name: "b", footprint: 12 * gigabyte),
                process(pid: 3, name: "c", footprint: 9 * gigabyte),
            ],
            appDescendantPIDs: [1, 2, 3],
            at: Date(timeIntervalSinceReferenceDate: 0)
        )

        #expect(ledger.alerts().map(\.pid) == [2, 3, 1])
    }

    @Test("A workspace-scoped process outside the app tree is flagged as such")
    func workspaceScopedProcessIsNotADescendant() {
        var ledger = RuntimeProcessGrowthLedger()
        ledger.record(
            candidates: [process(pid: 99, name: "claude", footprint: 8 * gigabyte)],
            appDescendantPIDs: [],
            at: Date(timeIntervalSinceReferenceDate: 0)
        )

        #expect(ledger.alerts().first?.isAppDescendant == false)
    }

    @Test("Sampler surfaces and mutes alerts across samples")
    func samplerSurfacesAndMutesAlerts() async {
        let clock = MutableTestClock(Date(timeIntervalSinceReferenceDate: 0))
        let provider = FixedRuntimeProcessProvider(
            processes: [
                RuntimeProcessSample(
                    pid: 100, parentPID: 1, name: "WorkSpaces", command: "WorkSpaces",
                    cpuPercent: 0, residentMemoryBytes: 512 * megabyte,
                    startedAt: Date(timeIntervalSince1970: 1_000)),
                RuntimeProcessSample(
                    pid: 101, parentPID: 100, name: "codex", command: "codex",
                    cpuPercent: 0, residentMemoryBytes: 9 * gigabyte,
                    startedAt: Date(timeIntervalSince1970: 1_000)),
            ]
        )
        let sampler = RuntimeDiagnosticsSampler(
            provider: provider,
            processIdentifier: { 100 },
            clock: { clock.now },
            minimumSampleInterval: 0
        )

        let identity = RuntimeProcessIdentity(pid: 101, startedAt: Date(timeIntervalSince1970: 1_000))

        _ = await sampler.sample(workspaceDirectories: [])
        #expect(await sampler.alerts().map(\.pid) == [101])

        await sampler.mute(identity)
        clock.advance(by: 30)
        _ = await sampler.sample(workspaceDirectories: [])
        #expect(await sampler.alerts().isEmpty)

        await sampler.unmute(identity)
        #expect(await sampler.alerts().map(\.pid) == [101])
    }

    private func process(
        pid: Int32,
        name: String,
        footprint: Int64,
        startedAt: Date = Date(timeIntervalSince1970: 1_000)
    ) -> RuntimeProcessSample {
        RuntimeProcessSample(
            pid: pid,
            parentPID: 1,
            name: name,
            command: name,
            cpuPercent: 0,
            residentMemoryBytes: footprint,
            startedAt: startedAt
        )
    }
}

struct FixedRuntimeProcessProvider: RuntimeProcessSnapshotProviding {
    let processes: [RuntimeProcessSample]

    func processes() async throws -> [RuntimeProcessSample] {
        processes
    }
}

final class MutableTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}
