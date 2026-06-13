//
//  PerfChannel2Tests.swift
//  WorkspaceManagerTests
//
//  In-process perf scenario for the status-line forwarder route. Mirrors the
//  Scenario A pattern from PerfChannel1Tests; differences are: the URL path
//  is `/statusline`, the body is a status-line payload, and we measure the
//  same two metrics (HTTP 200 latency, registry update latency).
//

import Combine
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite(
    "PerfChannel2",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["WORKSPACES_PERF_RUN"] == "1")
)
struct PerfChannel2Tests {

    private static func tempSocket() -> URL {
        URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("wm-perf-c2-\(UUID().uuidString.prefix(8)).sock")
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

    @discardableResult
    private static func rawPost(
        socket: String,
        path: String,
        body: Data,
        hostSessionID: UUID? = nil
    ) -> (Date, Date) {
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
        if let hostSessionID {
            head += "X-WorkSpaces-Host-Session-ID: \(hostSessionID.uuidString)\r\n"
        }
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
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
        }
        return (sent, Date())
    }

    /// Scenario A clone for /statusline. 1000 status-line POSTs, parallelism=8.
    /// Far above realistic 1 Hz × N sessions to expose any allocator regressions.
    @Test("channel2_statusline_burst: 1000 statusline POSTs, parallelism=8")
    func statusLineBurst() async throws {
        let cwd = "/tmp/perf-c2-\(UUID().uuidString.prefix(6))"
        try? FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let registry = await AgentSessionRegistry()
        let hostID = UUID()
        await MainActor.run {
            registry.register(hostSessionID: hostID, cwd: cwd, kind: .claudeCode)
        }

        let socket = Self.tempSocket()
        let listener = AgentHookListener(
            bundleIdentifier: "com.test.perf-c2",
            registry: registry,
            socketURLOverride: socket,
            logger: { _ in }
        )
        try await listener.start()
        defer { Task { await listener.stop() } }
        try await Task.sleep(nanoseconds: 250_000_000)

        let totalEvents = 1000
        let parallelism = 8
        let socketPath = socket.path

        let updateTimestamps = LockedArrayC2<Date>()
        let cancellable = await MainActor.run {
            registry.$statuses
                .dropFirst()
                .sink { _ in updateTimestamps.append(Date()) }
        }
        defer { cancellable.cancel() }

        // Bind via SessionStart so /statusline resolves cheaply via agentSessionID.
        let bind: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "burst-c2",
            "cwd": cwd,
        ]
        _ = Self.rawPost(
            socket: socketPath, path: "/event",
            body: try JSONSerialization.data(withJSONObject: bind),
            hostSessionID: hostID
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        updateTimestamps.reset()

        // Build N varied status-line bodies — vary cost so each ingest mutates state.
        let bodies: [Data] = (0..<totalEvents).map { i in
            let body: [String: Any] = [
                "session_id": "burst-c2",
                "workspace": ["current_dir": cwd],
                "model": ["display_name": "Claude Sonnet 4.5"],
                "context_window": ["used_percentage": Double(i % 100)],
                "cost": ["total_cost_usd": Double(i) * 0.001],
                "rate_limits": [
                    "five_hour": ["used_percentage": Double(i % 100)]
                ],
            ]
            return try! JSONSerialization.data(withJSONObject: body)
        }

        let httpLatencies = LockedArrayC2<Double>()
        let sendTimestamps = LockedArrayC2<Date>()

        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            let perWorker = totalEvents / parallelism
            for w in 0..<parallelism {
                let lo = w * perWorker
                let hi = (w == parallelism - 1) ? totalEvents : lo + perWorker
                group.addTask {
                    for i in lo..<hi {
                        let (sent, ack) = Self.rawPost(
                            socket: socketPath,
                            path: "/statusline",
                            body: bodies[i],
                            hostSessionID: hostID
                        )
                        sendTimestamps.append(sent)
                        httpLatencies.append(ack.timeIntervalSince(sent) * 1000)
                    }
                }
            }
        }
        let httpDoneAt = Date()

        let deadline = Date().addingTimeInterval(5.0)
        while updateTimestamps.count < totalEvents && Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let updates = updateTimestamps.snapshot()
        let sends = sendTimestamps.snapshot().sorted()

        let pairCount = min(sends.count, updates.count)
        let registryLatencies: [Double] = (0..<pairCount).map { i in
            updates[i].timeIntervalSince(sends[i]) * 1000
        }

        let httpStats = Self.summarize(httpLatencies.snapshot())
        let regStats = Self.summarize(registryLatencies)

        let payload: [String: Any] = [
            "scenario": "channel2_statusline_burst",
            "events_sent": totalEvents,
            "parallelism": parallelism,
            "events_observed": updates.count,
            "wall_clock_ms": httpDoneAt.timeIntervalSince(started) * 1000,
            "metrics": [
                "channel2_statusline_http_200_latency_ms": httpStats,
                "channel2_statusline_registry_update_latency_ms": regStats,
            ],
        ]
        try Self.writeResult(payload, to: Self.resultPath(scenario: "channel2_statusline_burst"))

        #expect(updates.count >= Int(Double(totalEvents) * 0.95))
    }
}

// Local copy of the lock-protected array helper from PerfChannel1Tests, kept
// internal to avoid cross-file linkage just for a test utility.
private final class LockedArrayC2<T: Sendable>: @unchecked Sendable {
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
        items.removeAll()
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
