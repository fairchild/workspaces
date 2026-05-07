//
//  ColdStartRecoveryTests.swift
//  WorkspaceManagerTests
//
//  Synthesize a 1000-record transcript, replay it through the cold-start path,
//  and assert the final state matches a synchronous-ingest baseline. Also gates
//  the 500 ev/s replay rate-cap from the perf audit.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
@Suite("ColdStartRecovery")
struct ColdStartRecoveryTests {

    private func writeFixture(records: Int) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-coldstart-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")

        var lines: [String] = []
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

    @Test func replayMatchesSyncIngestBaseline() async throws {
        let url = writeFixture(records: 1000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Build a synchronous-ingest baseline by reading every record and feeding
        // events one at a time through `ingest(_:for:origin:)`.
        let host = UUID()
        let baseline = AgentSessionRegistry()
        baseline.register(hostSessionID: host, cwd: "/tmp", kind: .claudeCode)
        for await record in TranscriptReader(transcriptPath: url).tail() {
            if let event = TranscriptEventMapper.mapToAgentEvent(
                record,
                agentSessionID: nil,
                kind: .claudeCode
            ) {
                baseline.ingest(event, for: host, origin: .transcript)
            }
        }

        // Replay through the cold-start coordinator. Throttle is intentionally
        // permissive for the unit test (10k ev/s) so it finishes fast; the perf
        // scenario asserts the production 500 ev/s gate on a 10k-record fixture.
        let recovery = AgentSessionRegistry()
        recovery.register(hostSessionID: host, cwd: "/tmp", kind: .claudeCode)
        let runner = TranscriptColdStartRecovery(
            registry: recovery,
            configuration: .init(eventsPerSecond: 10_000, flushSize: 64, flushIntervalMS: 16)
        )
        let outcome = await runner.replay(
            transcriptPath: url,
            for: host,
            agentSessionID: nil,
            kind: .claudeCode
        )

        #expect(outcome.recordsProcessed == 1000)
        #expect(outcome.eventsEmitted > 0)

        let baselineRun = baseline.statuses[host]?.run
        let recoveryRun = recovery.statuses[host]?.run
        #expect(baselineRun == recoveryRun)
    }

    @Test func replayHonoursRateCapAtFiveHundred() async throws {
        // Use a fixture large enough that the initial burst credit (≤
        // `eventsPerSecond` events) is amortised across the steady-state phase.
        let recordCount = 3000
        let url = writeFixture(records: recordCount)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let host = UUID()
        let registry = AgentSessionRegistry()
        registry.register(hostSessionID: host, cwd: "/tmp", kind: .claudeCode)

        let runner = TranscriptColdStartRecovery(
            registry: registry,
            configuration: .init(eventsPerSecond: 500, flushSize: 64, flushIntervalMS: 16)
        )

        let outcome = await runner.replay(
            transcriptPath: url,
            for: host,
            agentSessionID: nil,
            kind: .claudeCode
        )

        // The token bucket starts full (500 tokens), so the first ~500 events
        // pass without throttling — that's by design. After the initial credit
        // is spent, steady-state rate must stay at or near 500 ev/s. With 3000
        // events the realised rate should be ≤ ~600 ev/s.
        #expect(outcome.eventsEmitted >= recordCount)
        let realisedRate = Double(outcome.eventsEmitted) / outcome.durationSeconds
        #expect(
            realisedRate <= 650,
            "rate cap held: \(outcome.eventsEmitted) events in \(outcome.durationSeconds)s = \(realisedRate) ev/s"
        )
    }

    @Test func knownSessionStoreRoundTrip() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-known-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("known-sessions.json")
        let store = KnownSessionStore(storageURL: url)
        let host = UUID()
        let session = KnownSession(
            hostSessionID: host,
            agentSessionID: "agent-123",
            cwd: "/tmp/proj",
            transcriptPath: "/tmp/proj/transcript.jsonl",
            kindRaw: AgentKind.claudeCode.rawValue,
            lastSeenAt: Date()
        )
        await store.record(session)

        let store2 = KnownSessionStore(storageURL: url)
        let all = await store2.all()
        #expect(all.count == 1)
        #expect(all.first?.hostSessionID == host)
        #expect(all.first?.agentSessionID == "agent-123")

        await store2.remove(hostSessionID: host)
        let after = await store2.all()
        #expect(after.isEmpty)
    }
}
