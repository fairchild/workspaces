//
//  RuntimeDiagnostics.swift
//  WorkspaceManagerCore
//
//  Lightweight process and trace diagnostics for the WorkSpaces Detail Pane.
//

import Darwin
import Foundation

public struct RuntimeProcessSample: Codable, Equatable, Identifiable, Sendable {
    public var id: Int32 { pid }

    public let pid: Int32
    public let parentPID: Int32
    public let name: String
    public let command: String
    public let cpuPercent: Double
    public let residentMemoryBytes: Int64
    public let cpuTimeSeconds: TimeInterval
    public let currentDirectory: String?

    public init(
        pid: Int32,
        parentPID: Int32,
        name: String,
        command: String,
        cpuPercent: Double,
        residentMemoryBytes: Int64,
        cpuTimeSeconds: TimeInterval = 0,
        currentDirectory: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.command = command
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.cpuTimeSeconds = cpuTimeSeconds
        self.currentDirectory = currentDirectory
    }
}

public struct RuntimeResourceTotals: Codable, Equatable, Sendable {
    public let processCount: Int
    public let cpuPercent: Double
    public let residentMemoryBytes: Int64
    public let cpuTimeSeconds: TimeInterval

    public init(
        processCount: Int,
        cpuPercent: Double,
        residentMemoryBytes: Int64,
        cpuTimeSeconds: TimeInterval
    ) {
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.cpuTimeSeconds = cpuTimeSeconds
    }

    public static let empty = RuntimeResourceTotals(
        processCount: 0,
        cpuPercent: 0,
        residentMemoryBytes: 0,
        cpuTimeSeconds: 0
    )
}

public struct RuntimeDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public let sampledAt: Date
    public let appPID: Int32
    public let allProcesses: [RuntimeProcessSample]
    public let appTreeProcesses: [RuntimeProcessSample]
    public let appTreeTotals: RuntimeResourceTotals
    public let workspaceProcesses: [RuntimeProcessSample]
    public let workspaceTotals: RuntimeResourceTotals
    public let errorMessage: String?

    public init(
        sampledAt: Date,
        appPID: Int32,
        allProcesses: [RuntimeProcessSample],
        appTreeProcesses: [RuntimeProcessSample],
        appTreeTotals: RuntimeResourceTotals,
        workspaceProcesses: [RuntimeProcessSample],
        workspaceTotals: RuntimeResourceTotals,
        errorMessage: String? = nil
    ) {
        self.sampledAt = sampledAt
        self.appPID = appPID
        self.allProcesses = allProcesses
        self.appTreeProcesses = appTreeProcesses
        self.appTreeTotals = appTreeTotals
        self.workspaceProcesses = workspaceProcesses
        self.workspaceTotals = workspaceTotals
        self.errorMessage = errorMessage
    }
}

public struct RuntimeProcessHistory: Equatable, Sendable {
    public let snapshots: [RuntimeDiagnosticsSnapshot]

    public init(snapshots: [RuntimeDiagnosticsSnapshot]) {
        self.snapshots = snapshots
    }

    public var sampleCount: Int { snapshots.count }

    public var latest: RuntimeDiagnosticsSnapshot? { snapshots.last }

    public var appCPUAverage: Double {
        average { $0.appTreeTotals.cpuPercent }
    }

    public var appCPUPeak: Double {
        snapshots.map(\.appTreeTotals.cpuPercent).max() ?? 0
    }

    public var appMemoryPeakBytes: Int64 {
        snapshots.map(\.appTreeTotals.residentMemoryBytes).max() ?? 0
    }

    public var workspaceCPUAverage: Double {
        average { $0.workspaceTotals.cpuPercent }
    }

    public var workspaceCPUPeak: Double {
        snapshots.map(\.workspaceTotals.cpuPercent).max() ?? 0
    }

    public var workspaceMemoryPeakBytes: Int64 {
        snapshots.map(\.workspaceTotals.residentMemoryBytes).max() ?? 0
    }

