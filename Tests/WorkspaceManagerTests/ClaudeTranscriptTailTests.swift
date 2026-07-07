import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeTranscriptTail")
struct ClaudeTranscriptTailTests {
    // MARK: - Project slug

    @Test("Slug replaces every slash and dot with a dash")
    func slugRule() {
        #expect(ClaudeTranscriptTail.projectSlug(forCWD: "/Users/me/code") == "-Users-me-code")
        // A leading dot on a path segment (e.g. `/.chat`) yields a double dash, matching disk.
        #expect(
            ClaudeTranscriptTail.projectSlug(forCWD: "/Users/me/proj/.chat-worktrees/session-1")
                == "-Users-me-proj--chat-worktrees-session-1")
    }

    // MARK: - Transcript URL

    @Test("URL resolves under ~/.claude/projects for a Claude Code session")
    func urlHappyPath() throws {
        let home = URL(fileURLWithPath: "/Users/me")
        let url = try #require(
            ClaudeTranscriptTail.transcriptURL(
                cwd: "/Users/me/code", agentSessionID: "abc-123", kind: .claudeCode,
                homeDirectory: home))
        #expect(url.path == "/Users/me/.claude/projects/-Users-me-code/abc-123.jsonl")
    }

    @Test("URL is nil for non-happy inputs")
    func urlNilCases() {
        let home = URL(fileURLWithPath: "/Users/me")
        // Wrong agent kind.
        #expect(
            ClaudeTranscriptTail.transcriptURL(
                cwd: "/Users/me/code", agentSessionID: "abc", kind: .opencode, homeDirectory: home)
                == nil)
        // Missing / empty session id.
        #expect(
            ClaudeTranscriptTail.transcriptURL(
                cwd: "/Users/me/code", agentSessionID: nil, kind: .claudeCode, homeDirectory: home)
                == nil)
        #expect(
            ClaudeTranscriptTail.transcriptURL(
                cwd: "/Users/me/code", agentSessionID: "", kind: .claudeCode, homeDirectory: home)
                == nil)
        // Empty cwd.
        #expect(
            ClaudeTranscriptTail.transcriptURL(
                cwd: "   ", agentSessionID: "abc", kind: .claudeCode, homeDirectory: home) == nil)
    }

    // MARK: - Last assistant text parsing

    private let sampleTranscript = """
        {"type":"user","message":{"role":"user","content":"review the code"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"An earlier reply."}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"more"},{"type":"text","text":"The final answer."}]}}
        {"type":"system"}
        """

    @Test("Picks the last assistant text block, skipping thinking, tool_use, and user rows")
    func picksLastAssistantText() {
        #expect(ClaudeTranscriptTail.lastAssistantText(inTailChunk: sampleTranscript) == "The final answer.")
    }

    @Test("A partial leading line fails to parse and is ignored")
    func ignoresPartialLeadingLine() {
        let partial = "type\":\"assistant\",\"garbage\n" + sampleTranscript
        #expect(ClaudeTranscriptTail.lastAssistantText(inTailChunk: partial) == "The final answer.")
    }

    @Test("No assistant text yields nil")
    func noAssistantText() {
        let chunk = """
            {"type":"user","message":{"role":"user","content":"hello"}}
            {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}
            """
        #expect(ClaudeTranscriptTail.lastAssistantText(inTailChunk: chunk) == nil)
        #expect(ClaudeTranscriptTail.lastAssistantText(inTailChunk: "") == nil)
    }

    @Test("Assistant text is collapsed to one line and truncated")
    func collapsesAndTruncates() {
        let long = String(repeating: "y", count: 300)
        let chunk =
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"line one\\nline two\"}]}}"
        #expect(ClaudeTranscriptTail.lastAssistantText(inTailChunk: chunk) == "line one line two")

        let longChunk =
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(long)\"}]}}"
        let snippet = ClaudeTranscriptTail.lastAssistantText(inTailChunk: longChunk, maxLength: 50)
        #expect(snippet?.count == 50)
        #expect(snippet?.hasSuffix("…") == true)
    }

    // MARK: - Resolver (reads the file tail)

    @Test("Resolver reads the last assistant message from a transcript on disk")
    func resolverReadsTail() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-home-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/Users/tester/project"
        let sessionID = "session-\(UUID().uuidString)"
        let dir =
            home
            .appendingPathComponent(
                ".claude/projects/\(ClaudeTranscriptTail.projectSlug(forCWD: cwd))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionID).jsonl")
        try sampleTranscript.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeTranscriptTailResolver()

        // End-to-end: the resolver seeks the file tail, parses, and returns the last message.
        let resolved = await resolver.tail(
            cwd: cwd, agentSessionID: sessionID, kind: .claudeCode, homeDirectory: home)
        #expect(resolved == "The final answer.")

        // A missing file resolves to nil (fail-closed).
        let missing = await resolver.tail(
            cwd: "/nope/does/not/exist", agentSessionID: "missing", kind: .claudeCode,
            homeDirectory: home)
        #expect(missing == nil)

        // A non-Claude kind never resolves.
        let wrongKind = await resolver.tail(
            cwd: cwd, agentSessionID: sessionID, kind: .opencode, homeDirectory: home)
        #expect(wrongKind == nil)
    }

    @Test("Resolver rejects a non-regular file at the transcript path")
    func resolverRejectsNonRegularFile() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-home-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/Users/tester/project"
        let sessionID = "session-\(UUID().uuidString)"
        let dir =
            home
            .appendingPathComponent(
                ".claude/projects/\(ClaudeTranscriptTail.projectSlug(forCWD: cwd))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Put a *directory* where the "<id>.jsonl" file would be — a stand-in for any non-regular
        // path (symlink/FIFO/device). The resolver must reject it, not open it.
        let nonRegular = dir.appendingPathComponent("\(sessionID).jsonl")
        try FileManager.default.createDirectory(at: nonRegular, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let resolver = ClaudeTranscriptTailResolver()
        let resolved = await resolver.tail(
            cwd: cwd, agentSessionID: sessionID, kind: .claudeCode, homeDirectory: home)
        #expect(resolved == nil)
    }

    @Test("A final record larger than the tail budget fails closed to nil, never an older message")
    func oversizedFinalRecordFailsClosed() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-home-\(UUID().uuidString)", isDirectory: true)
        let cwd = "/Users/tester/project"
        let sessionID = "session-\(UUID().uuidString)"
        let dir =
            home
            .appendingPathComponent(
                ".claude/projects/\(ClaudeTranscriptTail.projectSlug(forCWD: cwd))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionID).jsonl")
        // An earlier valid assistant message, then a final record far larger than the tail budget.
        let huge = String(repeating: "z", count: 4096)
        let transcript =
            "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Older answer.\"}]}}\n"
            + "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(huge)\"}]}}"
        try transcript.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        // A tiny tail budget starts the read inside the final record: it fails closed to nil rather
        // than surfacing the *older* "Older answer." message.
        let resolver = ClaudeTranscriptTailResolver(tailByteCount: 256)
        let resolved = await resolver.tail(
            cwd: cwd, agentSessionID: sessionID, kind: .claudeCode, homeDirectory: home)
        #expect(resolved == nil)
    }
}
