import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("RuntimeDiagnostics")
struct RuntimeDiagnosticsTests {
    @Test("Kernel entries map onto the sample the pane renders")
    func kernelEntriesMapOntoSamples() async throws {
        let provider = LiveRuntimeProcessSnapshotProvider(
            snapshot: { _ in
                [
                    ProcessInventoryEntry(
                        pid: 101,
                        parentPID: 100,
                        uid: 501,
                        name: "claude",
                        cpuTimeSeconds: 60,
                        footprintBytes: 65_536 * 1_024,
                        elapsedSeconds: 120,
                        currentDirectory: "/Users/fairchild/code/project",
                        commandLine: "claude --continue"
                    ),
                    ProcessInventoryEntry(
                        pid: 200,
                        parentPID: 1,
                        uid: 0,
                        name: "kernel-owned",
                        cpuTimeSeconds: 0,
                        footprintBytes: 2_048,
                        elapsedSeconds: 0
                    ),
                ]
            },
            clock: { Date(timeIntervalSinceReferenceDate: 0) }
        )

        let samples = try await provider.processes()

        #expect(samples.count == 2)
        #expect(samples[0].pid == 101)
        #expect(samples[0].parentPID == 100)
        #expect(samples[0].name == "claude")
        #expect(samples[0].command == "claude --continue")
        #expect(samples[0].residentMemoryBytes == 67_108_864)
        #expect(samples[0].cpuTimeSeconds == 60)
        // 60 s of CPU over 120 s of life is half a core.
        #expect(samples[0].cpuPercent == 50)
        #expect(samples[0].currentDirectory == "/Users/fairchild/code/project")
        // No detail for a process the caller may not inspect: the command falls
        // back to the accounting name and the directory stays unknown.
        #expect(samples[1].command == "kernel-owned")
        #expect(samples[1].currentDirectory == nil)
        #expect(samples[1].cpuPercent == 0)
    }

    @Test("descendant tree includes root and nested children only")
    func descendantTreeIncludesRootAndNestedChildrenOnly() {
        let processes = [
            sample(pid: 10, parentPID: 1, name: "WorkspaceManager"),
            sample(pid: 11, parentPID: 10, name: "zsh"),
            sample(pid: 12, parentPID: 11, name: "claude"),
            sample(pid: 20, parentPID: 1, name: "Other"),
        ]

        let tree = RuntimeDiagnosticsSampler.appTreeProcesses(from: processes, rootPID: 10)

        #expect(tree.map(\.pid) == [10, 11, 12])
    }

    @Test("workspace processes match cwd prefixes")
    func workspaceProcessesMatchCWDPrefixes() {
        let workspace = URL(fileURLWithPath: "/Users/fairchild/code/project")
        let processes = [
            sample(pid: 10, parentPID: 1, name: "WorkspaceManager", cwd: "/Applications"),
            sample(pid: 11, parentPID: 10, name: "claude", cpu: 25, cwd: "/Users/fairchild/code/project"),
            sample(pid: 12, parentPID: 10, name: "node", cpu: 50, cwd: "/Users/fairchild/code/project/web"),
            sample(pid: 20, parentPID: 1, name: "Other", cwd: "/Users/fairchild/code/other"),
        ]

        let workspaceProcesses = RuntimeDiagnosticsSampler.workspaceProcesses(
            from: processes,
            workspaceDirectories: [workspace]
        )

        #expect(workspaceProcesses.map(\.pid) == [12, 11])
    }