    private func average(_ value: (RuntimeDiagnosticsSnapshot) -> Double) -> Double {
        guard !snapshots.isEmpty else { return 0 }
        return snapshots.map(value).reduce(0, +) / Double(snapshots.count)
    }
}

public struct RuntimeDiagnosticFailure: Equatable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let title: String
    public let detail: String

    public init(id: String, timestamp: Date, title: String, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.detail = detail
    }
}

public struct RuntimeDiagnosticsSummary: Equatable, Sendable {
    public let spanCount: Int
    public let failureCount: Int
    public let slowSpanCount: Int
    public let parseErrorCount: Int
    public let activeAgentSessionCount: Int
    public let latestFailures: [RuntimeDiagnosticFailure]

    public init(
        spanCount: Int,
        failureCount: Int,
        slowSpanCount: Int,
        parseErrorCount: Int,
        activeAgentSessionCount: Int,
        latestFailures: [RuntimeDiagnosticFailure]
    ) {
        self.spanCount = spanCount
        self.failureCount = failureCount
        self.slowSpanCount = slowSpanCount
        self.parseErrorCount = parseErrorCount
        self.activeAgentSessionCount = activeAgentSessionCount
        self.latestFailures = latestFailures
    }

    public static func make(
        events: [StartupDiagnosticsStore.DiagnosticEvent],
        agentStatuses: [AgentSessionStatus],
        slowSpanThresholdMs: Double = 1_000,
        maxFailures: Int = 5
    ) -> RuntimeDiagnosticsSummary {
        let eventFailures = events.enumerated().compactMap { index, event -> RuntimeDiagnosticFailure? in
            guard isFailure(event) else { return nil }
            let reason =
                event.labels["failure_reason"]
                ?? event.labels["outcome"]
                ?? event.labels["error"]
                ?? "failed"
            return RuntimeDiagnosticFailure(
                id: "event-\(index)-\(event.timestamp.timeIntervalSinceReferenceDate)",
                timestamp: event.timestamp,
                title: event.metric,
                detail: reason
            )
        }

        let agentFailures = agentStatuses.compactMap { status -> RuntimeDiagnosticFailure? in
            guard case .errored(let category, let message) = status.run else { return nil }
            return RuntimeDiagnosticFailure(
                id: "agent-\(status.hostSessionID.uuidString)",
                timestamp: status.lastEventAt,
                title: "\(status.kind.rawValue) \(category.rawValue)",
                detail: message ?? status.cwd
            )
        }

        let latestFailures = (eventFailures + agentFailures)
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(maxFailures)

        return RuntimeDiagnosticsSummary(
            spanCount: events.count,
            failureCount: eventFailures.count + agentFailures.count,
            slowSpanCount: events.filter { $0.durationMs >= slowSpanThresholdMs }.count,
            parseErrorCount: events.filter(Self.isParseError).count,
            activeAgentSessionCount: agentStatuses.filter { status in
                if case .complete = status.run { return false }
                return true
            }.count,
            latestFailures: Array(latestFailures)
        )
    }

    private static func isFailure(_ event: StartupDiagnosticsStore.DiagnosticEvent) -> Bool {
        if event.labels["failure_reason"] != nil || event.labels["error"] != nil {
            return true
        }
        if let outcome = event.labels["outcome"]?.lowercased() {
            return outcome.contains("failure") || outcome == "failed"
        }
        return event.metric.lowercased().contains("failure")
    }

    private static func isParseError(_ event: StartupDiagnosticsStore.DiagnosticEvent) -> Bool {
        let metric = event.metric.lowercased()
        guard metric.contains("parse") else { return false }
        return isFailure(event) || metric.contains("error")
    }
}

public protocol RuntimeProcessSnapshotProviding: Sendable {
    func processes() async throws -> [RuntimeProcessSample]
}

public struct LiveRuntimeProcessSnapshotProvider: RuntimeProcessSnapshotProviding {
    public init() {}

