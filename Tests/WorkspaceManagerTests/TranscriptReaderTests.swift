//
//  TranscriptReaderTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TranscriptReader")
struct TranscriptReaderTests {

    private func tempJSONLFile(name: String = UUID().uuidString) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wm-transcript-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).jsonl")
    }

    private func write(_ lines: [String], to url: URL) {
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func tailDecodesAllCanonicalTypes() async throws {
        let url = tempJSONLFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        write(
            [
                #"{"type":"user","uuid":"u1","text":"hello there"}"#,
                #"{"type":"assistant","uuid":"a1","text":"hi","model":"claude-sonnet-5"}"#,
                #"{"type":"tool_use","uuid":"t1","tool_name":"Read","input":{"file_path":"/tmp/x"}}"#,
                #"{"type":"tool_result","uuid":"r1","tool_name":"Read","duration_ms":42,"is_error":false,"text":"ok"}"#,
                #"{"type":"summary","uuid":"s1","summary":"all good"}"#,
                #"{"type":"orchestration_event","payload":{"k":"v"}}"#,
            ],
            to: url
        )

        var collected: [TranscriptRecord] = []
        for await record in TranscriptReader(transcriptPath: url).tail() {
            collected.append(record)
        }

        #expect(collected.count == 6)
        guard case .user(let u) = collected[0] else {
            Issue.record("expected user record")
            return
        }
        #expect(u.text == "hello there")

        guard case .assistant(let a) = collected[1] else {
            Issue.record("expected assistant record")
            return
        }
        #expect(a.model == "claude-sonnet-5")

        guard case .toolUse(let t) = collected[2] else {
            Issue.record("expected tool_use record")
            return
        }
        #expect(t.toolName == "Read")
        #expect(t.inputSummary == "/tmp/x")

        guard case .toolResult(let r) = collected[3] else {
            Issue.record("expected tool_result record")
            return
        }
        #expect(r.durationMS == 42)
        #expect(r.isError == false)

        guard case .summary(let s) = collected[4] else {
            Issue.record("expected summary record")
            return
        }
        #expect(s.summary == "all good")

        guard case .opaque(let typeName, _) = collected[5] else {
            Issue.record("expected opaque record")
            return
        }
        #expect(typeName == "orchestration_event")
    }

    @Test func tailIgnoresMalformedLines() async throws {
        let url = tempJSONLFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        write(
            [
                #"{"type":"user","text":"first"}"#,
                "not-json-at-all",
                "",
                #"{"type":"user","text":"second"}"#,
            ],
            to: url
        )

        var count = 0
        for await _ in TranscriptReader(transcriptPath: url).tail() { count += 1 }
        #expect(count == 2)
    }

    @Test func tailHandlesPartialLastLineWithoutNewline() async throws {
        let url = tempJSONLFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let body = #"{"type":"user","text":"only line"}"#
        try? body.write(to: url, atomically: true, encoding: .utf8)

        var count = 0
        for await record in TranscriptReader(transcriptPath: url).tail() {
            count += 1
            if case .user(let u) = record { #expect(u.text == "only line") }
        }
        #expect(count == 1)
    }

    @Test func liveStreamPicksUpAppends() async throws {
        let url = tempJSONLFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try? "".write(to: url, atomically: true, encoding: .utf8)

        let reader = TranscriptReader(transcriptPath: url, pollInterval: 0.05)
        let stream = reader.live()
        let collector = Task<[TranscriptRecord], Never> {
            var out: [TranscriptRecord] = []
            for await record in stream {
                out.append(record)
                if out.count == 2 { break }
            }
            return out
        }

        // Append one line, wait, append another.
        try? "{\"type\":\"user\",\"text\":\"first\"}\n".write(to: url, atomically: true, encoding: .utf8)
        try? await Task.sleep(nanoseconds: 200_000_000)

        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            handle.write(Data("{\"type\":\"user\",\"text\":\"second\"}\n".utf8))
            try? handle.close()
        }

        let collected = await collector.value
        #expect(collected.count == 2)
    }
}
