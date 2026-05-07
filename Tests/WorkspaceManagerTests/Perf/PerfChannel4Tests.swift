//
//  PerfChannel4Tests.swift
//  WorkspaceManagerTests
//
//  In-process perf scenario for Channel 4 cold-start transcript replay.
//
//  Gate (from `.context/claude-integration/perf-audit-pr443-final.md`):
//    - 10,000-record JSONL replay must complete within 25 seconds (matches the
//      ≤500 ev/s replay rate-cap floor).
//    - RSS delta must stay under 50 MB across the replay (the registry holds a
//      single AgentSessionStatus; growth above this floor would indicate the
//      ingestBatch path is leaking state).
//
//  Opt-in via WORKSPACES_PERF_RUN=1.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite(
    "PerfChannel4",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["WORKSPACES_PERF_RUN"] == "1")
)
struct PerfChannel4Tests {

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

    /// Resident set size in MB for the current process.
    private static func currentRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    ptr,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }

    private static func writeFixture(records: Int) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-perf-channel4-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")
        var lines: [String] = []
        lines.reserveCapacity(records)
        for i in 0..<records {
            let mod = i % 4
            switch mod {
            case 0:
                lines.append(#"{"type":"user","text":"prompt \#(i)"}"#)
            case 1:
                lines.append(
                    #"{"type":"tool_use","tool_name":"Read","input":{"file_path":"/tmp/\#(i)"}}"#
                )
            case 2:
                lines.append(
                    #"{"type":"tool_result","tool_name":"Read","duration_ms":\#(i % 50),"is_error":false,"text":"ok"}"#
                )
            default:
                lines.append(
                    #"{"type":"assistant","model":"claude-sonnet-5","text":"reply \#(i)"}"#
                )
            }
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("channel4_replay_10k_records")
    @MainActor
    func replay10kRecords() async throws {
        let recordCount = 10_000
        let fixture = Self.writeFixture(records: recordCount)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let registry = AgentSessionRegistry()
        let host = UUID()
        registry.register(hostSessionID: host, cwd: "/tmp/perf-channel4", kind: .claudeCode)

        let rssBeforeMB = Self.currentRSSMB()

        let runner = TranscriptColdStartRecovery(
            registry: registry,
            configuration: .init(eventsPerSecond: 500, flushSize: 64, flushIntervalMS: 16)
        )

        let started = Date()
        let outcome = await runner.replay(
            transcriptPath: fixture,
            for: host,
            agentSessionID: nil,
            kind: .claudeCode
        )
        let elapsed = Date().timeIntervalSince(started)

        let rssAfterMB = Self.currentRSSMB()
        let rssDeltaMB = rssAfterMB - rssBeforeMB

        // Hard gates from the perf audit:
        #expect(
            elapsed < 25.0,
            "replay completed in \(elapsed)s, must be < 25s for 10k records at 500 ev/s"
        )
        #expect(
            rssDeltaMB < 50.0,
            "RSS delta = \(rssDeltaMB) MB, must be < 50 MB"
        )

        // Sanity: the recovery must have processed everything.
        #expect(outcome.recordsProcessed == recordCount)

        let payload: [String: Any] = [
            "scenario": "channel4_replay_10k_records",
            "metrics": [
                "channel4_replay_completion_seconds": [
                    "value": elapsed,
                    "budget": 25.0,
                ],
                "channel4_replay_rss_delta_mb": [
                    "value": rssDeltaMB,
                    "budget": 50.0,
                ],
                "channel4_records_processed": [
                    "value": outcome.recordsProcessed
                ],
                "channel4_events_emitted": [
                    "value": outcome.eventsEmitted
                ],
                "channel4_realised_rate_eps": [
                    "value": Double(outcome.eventsEmitted) / elapsed
                ],
            ],
            "rss_before_mb": rssBeforeMB,
            "rss_after_mb": rssAfterMB,
        ]
        try Self.writeResult(payload, to: Self.resultPath(scenario: "channel4_replay_10k_records"))
    }
}