    public func processes() async throws -> [RuntimeProcessSample] {
        async let processOutput = ProcessRunner.run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,pcpu=,rss=,time=,comm=,args="],
            timeout: 10
        )
        async let cwdOutput = ProcessRunner.run(
            executable: "/usr/sbin/lsof",
            arguments: ["-d", "cwd", "-F", "pcn"],
            timeout: 10
        )

        let processResult = try await processOutput
        guard processResult.exitCode == 0 else {
            throw RuntimeDiagnosticsError.commandFailed(
                command: "ps",
                stderr: processResult.stderr
            )
        }

        let cwdByPID: [Int32: String]
        do {
            let cwdResult = try await cwdOutput
            cwdByPID =
                cwdResult.exitCode == 0
                ? RuntimeDiagnosticsParser.parseLsofCWDs(cwdResult.stdout)
                : [:]
        } catch {
            cwdByPID = [:]
        }

        let samples = RuntimeDiagnosticsParser.parsePS(processResult.stdout, cwdByPID: cwdByPID)
        return samples.map { sample in
            // `ps rss` excludes compressed pages and graphics memory and
            // under-reported this app ~7x against Activity Monitor (#1347 D1).
            // Physical footprint is what the kernel's own limits act on;
            // same-user processes read it without privileges, others keep rss.
            guard let footprint = RuntimeProcessMemory.physicalFootprint(pid: sample.pid) else {
                return sample
            }
            return RuntimeProcessSample(
                pid: sample.pid,
                parentPID: sample.parentPID,
                name: sample.name,
                command: sample.command,
                cpuPercent: sample.cpuPercent,
                residentMemoryBytes: footprint,
                cpuTimeSeconds: sample.cpuTimeSeconds,
                currentDirectory: sample.currentDirectory
            )
        }
    }
}

public enum RuntimeProcessMemory {
    /// The kernel's physical footprint for `pid` (what Activity Monitor's
    /// "Memory" column and the cpu/memory resource limits act on), via
    /// `proc_pid_rusage`. Returns nil when the pid is gone or belongs to
    /// another user without inspection rights.
    public static func physicalFootprint(pid: Int32) -> Int64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        guard info.ri_phys_footprint <= UInt64(Int64.max) else { return nil }
        return Int64(info.ri_phys_footprint)
    }

    /// High-water physical footprint over the process lifetime; nil under the
    /// same conditions as ``physicalFootprint(pid:)``.
    public static func lifetimeMaxPhysicalFootprint(pid: Int32) -> Int64? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        guard info.ri_lifetime_max_phys_footprint <= UInt64(Int64.max) else { return nil }
        return Int64(info.ri_lifetime_max_phys_footprint)
    }
}

public enum RuntimeDiagnosticsError: Error, CustomStringConvertible, Equatable, Sendable {
    case commandFailed(command: String, stderr: String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "\(command) failed while collecting diagnostics."
                : "\(command) failed while collecting diagnostics: \(trimmed)"
        }
    }
}

public enum RuntimeDiagnosticsParser {
    public static func parsePS(
        _ output: String,
        cwdByPID: [Int32: String] = [:]
    ) -> [RuntimeProcessSample] {
        output.split(separator: "\n").compactMap { line in
            parsePSLine(String(line), cwdByPID: cwdByPID)
        }
    }

    static func parsePSLine(
        _ line: String,
        cwdByPID: [Int32: String]
    ) -> RuntimeProcessSample? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
        guard
            parts.count >= 6,
            let pid = Int32(parts[0]),
            let parentPID = Int32(parts[1]),
            let cpuPercent = Double(parts[2]),
            let residentMemoryKB = Int64(parts[3])
        else {
            return nil
        }

        let cpuTimeSeconds = parseCPUTime(String(parts[4]))
        let name = String(parts[5])
        let command = parts.count >= 7 ? String(parts[6]) : name

