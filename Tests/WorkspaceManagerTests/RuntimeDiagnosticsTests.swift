import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("RuntimeDiagnostics")
struct RuntimeDiagnosticsTests {
    @Test("ps parser preserves process metrics and command")
    func psParserPreservesProcessMetricsAndCommand() {
        let output = """
              100     1   1.5  2048 00:01:02 WorkSpaces /Applications/WorkSpaces.app/Contents/MacOS/WorkSpaces
              101   100  81.8 65536 01:02:03 claude claude --continue
            """

        let processes = RuntimeDiagnosticsParser.parsePS(
            output,
            cwdByPID: [101: "/Users/fairchild/code/project"]
        )

        #expect(processes.count == 2)
        #expect(processes[0].pid == 100)
        #expect(processes[0].parentPID == 1)
        #expect(processes[0].cpuPercent == 1.5)
        #expect(processes[0].residentMemoryBytes == 2_097_152)
        #expect(processes[0].cpuTimeSeconds == 62)
        #expect(processes[1].name == "claude")
        #expect(processes[1].command == "claude --continue")
        #expect(processes[1].currentDirectory == "/Users/fairchild/code/project")
    }

    @Test("lsof parser maps cwd by pid")
    func lsofParserMapsCWDByPID() {
        let output = """
            p100
            cWorkSpaces
            n/Applications/WorkSpaces.app
            p101
            cclaude
            n/Users/fairchild/code/project
            """

        let cwdByPID = RuntimeDiagnosticsParser.parseLsofCWDs(output)

        #expect(cwdByPID[100] == "/Applications/WorkSpaces.app")
        #expect(cwdByPID[101] == "/Users/fairchild/code/project")
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