    @Test("snapshot workspace scope can update without a new process sample")
    func snapshotWorkspaceScopeCanUpdateWithoutNewProcessSample() {
        let firstWorkspace = URL(fileURLWithPath: "/Users/fairchild/code/project")
        let secondWorkspace = URL(fileURLWithPath: "/Users/fairchild/code/other")
        let snapshot = RuntimeDiagnosticsSnapshot(
            sampledAt: Date(timeIntervalSinceReferenceDate: 10),
            appPID: 10,
            allProcesses: [
                sample(pid: 10, parentPID: 1, name: "WorkspaceManager", cwd: "/Applications"),
                sample(pid: 11, parentPID: 10, name: "claude", cpu: 25, cwd: "/Users/fairchild/code/project"),
                sample(pid: 12, parentPID: 10, name: "node", cpu: 50, cwd: "/Users/fairchild/code/other"),
            ],
            appTreeProcesses: [],
            appTreeTotals: .empty,
            workspaceProcesses: [
                sample(pid: 11, parentPID: 10, name: "claude", cpu: 25, cwd: "/Users/fairchild/code/project")
            ],
            workspaceTotals: RuntimeDiagnosticsSampler.totals(for: [
                sample(pid: 11, parentPID: 10, name: "claude", cpu: 25, cwd: "/Users/fairchild/code/project")
            ])
        )

        let rescoped = RuntimeDiagnosticsSampler.rescopeWorkspaceProcesses(
            in: snapshot,
            workspaceDirectories: [secondWorkspace]
        )

        #expect(
            RuntimeDiagnosticsSampler.rescopeWorkspaceProcesses(
                in: snapshot,
                workspaceDirectories: [firstWorkspace]
            ).workspaceProcesses.map(\.pid) == [11])
        #expect(rescoped.workspaceProcesses.map(\.pid) == [12])
        #expect(rescoped.workspaceTotals.cpuPercent == 50)
    }

    @Test("sampler trims history to configured duration")
    func samplerTrimsHistoryToConfiguredDuration() async {
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 0))
        let provider = StubRuntimeProcessProvider(processes: [
            sample(pid: 100, parentPID: 1, name: "WorkspaceManager")
        ])
        let sampler = RuntimeDiagnosticsSampler(
            provider: provider,
            processIdentifier: { 100 },
            clock: { clock.now },
            minimumSampleInterval: 0,
            maxHistoryDuration: 10
        )

        _ = await sampler.sample(workspaceDirectories: [])
        clock.advance(by: 5)
        _ = await sampler.sample(workspaceDirectories: [])
        clock.advance(by: 20)
        _ = await sampler.sample(workspaceDirectories: [])

        let history = await sampler.history(duration: 60)

        #expect(history.sampleCount == 1)
        #expect(history.latest?.sampledAt == clock.now)
    }

    @Test("Older snapshots keep their totals and shed their process arrays")
    func olderSnapshotsAreCompacted() async {
        // The sampler now runs whether or not the pane is open, so an hour of
        // uncompacted history would be an hour of every process on the host.
        let clock = MutableClock(Date(timeIntervalSinceReferenceDate: 0))
        let provider = StubRuntimeProcessProvider(processes: [
            sample(pid: 100, parentPID: 1, name: "WorkspaceManager", cpu: 3, memory: 2_048),
            sample(pid: 101, parentPID: 100, name: "claude", cpu: 7, memory: 4_096),
        ])
        let sampler = RuntimeDiagnosticsSampler(
            provider: provider,
            processIdentifier: { 100 },
            clock: { clock.now },
            minimumSampleInterval: 0,
            maxHistoryDuration: 3_600,
            fullSnapshotRetention: 2
        )

        for _ in 0..<6 {
            _ = await sampler.sample(workspaceDirectories: [])
            clock.advance(by: 30)
        }

        let history = await sampler.history(duration: 3_600)

        #expect(history.sampleCount == 6)
        #expect(history.snapshots.prefix(4).allSatisfy { $0.allProcesses.isEmpty })
        #expect(history.snapshots.suffix(2).allSatisfy { $0.allProcesses.count == 2 })
        // The aggregates the pane reads survive compaction: every retained
        // snapshot still carries its totals, and the peak is read off them.
        #expect(history.snapshots.allSatisfy { $0.appTreeTotals.processCount == 2 })
        #expect(history.appMemoryPeakBytes == 6_144)
        #expect(history.latest?.appTreeProcesses.count == 2)
    }

    @Test("CPU percent is the share of a core used since the last sample")
    func cpuPercentIsSampledNotLifetimeAveraged() {
        let started = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSinceReferenceDate: 60)
        let sample = RuntimeProcessSample(
            pid: 42, parentPID: 1, name: "codex", command: "codex",
            cpuPercent: 1, residentMemoryBytes: 0, cpuTimeSeconds: 105,
            startedAt: started)

        let overlaid = RuntimeDiagnosticsSampler.overlayingSampledCPU(
            [sample],
            previous: [
                RuntimeProcessIdentity(pid: 42, startedAt: started):
                    (seconds: 90, at: now.addingTimeInterval(-30))
            ],
            now: now
        )

        // 15 s of CPU over a 30 s window is half a core.
        #expect(overlaid[0].cpuPercent == 50)

        // A process seen for the first time keeps whatever the provider reported,
        // because a rate needs two readings.
        let firstSighting = RuntimeDiagnosticsSampler.overlayingSampledCPU(
            [sample], previous: [:], now: now)
        #expect(firstSighting[0].cpuPercent == 1)
    }

    @Test("A pid seen before under a different start time is treated as new")
    func recycledPIDDoesNotInheritCPURate() {
        let now = Date(timeIntervalSinceReferenceDate: 60)
        let sample = RuntimeProcessSample(
            pid: 42, parentPID: 1, name: "node", command: "node",
            cpuPercent: 7, residentMemoryBytes: 0, cpuTimeSeconds: 3,
            startedAt: Date(timeIntervalSince1970: 9_000))

        let overlaid = RuntimeDiagnosticsSampler.overlayingSampledCPU(
            [sample],
            previous: [
                RuntimeProcessIdentity(pid: 42, startedAt: Date(timeIntervalSince1970: 1_000)):
                    (seconds: 90, at: now.addingTimeInterval(-30))
            ],
            now: now
        )

        #expect(overlaid[0].cpuPercent == 7)
    }

    @Test("Concurrent sampling collapses to one sweep")
    func concurrentSamplingCollapsesToOneSweep() async {
        // The pane polls every 5 s and the watchdog every 30 s against one
        // sampler. Without coalescing both can pass the interval check and land
        // out of order, leaving the newest snapshot behind an older one.
        let provider = SlowRuntimeProcessProvider(
            processes: [sample(pid: 100, parentPID: 1, name: "WorkspaceManager")]
        )
        let sampler = RuntimeDiagnosticsSampler(
            provider: provider,
            processIdentifier: { 100 },
            minimumSampleInterval: 0
        )

        async let first = sampler.sample(workspaceDirectories: [])
        async let second = sampler.sample(workspaceDirectories: [])
        async let third = sampler.sample(workspaceDirectories: [])
        _ = await (first, second, third)

        #expect(await provider.callCount == 1)
        #expect(await sampler.history(duration: 3_600).sampleCount == 1)
    }

    @Test("The always-on sweep keeps the scope the pane last set")
    func nilScopeKeepsTheLastScope() async {
        let workspace = URL(fileURLWithPath: "/Users/fairchild/code/project")
        let provider = StubRuntimeProcessProvider(processes: [
            sample(pid: 100, parentPID: 1, name: "WorkspaceManager", cwd: "/Applications"),
            sample(pid: 200, parentPID: 1, name: "claude", cwd: "/Users/fairchild/code/project"),
        ])
        let sampler = RuntimeDiagnosticsSampler(
            provider: provider,
            processIdentifier: { 100 },
            minimumSampleInterval: 0
        )

        let scoped = await sampler.sample(workspaceDirectories: [workspace])
        #expect(scoped?.workspaceProcesses.map(\.pid) == [200])

        // The watchdog has no view of the model store and passes nil. Reading
        // that as "scope nothing" would drop every workspace-scoped process from
        // the growth ledger on the next sweep.
        let unscoped = await sampler.sample(workspaceDirectories: nil)
        #expect(unscoped?.workspaceProcesses.map(\.pid) == [200])
    }

    @Test("summary counts event and agent failures")
    func summaryCountsEventAndAgentFailures() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let events = [
            StartupDiagnosticsStore.DiagnosticEvent(
                timestamp: now,
                metric: "workspace_status_sync",
                durationMs: 250,
                labels: ["outcome": "success"]
            ),
            StartupDiagnosticsStore.DiagnosticEvent(
                timestamp: now.addingTimeInterval(1),
                metric: "open_in_editor_launch",
                durationMs: 1_500,
                labels: ["outcome": "failure", "failure_reason": "editor_not_installed"]
            ),
            StartupDiagnosticsStore.DiagnosticEvent(
                timestamp: now.addingTimeInterval(2),
                metric: "trace_parse_error",
                durationMs: 10,
                labels: ["error": "bad_payload"]
            ),
        ]
        let statuses = [
            AgentSessionStatus(
                hostSessionID: UUID(),
                kind: .claudeCode,
                cwd: "/repo",
                run: .errored(category: .toolFailure, message: "tool failed"),
                lastEventAt: now.addingTimeInterval(3)
            )
        ]

        let summary = RuntimeDiagnosticsSummary.make(events: events, agentStatuses: statuses)

        #expect(summary.spanCount == 3)
        #expect(summary.failureCount == 3)
        #expect(summary.slowSpanCount == 1)
        #expect(summary.parseErrorCount == 1)
        #expect(summary.activeAgentSessionCount == 1)
        #expect(summary.latestFailures.count == 3)
    }

    private func sample(
        pid: Int32,
        parentPID: Int32,
        name: String,
        cpu: Double = 0,
        memory: Int64 = 0,
        cwd: String? = nil
    ) -> RuntimeProcessSample {
        RuntimeProcessSample(
            pid: pid,
            parentPID: parentPID,
            name: name,
            command: name,
            cpuPercent: cpu,
            residentMemoryBytes: memory,
            currentDirectory: cwd
        )
    }
}

private actor SlowRuntimeProcessProvider: RuntimeProcessSnapshotProviding {
    let processes: [RuntimeProcessSample]
    private(set) var callCount = 0

    init(processes: [RuntimeProcessSample]) {
        self.processes = processes
    }

    func processes() async throws -> [RuntimeProcessSample] {
        callCount += 1
        try? await Task.sleep(for: .milliseconds(50))
        return processes
    }
}

private struct StubRuntimeProcessProvider: RuntimeProcessSnapshotProviding {
    let processes: [RuntimeProcessSample]

    func processes() async throws -> [RuntimeProcessSample] {
        processes
    }
}

private final class MutableClock: @unchecked Sendable {
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