        return RuntimeProcessSample(
            pid: pid,
            parentPID: parentPID,
            name: name,
            command: command,
            cpuPercent: cpuPercent,
            residentMemoryBytes: residentMemoryKB * 1_024,
            cpuTimeSeconds: cpuTimeSeconds,
            currentDirectory: cwdByPID[pid]
        )
    }

    public static func parseLsofCWDs(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var currentPID: Int32?

        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            guard let prefix = line.first else { continue }
            let value = String(line.dropFirst())

            switch prefix {
            case "p":
                currentPID = Int32(value)
            case "n":
                if let currentPID {
                    result[currentPID] = value
                }
            default:
                break
            }
        }

        return result
    }

    public static func parseCPUTime(_ value: String) -> TimeInterval {
        let daySplit = value.split(separator: "-", maxSplits: 1)
        let dayCount: Int
        let timePart: Substring
        if daySplit.count == 2 {
            dayCount = Int(daySplit[0]) ?? 0
            timePart = daySplit[1]
        } else {
            dayCount = 0
            timePart = Substring(value)
        }

        let parts = timePart.split(separator: ":").compactMap { Double($0) }
        let seconds: Double
        switch parts.count {
        case 3:
            seconds = (parts[0] * 3_600) + (parts[1] * 60) + parts[2]
        case 2:
            seconds = (parts[0] * 60) + parts[1]
        case 1:
            seconds = parts[0]
        default:
            seconds = 0
        }

        return Double(dayCount * 86_400) + seconds
    }
}

