//
//  ClaudeTranscriptTurnTests.swift
//  WorkspaceManagerTests
//
//  The transcript is what `ws check` and `ws resume` take as the record of what ran, so
//  these pin which entry counts as the last turn and how a requested model is compared.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Claude transcript turn")
struct ClaudeTranscriptTurnTests {
    private func withTranscript(_ lines: [String], _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try body(url)
    }

    private static func assistant(model: String, effort: String?, sidechain: Bool = false) -> String {
        let effortField = effort.map { ",\"effort\":\"\($0)\"" } ?? ""
        return
            "{\"type\":\"assistant\",\"isSidechain\":\(sidechain)\(effortField),\"message\":{\"model\":\"\(model)\"}}"
    }

    @Test("The last assistant entry is the turn, whatever follows it")
    func lastTurnWins() throws {
        try withTranscript([
            Self.assistant(model: "claude-haiku-5-5", effort: "low"),
            "{\"type\":\"user\",\"message\":{\"role\":\"user\"}}",
            Self.assistant(model: "claude-opus-5-5", effort: "xhigh"),
            "{\"type\":\"permission-mode\",\"permissionMode\":\"auto\"}",
        ]) { url in
            #expect(
                ClaudeTranscriptTurn.last(in: url)
                    == ClaudeTranscriptTurn(model: "claude-opus-5-5", effort: "xhigh")
            )
        }
    }

    @Test("A turn carries the time claude wrote it")
    func timestamp() throws {
        try withTranscript([
            "{\"type\":\"assistant\",\"timestamp\":\"2026-11-01T00:55:29.887Z\","
                + "\"message\":{\"model\":\"claude-opus-5-5\"}}"
        ]) { url in
            let timestamp = try #require(ClaudeTranscriptTurn.last(in: url)?.timestamp)
            #expect(abs(timestamp.timeIntervalSince1970 - 1_793_494_529.887) < 0.01)
        }
    }

    @Test("A subagent's turn and a locally generated message are not the conversation's")
    func skipsWhatIsNotTheConversation() throws {
        try withTranscript([
            Self.assistant(model: "claude-opus-5-5", effort: "high"),
            Self.assistant(model: "claude-haiku-5-5", effort: "low", sidechain: true),
            Self.assistant(model: "<synthetic>", effort: nil),
        ]) { url in
            #expect(ClaudeTranscriptTurn.last(in: url)?.model == "claude-opus-5-5")
        }
    }

    @Test("A transcript with no turn yet, or no file at all, has no last turn")
    func noTurn() throws {
        try withTranscript(["{\"type\":\"user\"}", "not json"]) { url in
            #expect(ClaudeTranscriptTurn.last(in: url) == nil)
        }
        #expect(ClaudeTranscriptTurn.last(in: URL(fileURLWithPath: "/nonexistent/x.jsonl")) == nil)
    }

    @Test("Reading only the end of a long transcript finds the turn and survives the cut line")
    func tailWindow() throws {
        let filler = String(repeating: "x", count: 4096)
        try withTranscript([
            "{\"type\":\"user\",\"filler\":\"\(filler)\"}",
            Self.assistant(model: "claude-opus-5-5", effort: "max"),
        ]) { url in
            #expect(ClaudeTranscriptTurn.last(in: url, tailBytes: 512)?.effort == "max")
        }
    }

    @Test(
        "A requested model is satisfied by the full id, an alias, or a variant of the same model",
        arguments: [
            ("claude-opus-5-5", "claude-opus-5-5", true),
            ("claude-opus-5-5", "opus", true),
            ("claude-opus-5-5", "OPUS", true),
            ("claude-opus-5-5", "claude-opus-5-5[1m]", true),
            ("claude-opus-5-5", "sonnet", false),
            ("claude-opus-5-5", "claude-sonnet-5-5", false),
            ("claude-opus-5-5", "", false),
        ]
    )
    func modelMatching(observed: String, requested: String, expected: Bool) {
        #expect(ClaudeTranscriptTurn.model(observed, satisfies: requested) == expected)
    }
}
