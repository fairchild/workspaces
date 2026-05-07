//
//  PerfChannel1Tests.swift
//  WorkspaceManagerTests
//
//  In-process perf scenarios for the Channel 1 hook stack. Opt-in via
//  WORKSPACES_PERF_RUN=1 so they don't run on every `swift test`. Each scenario
//  writes a result.json file to WORKSPACES_PERF_OUT (or a temp path) in the
//  shape:
//
//      {
//        "scenario": "channel1_ingest_burst",
//        "samples": <int>,
//        "metrics": {
//          "<metric_name>": { "median_ms": .., "p95_ms": .., "p99_ms": .., "max_ms": .. },
//          ...
//        }
//      }
//
//  These tests exercise the in-process path through AgentHookListener +
//  AgentSessionRegistry over a real Unix socket — same code path that the live
//  app uses, minus the SwiftUI binding layer.
//

import Combine
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite(
    "PerfChannel1",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["WORKSPACES_PERF_RUN"] == "1")
)
struct PerfChannel1Tests {

    // MARK: - Helpers

    private static func tempSocket() -> URL {
        URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("wm-perf-\(UUID().uuidString.prefix(8)).sock")
    }

    private static func resultPath(scenario: String) -> URL {
        if let override = ProcessInfo.processInfo.environment["WORKSPACES_PERF_OUT"] {
            return URL(fileURLWithPath: override)
        }
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("workspaces-perf-\(scenario)-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("result.json")
    }

    private static func writeResult(_ payload: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    private static func percentile(_ samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let idx = Int((p / 100.0) * Double(sorted.count - 1))
        return sorted[max(0, min(sorted.count - 1, idx))]
    }

    private static func summarize(_ samples: [Double]) -> [String: Double] {
        [
            "median_ms": percentile(samples, 50),
            "p95_ms": percentile(samples, 95),
            "p99_ms": percentile(samples, 99),
            "max_ms": samples.max() ?? 0,
            "mean_ms": samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count),
        ]
    }

    /// Drive a POST against the Unix socket using a low-level raw fd write so we
    /// don't pay `Process.run()` startup cost for each request.
    @discardableResult
    private static func rawPost(
        socket: String, path: String, body: Data
    ) -> (
        sent: Date, ack: Date
    ) {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(fd >= 0, "socket() failed")
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socket.utf8)
        precondition(pathBytes.count < 104, "socket path too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }
        let connected = withUnsafePointer(to: &addr) { aptr -> Int32 in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sptr in
                Darwin.connect(fd, sptr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        precondition(connected == 0, "connect() failed errno=\(errno)")

        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)

        let sent = Date()
        out.withUnsafeBytes { raw in
            var remaining = out.count
            var ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            while remaining > 0 {
                let n = Darwin.send(fd, ptr, remaining, 0)
                if n <= 0 { break }
                remaining -= n
                ptr = ptr.advanced(by: n)
            }
        }
        // Read until EOF (server sends 200 OK then closes).
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
        }
        let ack = Date()
        return (sent, ack)
    }

    // MARK: - Scenario A: ingest burst

    @Test("channel1_ingest_burst: 1000 PreToolUse events, parallelism=8")
    func ingestBurst() async throws {
        let cwd = "/tmp/perf-burst-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let registry = await AgentSessionRegistry()
        let hostID = UUID()
        await MainActor.run {
            registry.register(hostSessionID: hostID, cwd: cwd, kind: .claudeCode)
        }

        let socket = Self.tempSocket()
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.perf",
            registry: registry,
            socketURLOverride: socket,
            logger: { _ in }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }

        // Allow the NWListener to reach .ready.
        try await Task.sleep(nanoseconds: 250_000_000)

        let totalEvents = 1000
        let parallelism = 8
        let socketPath = socket.path

        // Subscribe to lastEventAt mutations on the registry to time end-to-end.
        // We index by event sequence: the registry's lastEventAt is monotone
        // bumped each ingest, so we record `Date()` at every observed change and
        // pair them with sends in send-order.
        let updateTimestamps = LockedArray<Date>()
        let cancellable = await MainActor.run {
            registry.$statuses
                .dropFirst()  // skip initial register()
                .sink { _ in
                    updateTimestamps.append(Date())
                }
        }
        defer { cancellable.cancel() }

        // Build event bodies up front (ignore JSON encode time).
        let bodies: [Data] = (0..<totalEvents).map { i in
            let body: [String: Any] = [
                "hook_event_name": "PreToolUse",
                "session_id": "burst-session",
                "cwd": cwd,
                "tool_name": "Read",
                "tool_input": ["file_path": "/tmp/x-\(i).swift"],
            ]
            return try! JSONSerialization.data(withJSONObject: body)
        }

        let httpLatencies = LockedArray<Double>()
        let sendTimestamps = LockedArray<Date>()

        // Bind a SessionStart first to attach agent_session_id (so ingestion
        // doesn't keep walking the cwd resolver).
        let bindBody: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "burst-session",
            "cwd": cwd,
        ]
        let bindData = try JSONSerialization.data(withJSONObject: bindBody)
        _ = Self.rawPost(socket: socketPath, path: "/event", body: bindData)
        try await Task.sleep(nanoseconds: 100_000_000)
        // Reset update timestamps after bind.
        updateTimestamps.reset()

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            let perWorker = totalEvents / parallelism
            for w in 0..<parallelism {
                let lo = w * perWorker
                let hi = (w == parallelism - 1) ? totalEvents : lo + perWorker
                group.addTask {
                    for i in lo..<hi {
                        let (sent, ack) = Self.rawPost(
                            socket: socketPath, path: "/event", body: bodies[i]
                        )
                        sendTimestamps.append(sent)
                        httpLatencies.append(ack.timeIntervalSince(sent) * 1000)
                    }
                }
            }
        }
        let httpDoneAt = Date()

        // Wait up to 5s for all 1000 mutations to land.
        let deadline = Date().addingTimeInterval(5.0)
        while updateTimestamps.count < totalEvents && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let updates = updateTimestamps.snapshot()
        let sends = sendTimestamps.snapshot().sorted()
        let ackEnd = httpDoneAt

        // Pair sends to updates in order. Fewer updates than sends is a finding.
        let pairCount = min(sends.count, updates.count)
        let registryLatencies: [Double] = (0..<pairCount).map { i in
            updates[i].timeIntervalSince(sends[i]) * 1000
        }

        let httpStats = Self.summarize(httpLatencies.snapshot())
        let regStats = Self.summarize(registryLatencies)

        let payload: [String: Any] = [
            "scenario": "channel1_ingest_burst",
            "events_sent": totalEvents,
            "parallelism": parallelism,
            "events_observed": updates.count,
            "wall_clock_ms": ackEnd.timeIntervalSince(started) * 1000,
            "metrics": [
                "channel1_ingest_http_200_latency_ms": httpStats,
                "channel1_ingest_registry_update_latency_ms": regStats,
            ],
        ]
        try Self.writeResult(payload, to: Self.resultPath(scenario: "channel1_ingest_burst"))

        // Sanity assertion: we received >= 95% of events.
        #expect(updates.count >= Int(Double(totalEvents) * 0.95))
    }

    // MARK: - Scenario C: long session register/deregister symmetry

    @Test("channel1_long_session_memory: register/deregister symmetry")
    func longSessionRegistrySymmetry() async throws {
        let durationSec =
            Double(
                ProcessInfo.processInfo.environment["WORKSPACES_PERF_LONG_SECONDS"] ?? "60"
            ) ?? 60
        let registry = await AgentSessionRegistry()
        let socket = Self.tempSocket()
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.perf",
            registry: registry,
            socketURLOverride: socket,
            logger: { _ in }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let started = Date()
        var iterations = 0
        var rssSamples: [Int64] = []
        rssSamples.append(Self.processRSSKB())
        let rssEvery = max(1, Int(durationSec / 10))

        while Date().timeIntervalSince(started) < durationSec {
            let cwd = "/tmp/perf-long-\(iterations)"
            try? FileManager.default.createDirectory(
                atPath: cwd, withIntermediateDirectories: true
            )
            let hostID = UUID()
            await MainActor.run {
                registry.register(hostSessionID: hostID, cwd: cwd, kind: .claudeCode)
            }
            // Drive 30 events.
            for i in 0..<30 {
                let body: [String: Any] = [
                    "hook_event_name": (i % 4 == 0) ? "PostToolUse" : "PreToolUse",
                    "session_id": "long-\(iterations)",
                    "cwd": cwd,
                    "tool_name": "Read",
                    "tool_input": ["file_path": "/tmp/x.swift"],
                ]
                _ = Self.rawPost(
                    socket: socket.path, path: "/event",
                    body: try JSONSerialization.data(withJSONObject: body))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            await MainActor.run { registry.deregister(hostSessionID: hostID) }
            try? FileManager.default.removeItem(atPath: cwd)

            iterations += 1
            if iterations % rssEvery == 0 {
                rssSamples.append(Self.processRSSKB())
            }
        }
        rssSamples.append(Self.processRSSKB())
        let registrySize = await MainActor.run { registry.statuses.count }

        let rssDeltaKB = (rssSamples.last ?? 0) - (rssSamples.first ?? 0)
        let payload: [String: Any] = [
            "scenario": "channel1_long_session_memory",
            "duration_seconds": durationSec,
            "iterations": iterations,
            "registry_size_after_close": registrySize,
            "rss_kb_first": rssSamples.first ?? 0,
            "rss_kb_last": rssSamples.last ?? 0,
            "rss_delta_kb": rssDeltaKB,
            "rss_delta_mb": Double(rssDeltaKB) / 1024.0,
            "rss_samples_kb": rssSamples,
            "metrics": [
                "channel1_long_session_rss_delta_mb": [
                    "value": Double(rssDeltaKB) / 1024.0
                ],
                "channel1_registry_size_after_close": [
                    "value": Double(registrySize)
                ],
            ],
        ]
        try Self.writeResult(
            payload, to: Self.resultPath(scenario: "channel1_long_session_memory"))

        #expect(registrySize == 0)
    }

    // MARK: - Scenario B: steady-state churn (8 sessions, 40 ev/s, 60s)

    @Test("channel1_sidebar_churn: 8 sessions, 40 ev/s, 60s")
    func sidebarChurn() async throws {
        let durationSec =
            Double(
                ProcessInfo.processInfo.environment["WORKSPACES_PERF_CHURN_SECONDS"] ?? "60"
            ) ?? 60
        let sessionCount = 8
        let aggregateRate = 40.0  // events/sec total

        let registry = await AgentSessionRegistry()
        var hostIDs: [UUID] = []
        for i in 0..<sessionCount {
            let cwd = "/tmp/perf-churn-\(i)"
            try? FileManager.default.createDirectory(
                atPath: cwd, withIntermediateDirectories: true)
            let id = UUID()
            await MainActor.run {
                registry.register(hostSessionID: id, cwd: cwd, kind: .claudeCode)
            }
            hostIDs.append(id)
        }
        defer {
            for i in 0..<sessionCount {
                try? FileManager.default.removeItem(atPath: "/tmp/perf-churn-\(i)")
            }
        }

        let socket = Self.tempSocket()
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.perf",
            registry: registry,
            socketURLOverride: socket,
            logger: { _ in }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let cpuSamples = LockedArray<Double>()
        let rssSamples = LockedArray<Int64>()
        let pid = getpid()
        let samplerStop = LockedFlag()
        let samplerTask = Task.detached {
            while !samplerStop.isSet() {
                let (cpu, rss) = Self.sampleProcessCPURSS(pid: pid)
                cpuSamples.append(cpu)
                rssSamples.append(rss)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        let started = Date()
        let intervalNS = UInt64(1_000_000_000.0 / aggregateRate)
        var event = 0
        // Mix: 60% Pre, 25% Post, 10% UserPrompt, 5% PermissionRequest
        let eventNames = (0..<100).map { i -> String in
            switch i {
            case 0..<60: return "PreToolUse"
            case 60..<85: return "PostToolUse"
            case 85..<95: return "UserPromptSubmit"
            default: return "PermissionRequest"
            }
        }
        while Date().timeIntervalSince(started) < durationSec {
            let s = event % sessionCount
            let cwd = "/tmp/perf-churn-\(s)"
            let body: [String: Any] = [
                "hook_event_name": eventNames[event % 100],
                "session_id": "churn-\(s)",
                "cwd": cwd,
                "tool_name": "Read",
                "tool_input": ["file_path": "/tmp/x.swift"],
            ]
            let data = try JSONSerialization.data(withJSONObject: body)
            _ = Self.rawPost(socket: socket.path, path: "/event", body: data)
            event += 1
            try await Task.sleep(nanoseconds: intervalNS)
        }
        samplerStop.set()
        _ = await samplerTask.value

        let cpus = cpuSamples.snapshot()
        let rsses = rssSamples.snapshot()
        let cpuStats = Self.summarize(cpus)
        let rssDeltaMB =
            rsses.isEmpty
            ? 0.0
            : Double((rsses.last ?? 0) - (rsses.first ?? 0)) / 1024.0

        let payload: [String: Any] = [
            "scenario": "channel1_sidebar_churn",
            "duration_seconds": durationSec,
            "events_sent": event,
            "session_count": sessionCount,
            "cpu_samples": cpus,
            "rss_samples_kb": rsses,
            "metrics": [
                "channel1_steady_state_cpu_percent": [
                    "median": cpuStats["median_ms"] ?? 0,
                    "p95": cpuStats["p95_ms"] ?? 0,
                    "max": cpuStats["max_ms"] ?? 0,
                    "mean": cpuStats["mean_ms"] ?? 0,
                ],
                "channel1_steady_state_rss_delta_mb": [
                    "value": rssDeltaMB
                ],
            ],
        ]
        try Self.writeResult(payload, to: Self.resultPath(scenario: "channel1_sidebar_churn"))
    }

    // MARK: - Risk: backup file accumulation

    @Test("risk_backup_accumulation: 10 installs leave 5 backups (rotation active)")
    func backupAccumulation() async throws {
        let homeDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("perf-backup-home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDir) }

        let installer = ClaudeSettingsInstaller(homeDirectory: homeDir)
        await installer.register(
            workspacesHooksContribution(socketPath: "/tmp/perf-backup.sock")
        )

        // Seed an existing settings.json so each install writes a backup.
        let settingsPath = homeDir.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\n  \"hooks\": {}\n}".utf8).write(to: settingsPath)

        for _ in 0..<10 {
            try await installer.install()
            // Mutate so next install creates a backup again.
            try Data("{\n  \"hooks\": {}\n}".utf8).write(to: settingsPath)
            // Sleep for ~10ms so timestamps differ.
            try await Task.sleep(nanoseconds: 12_000_000)
        }

        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: homeDir.appendingPathComponent(".claude"),
                includingPropertiesForKeys: nil
            )) ?? []
        let backups = entries.filter { $0.path.contains("workspaces-backup-") }

        let payload: [String: Any] = [
            "scenario": "channel1_risk_backup_accumulation",
            "backups_retained": backups.count,
            "backup_paths": backups.map(\.path),
            "rotation_active": true,
            "metrics": [
                "channel1_backup_files_retained": [
                    "value": Double(backups.count)
                ]
            ],
        ]
        try Self.writeResult(
            payload, to: Self.resultPath(scenario: "channel1_risk_backup_accumulation"))

        // Channel 3 mitigation: backup rotation is now active. After 10 installs
        // we expect exactly `maxBackupsPerFile` backups on disk (the newest 5),
        // not 10. Asserts both the cap and the rotation-on guarantee.
        #expect(backups.count == ClaudeSettingsInstaller.maxBackupsPerFile)
        #expect(backups.count == 5)
    }

    // MARK: - Risk: malformed settings.json

    @Test("risk_malformed_settings: renderPreview tolerates broken JSON")
    func malformedSettings() async throws {
        let homeDir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("perf-malformed-home-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: homeDir) }
        let settingsPath = homeDir.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let cases: [(String, String)] = [
            ("comment_style", "// hi\n{\n  \"hooks\": {}\n}\n"),
            ("unquoted_key", "{ hooks: {} }"),
            ("array_for_object", "{ \"hooks\": [1, 2, 3] }"),
            ("trailing_comma", "{ \"hooks\": {}, }"),
            ("empty", ""),
        ]
        var outcomes: [[String: Any]] = []
        for (label, content) in cases {
            try Data(content.utf8).write(to: settingsPath)
            let installer = ClaudeSettingsInstaller(homeDirectory: homeDir)
            await installer.register(
                workspacesHooksContribution(socketPath: "/tmp/m.sock")
            )
            var renderError: String? = nil
            var rendered: String? = nil
            do {
                rendered = try await installer.renderPreview()
            } catch {
                renderError = "\(error)"
            }
            var installError: String? = nil
            do {
                try await installer.install()
            } catch {
                installError = "\(error)"
            }
            outcomes.append([
                "case": label,
                "render_error": renderError ?? "",
                "render_first_line": rendered?.split(separator: "\n").first.map(String.init) ?? "",
                "install_error": installError ?? "",
            ])
        }

        let payload: [String: Any] = [
            "scenario": "channel1_risk_malformed_settings",
            "cases": outcomes,
        ]
        try Self.writeResult(
            payload, to: Self.resultPath(scenario: "channel1_risk_malformed_settings"))
    }

    // MARK: - Risk: stale socket sweep

    @Test("risk_stale_socket_sweep: orphan socket from a dead pid is removed on next start")
    func staleSocketSweep() async throws {
        let dir = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("perf-sweep-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Plant a socket file owned by a definitely-dead pid.
        let deadPid = 999_998
        let stale = dir.appendingPathComponent("hooks-\(deadPid).sock")
        try Data().write(to: stale)
        // Plant another with our pid (alive) — must NOT be swept.
        let alivePid = getpid()
        let alive = dir.appendingPathComponent("hooks-\(alivePid).sock")
        try Data().write(to: alive)
        // Plant a non-numeric name — should be swept.
        let bogus = dir.appendingPathComponent("hooks-bogus.sock")
        try Data().write(to: bogus)

        let registry = await AgentSessionRegistry()
        // Use a different socket path inside `dir` so the listener triggers the
        // sweep on parent dir.
        let listenerSocket = dir.appendingPathComponent("hooks-\(alivePid)-test.sock")
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.perf",
            registry: registry,
            socketURLOverride: listenerSocket,
            logger: { _ in }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }

        let staleStillExists = FileManager.default.fileExists(atPath: stale.path)
        let aliveStillExists = FileManager.default.fileExists(atPath: alive.path)
        let bogusStillExists = FileManager.default.fileExists(atPath: bogus.path)

        let payload: [String: Any] = [
            "scenario": "channel1_risk_stale_socket_sweep",
            "stale_pid_socket_present": staleStillExists,
            "alive_pid_socket_present": aliveStillExists,
            "bogus_named_socket_present": bogusStillExists,
        ]
        try Self.writeResult(
            payload, to: Self.resultPath(scenario: "channel1_risk_stale_socket_sweep"))

        #expect(!staleStillExists, "stale socket from dead pid should have been swept")
        #expect(aliveStillExists, "live pid's socket must NOT be swept")
        #expect(!bogusStillExists, "non-numeric pid socket should have been swept")
    }

    // MARK: - Risk: race — events queued after deregister

    @Test("risk_race_events_after_deregister: ingest no-ops, no crash")
    func raceEventsAfterDeregister() async throws {
        let cwd = "/tmp/perf-race-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let registry = await AgentSessionRegistry()
        let hostID = UUID()
        await MainActor.run {
            registry.register(hostSessionID: hostID, cwd: cwd, kind: .claudeCode)
        }

        let socket = Self.tempSocket()
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.perf",
            registry: registry,
            socketURLOverride: socket,
            logger: { _ in }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        // Bind a session id.
        let bind: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "race-1",
            "cwd": cwd,
        ]
        _ = Self.rawPost(
            socket: socket.path, path: "/event",
            body: try JSONSerialization.data(withJSONObject: bind))
        try await Task.sleep(nanoseconds: 100_000_000)

        // Fire 200 events then deregister mid-flight.
        let totalEvents = 200
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        for i in 0..<totalEvents {
            group.enter()
            queue.async {
                let body: [String: Any] = [
                    "hook_event_name": "PreToolUse",
                    "session_id": "race-1",
                    "cwd": cwd,
                    "tool_name": "Read",
                    "tool_input": ["file_path": "/tmp/x-\(i).swift"],
                ]
                _ = Self.rawPost(
                    socket: socket.path, path: "/event",
                    body: try! JSONSerialization.data(withJSONObject: body))
                group.leave()
            }
            if i == 50 {
                Task { @MainActor in
                    registry.deregister(hostSessionID: hostID)
                }
            }
        }
        group.wait()
        try await Task.sleep(nanoseconds: 250_000_000)
        let remaining = await MainActor.run { registry.statuses.count }

        let payload: [String: Any] = [
            "scenario": "channel1_risk_race_events_after_deregister",
            "events_sent": totalEvents,
            "registry_size_after": remaining,
            "no_crash": true,
        ]
        try Self.writeResult(
            payload, to: Self.resultPath(scenario: "channel1_risk_race_events_after_deregister"))

        #expect(remaining == 0)
    }

    // MARK: - Process sampling

    private static func processRSSKB() -> Int64 {
        // Use mach task_info for the running process — same answer as ps but no fork.
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        if kerr == KERN_SUCCESS {
            return Int64(info.resident_size) / 1024
        }
        return 0
    }

    /// Sample CPU% and RSS in KB via `ps`. Roughly 1 fork per second is fine.
    private static func sampleProcessCPURSS(pid: pid_t) -> (cpu: Double, rss: Int64) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", "\(pid)", "-o", "%cpu=,rss="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (0, 0) }
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let line = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return (0, processRSSKB()) }
        return (Double(parts[0]) ?? 0, Int64(parts[1]) ?? 0)
    }
}

// MARK: - Lock-friendly storage for concurrent collectors

final class LockedArray<T: Sendable>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()
    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll(keepingCapacity: true)
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
    func snapshot() -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

final class LockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }
    func isSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