public actor RuntimeDiagnosticsSampler {
    public static let shared = RuntimeDiagnosticsSampler()

    private let provider: any RuntimeProcessSnapshotProviding
    private let processIdentifier: @Sendable () -> Int32
    private let clock: @Sendable () -> Date
    private let minimumSampleInterval: TimeInterval
    private let maxHistoryDuration: TimeInterval

    private var snapshots: [RuntimeDiagnosticsSnapshot] = []
    private var lastErrorMessage: String?

    public init(
        provider: any RuntimeProcessSnapshotProviding = LiveRuntimeProcessSnapshotProvider(),
        processIdentifier: @escaping @Sendable () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        clock: @escaping @Sendable () -> Date = { Date() },
        minimumSampleInterval: TimeInterval = 5,
        maxHistoryDuration: TimeInterval = 3_600
    ) {
        self.provider = provider
        self.processIdentifier = processIdentifier
        self.clock = clock
        self.minimumSampleInterval = minimumSampleInterval
        self.maxHistoryDuration = maxHistoryDuration
    }

    public func sampleIfNeeded(workspaceDirectories: [URL]) async -> RuntimeDiagnosticsSnapshot? {
        let now = clock()
        if let latest = snapshots.last,
            now.timeIntervalSince(latest.sampledAt) < minimumSampleInterval
        {
            return latest
        }
        return await sample(workspaceDirectories: workspaceDirectories)
    }

    @discardableResult
    public func sample(workspaceDirectories: [URL]) async -> RuntimeDiagnosticsSnapshot? {
        let now = clock()
        let appPID = processIdentifier()

        do {
            let allProcesses = try await provider.processes()
            let appTreeProcesses = Self.appTreeProcesses(from: allProcesses, rootPID: appPID)
            let workspaceProcesses = Self.workspaceProcesses(
                from: allProcesses,
                workspaceDirectories: workspaceDirectories
            )
            let snapshot = RuntimeDiagnosticsSnapshot(
                sampledAt: now,
                appPID: appPID,
                allProcesses: allProcesses,
                appTreeProcesses: appTreeProcesses,
                appTreeTotals: Self.totals(for: appTreeProcesses),
                workspaceProcesses: workspaceProcesses,
                workspaceTotals: Self.totals(for: workspaceProcesses),
                errorMessage: nil
            )
            snapshots.append(snapshot)
            lastErrorMessage = nil
            trimHistory(relativeTo: now)
            return snapshot
        } catch {
            lastErrorMessage = String(describing: error)
            if let latest = snapshots.last {
                let failedSnapshot = RuntimeDiagnosticsSnapshot(
                    sampledAt: latest.sampledAt,
                    appPID: latest.appPID,
                    allProcesses: latest.allProcesses,
                    appTreeProcesses: latest.appTreeProcesses,
                    appTreeTotals: latest.appTreeTotals,
                    workspaceProcesses: latest.workspaceProcesses,
                    workspaceTotals: latest.workspaceTotals,
                    errorMessage: lastErrorMessage
                )
                snapshots[snapshots.count - 1] = failedSnapshot
                return failedSnapshot
            }
            return RuntimeDiagnosticsSnapshot(
                sampledAt: now,
                appPID: appPID,
                allProcesses: [],
                appTreeProcesses: [],
                appTreeTotals: .empty,
                workspaceProcesses: [],
                workspaceTotals: .empty,
                errorMessage: lastErrorMessage
            )
        }
    }

    public func history(duration: TimeInterval) -> RuntimeProcessHistory {
        let cutoff = clock().addingTimeInterval(-duration)
        return RuntimeProcessHistory(
            snapshots: snapshots.filter { $0.sampledAt >= cutoff }
        )
    }

    public func latestSnapshot() -> RuntimeDiagnosticsSnapshot? {
        snapshots.last
    }

    public func reset() {
        snapshots = []
        lastErrorMessage = nil
    }

    public static func rescopeWorkspaceProcesses(
        in snapshot: RuntimeDiagnosticsSnapshot,
        workspaceDirectories: [URL]
    ) -> RuntimeDiagnosticsSnapshot {
        let workspaceProcesses = workspaceProcesses(
            from: snapshot.allProcesses,
            workspaceDirectories: workspaceDirectories
        )

        return RuntimeDiagnosticsSnapshot(
            sampledAt: snapshot.sampledAt,
            appPID: snapshot.appPID,
            allProcesses: snapshot.allProcesses,
            appTreeProcesses: snapshot.appTreeProcesses,
            appTreeTotals: snapshot.appTreeTotals,
            workspaceProcesses: workspaceProcesses,
            workspaceTotals: totals(for: workspaceProcesses),
            errorMessage: snapshot.errorMessage
        )
    }

    public static func totals(for processes: [RuntimeProcessSample]) -> RuntimeResourceTotals {
        RuntimeResourceTotals(
            processCount: processes.count,
            cpuPercent: processes.map(\.cpuPercent).reduce(0, +),
            residentMemoryBytes: processes.map(\.residentMemoryBytes).reduce(0, +),
            cpuTimeSeconds: processes.map(\.cpuTimeSeconds).reduce(0, +)
        )
    }

    public static func appTreeProcesses(
        from processes: [RuntimeProcessSample],
        rootPID: Int32
    ) -> [RuntimeProcessSample] {
        let childrenByParent = Dictionary(grouping: processes, by: \.parentPID)
        var includedPIDs: Set<Int32> = []
        var stack = [rootPID]

        while let pid = stack.popLast() {
            guard includedPIDs.insert(pid).inserted else { continue }
            for child in childrenByParent[pid] ?? [] {
                stack.append(child.pid)
            }
        }

        return
            processes
            .filter { includedPIDs.contains($0.pid) }
            .sorted { lhs, rhs in
                if lhs.pid == rootPID { return true }
                if rhs.pid == rootPID { return false }
                return lhs.pid < rhs.pid
            }
    }

    public static func workspaceProcesses(
        from processes: [RuntimeProcessSample],
        workspaceDirectories: [URL]
    ) -> [RuntimeProcessSample] {
        let prefixes =
            workspaceDirectories
            .map { normalizedPath($0.path) }
            .filter { !$0.isEmpty }

        guard !prefixes.isEmpty else { return [] }

        return processes.filter { process in
            guard let currentDirectory = process.currentDirectory else { return false }
            let normalizedDirectory = normalizedPath(currentDirectory)
            return prefixes.contains { prefix in
                normalizedDirectory == prefix || normalizedDirectory.hasPrefix(prefix + "/")
            }
        }
        .sorted { lhs, rhs in
            if lhs.cpuPercent != rhs.cpuPercent {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func trimHistory(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-maxHistoryDuration)
        snapshots.removeAll { $0.sampledAt < cutoff }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
