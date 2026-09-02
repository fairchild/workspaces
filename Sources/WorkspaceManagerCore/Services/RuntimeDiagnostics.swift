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
    /// When the kernel recorded this process starting, when it could be read.
    /// A pid alone does not identify a process across samples — pids are reused —
    /// so anything that carries state between samples, or sends a signal, pairs
    /// the pid with this.
    public let startedAt: Date?

    public init(
        pid: Int32,
        parentPID: Int32,
        name: String,
        command: String,
        cpuPercent: Double,
        residentMemoryBytes: Int64,
        cpuTimeSeconds: TimeInterval = 0,
        currentDirectory: String? = nil,
        startedAt: Date? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.command = command
        self.cpuPercent = cpuPercent
        self.residentMemoryBytes = residentMemoryBytes
        self.cpuTimeSeconds = cpuTimeSeconds
        self.currentDirectory = currentDirectory
        self.startedAt = startedAt
    }

    /// Pid plus start time: the pair that survives pid reuse.
    public var identity: RuntimeProcessIdentity {
        RuntimeProcessIdentity(pid: pid, startedAt: startedAt)
    }
}

/// Names one running process across samples. A pid on its own does not: the
/// kernel reuses them, and a reused pid inheriting a predecessor's growth history
/// produces a false alert, while one inheriting its stop request kills a
/// bystander.
public struct RuntimeProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let startedAt: Date?

    public init(pid: Int32, startedAt: Date?) {
        self.pid = pid
        self.startedAt = startedAt
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

/// Reads the process table through `libproc` and `sysctl` — no `ps`, no `lsof`,
/// no subprocess at all (#1368). A sweep that spawns nothing is cheap enough to
/// run on a background cadence whether or not the Diagnostics pane is open,
/// which is what makes a runaway visible before the kernel acts on it.
public struct LiveRuntimeProcessSnapshotProvider: RuntimeProcessSnapshotProviding {
    private let snapshot: @Sendable (Date) -> [ProcessInventoryEntry]
    private let clock: @Sendable () -> Date

    public init() {
        self.init(
            snapshot: { ProcessInventory.hostSnapshot(now: $0) },
            clock: { Date() }
        )
    }

    init(
        snapshot: @escaping @Sendable (Date) -> [ProcessInventoryEntry],
        clock: @escaping @Sendable () -> Date
    ) {
        self.snapshot = snapshot
        self.clock = clock
    }

    public func processes() async throws -> [RuntimeProcessSample] {
        snapshot(clock()).map(Self.sample(from:))
    }

    /// Maps one kernel-level entry onto the sample shape the pane renders.
    ///
    /// `residentMemoryBytes` carries physical footprint, as it has since #1347
    /// D1: `ps rss` excludes compressed pages and graphics memory and
    /// under-reported this app about 9x against Activity Monitor. `cpuPercent`
    /// is the share of one core the process has averaged over its life —
    /// `ps`'s own `%cpu` is a decaying scheduler estimate, and the long-run
    /// figure is both reproducible and the one a runaway is judged on.
    static func sample(from entry: ProcessInventoryEntry) -> RuntimeProcessSample {
        RuntimeProcessSample(
            pid: entry.pid,
            parentPID: entry.parentPID,
            name: entry.name,
            command: entry.commandLine ?? entry.name,
            cpuPercent: entry.lifetimeCPUPercent,
            residentMemoryBytes: entry.footprintBytes,
            cpuTimeSeconds: entry.cpuTimeSeconds,
            currentDirectory: entry.currentDirectory,
            startedAt: entry.startedAt
        )
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

public actor RuntimeDiagnosticsSampler {
    public static let shared = RuntimeDiagnosticsSampler()

    private let provider: any RuntimeProcessSnapshotProviding
    private let processIdentifier: @Sendable () -> Int32
    private let clock: @Sendable () -> Date
    private let minimumSampleInterval: TimeInterval
    private let maxHistoryDuration: TimeInterval
    private let fullSnapshotRetention: Int
    private let alertPolicy: RuntimeProcessAlertPolicy

    private var snapshots: [RuntimeDiagnosticsSnapshot] = []
    private var growth = RuntimeProcessGrowthLedger()
    private var muted: Set<RuntimeProcessIdentity> = []
    private var lastErrorMessage: String?
    /// The scope the pane last supplied. The always-on sweep has no view of the
    /// model store, so it samples against whatever scope was last set rather than
    /// against nothing — sampling against nothing would drop every
    /// workspace-scoped process from the growth ledger on the next sweep.
    private var workspaceScope: [URL] = []
    /// The one sweep allowed to be in flight. This actor suspends at the
    /// provider `await`, so without this the pane's 5 s poll and the watchdog's
    /// 30 s poll can both pass the interval check and land out of order, leaving
    /// `latestSnapshot()` stale and the growth window running backwards.
    private var inFlight: Task<RuntimeDiagnosticsSnapshot?, Never>?
    /// Last CPU-time reading per process, for the sampled rate.
    private var previousCPUTime: [RuntimeProcessIdentity: (seconds: TimeInterval, at: Date)] = [:]

    public init(
        provider: any RuntimeProcessSnapshotProviding = LiveRuntimeProcessSnapshotProvider(),
        processIdentifier: @escaping @Sendable () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        clock: @escaping @Sendable () -> Date = { Date() },
        minimumSampleInterval: TimeInterval = 5,
        maxHistoryDuration: TimeInterval = 3_600,
        fullSnapshotRetention: Int = 1,
        alertPolicy: RuntimeProcessAlertPolicy = .default
    ) {
        self.provider = provider
        self.processIdentifier = processIdentifier
        self.clock = clock
        self.minimumSampleInterval = minimumSampleInterval
        self.maxHistoryDuration = maxHistoryDuration
        self.fullSnapshotRetention = fullSnapshotRetention
        self.alertPolicy = alertPolicy
    }

    /// Samples unless one is recent enough. `workspaceDirectories` is nil for a
    /// caller with no view of the model store — the always-on watchdog — which
    /// then samples against the scope the pane last set.
    public func sampleIfNeeded(workspaceDirectories: [URL]?) async -> RuntimeDiagnosticsSnapshot? {
        let now = clock()
        if let latest = snapshots.last,
            now.timeIntervalSince(latest.sampledAt) < minimumSampleInterval
        {
            if let workspaceDirectories { workspaceScope = workspaceDirectories }
            return latest
        }
        return await sample(workspaceDirectories: workspaceDirectories)
    }

    @discardableResult
    public func sample(workspaceDirectories: [URL]?) async -> RuntimeDiagnosticsSnapshot? {
        if let workspaceDirectories { workspaceScope = workspaceDirectories }

        if let inFlight {
            return await inFlight.value
        }
        let task = Task<RuntimeDiagnosticsSnapshot?, Never> { [self] in
            await performSample()
        }
        inFlight = task
        let snapshot = await task.value
        inFlight = nil
        return snapshot
    }

    private func performSample() async -> RuntimeDiagnosticsSnapshot? {
        let now = clock()
        let appPID = processIdentifier()
        let workspaceDirectories = workspaceScope

        do {
            let allProcesses = Self.overlayingSampledCPU(
                try await provider.processes(),
                previous: previousCPUTime,
                now: now
            )
            previousCPUTime = Dictionary(
                allProcesses.map { ($0.identity, (seconds: $0.cpuTimeSeconds, at: now)) },
                uniquingKeysWith: { _, latest in latest }
            )
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
            recordGrowth(
                appTreeProcesses: appTreeProcesses,
                workspaceProcesses: workspaceProcesses,
                at: now
            )
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

    /// Processes currently over a growth or footprint threshold.
    public func alerts() -> [RuntimeProcessAlert] {
        growth.alerts(policy: alertPolicy, muted: muted)
    }

    /// Silences one process until it is unmuted or exits. Dismissing an alert has
    /// to outlive the next sample, or the banner returns 30 seconds after the user
    /// waves it away. Keyed by identity, so a recycled pid is not born muted.
    public func mute(_ identity: RuntimeProcessIdentity) {
        muted.insert(identity)
    }

    public func unmute(_ identity: RuntimeProcessIdentity) {
        muted.remove(identity)
    }

    public func reset() {
        snapshots = []
        growth = RuntimeProcessGrowthLedger()
        muted = []
        previousCPUTime = [:]
        workspaceScope = []
        lastErrorMessage = nil
    }

    /// Replaces each process's lifetime CPU average with the share of one core it
    /// used since the previous sample.
    ///
    /// The lifetime figure is stable but answers the wrong question for a
    /// runaway: a process that idled for a day and then pinned a core reads as
    /// quiet. A first sighting keeps the lifetime figure, which is the only
    /// reading available for it.
    static func overlayingSampledCPU(
        _ samples: [RuntimeProcessSample],
        previous: [RuntimeProcessIdentity: (seconds: TimeInterval, at: Date)],
        now: Date
    ) -> [RuntimeProcessSample] {
        samples.map { sample in
            guard let last = previous[sample.identity] else { return sample }
            let elapsed = now.timeIntervalSince(last.at)
            guard elapsed > 0 else { return sample }
            let used = max(0, sample.cpuTimeSeconds - last.seconds)
            return RuntimeProcessSample(
                pid: sample.pid,
                parentPID: sample.parentPID,
                name: sample.name,
                command: sample.command,
                cpuPercent: (used / elapsed) * 100,
                residentMemoryBytes: sample.residentMemoryBytes,
                cpuTimeSeconds: sample.cpuTimeSeconds,
                currentDirectory: sample.currentDirectory,
                startedAt: sample.startedAt
            )
        }
    }

    private func recordGrowth(
        appTreeProcesses: [RuntimeProcessSample],
        workspaceProcesses: [RuntimeProcessSample],
        at sampledAt: Date
    ) {
        let descendantPIDs = Set(appTreeProcesses.map(\.pid))
        var candidates = appTreeProcesses
        candidates.append(contentsOf: workspaceProcesses.filter { !descendantPIDs.contains($0.pid) })

        growth.record(
            candidates: candidates,
            appDescendantPIDs: descendantPIDs,
            at: sampledAt,
            policy: alertPolicy
        )
        muted.formIntersection(candidates.map(\.identity))
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

    /// Drops readings past the window, and strips the per-process arrays from
    /// everything but the most recent few snapshots.
    ///
    /// The sampler now runs whether or not the pane is open, so an hour of
    /// history is an hour of every process on the host — tens of megabytes held
    /// to answer questions (`appCPUAverage`, the peaks, `latest`) that only ever
    /// read the totals and the newest snapshot. Compacting the tail keeps those
    /// answers identical and the retention flat.
    private func trimHistory(relativeTo now: Date) {
        let cutoff = now.addingTimeInterval(-maxHistoryDuration)
        snapshots.removeAll { $0.sampledAt < cutoff }

        let compactableCount = snapshots.count - max(fullSnapshotRetention, 1)
        guard compactableCount > 0 else { return }
        for index in 0..<compactableCount where !snapshots[index].allProcesses.isEmpty {
            snapshots[index] = Self.compacted(snapshots[index])
        }
    }

    /// A snapshot reduced to its totals. `RuntimeProcessHistory` reads nothing
    /// else from anything but `latest`, which is never compacted.
    static func compacted(_ snapshot: RuntimeDiagnosticsSnapshot) -> RuntimeDiagnosticsSnapshot {
        RuntimeDiagnosticsSnapshot(
            sampledAt: snapshot.sampledAt,
            appPID: snapshot.appPID,
            allProcesses: [],
            appTreeProcesses: [],
            appTreeTotals: snapshot.appTreeTotals,
            workspaceProcesses: [],
            workspaceTotals: snapshot.workspaceTotals,
            errorMessage: snapshot.errorMessage
        )
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
