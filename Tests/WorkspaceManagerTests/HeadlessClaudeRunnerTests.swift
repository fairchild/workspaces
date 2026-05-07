//
//  HeadlessClaudeRunnerTests.swift
//  WorkspaceManagerTests
//
//  Drives `HeadlessClaudeRunner` with a stub `HeadlessProcessRunning` that
//  emits a recorded NDJSON stream. Asserts session_id capture, --resume
//  argument plumbing, and graceful error pass-through.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("HeadlessClaudeRunner")
struct HeadlessClaudeRunnerTests {

    @Test("buildArguments emits the canonical --bare invocation")
    func buildArgumentsCanonical() {
        let args = HeadlessClaudeRunner.buildArguments(
            executable: "/opt/homebrew/bin/claude",
            prompt: "lint sweep",
            allowedTools: ["Read", "Bash"],
            resumeSessionID: nil
        )
        #expect(args.contains("--bare"))
        #expect(args.contains("-p"))
        #expect(args.contains("lint sweep"))
        #expect(args.contains("--output-format"))
        #expect(args.contains("stream-json"))
        #expect(args.contains("--verbose"))
        #expect(args.contains("--include-partial-messages"))
        #expect(args.contains("--permission-mode"))
        #expect(args.contains("acceptEdits"))
        #expect(args.contains("--allowedTools"))
        #expect(args.contains("Read,Bash"))
        #expect(!args.contains("--resume"))
    }

    @Test("buildArguments adds --resume <id> when supplied")
    func buildArgumentsWithResume() {
        let args = HeadlessClaudeRunner.buildArguments(
            executable: "/opt/homebrew/bin/claude",
            prompt: "p",
            allowedTools: [],
            resumeSessionID: "sess-42"
        )
        let idx = args.firstIndex(of: "--resume")
        #expect(idx != nil)
        if let idx, idx + 1 < args.count {
            #expect(args[idx + 1] == "sess-42")
        }
    }

    @Test("buildArguments prepends `claude` when falling back to /usr/bin/env")
    func buildArgumentsEnvFallback() {
        let args = HeadlessClaudeRunner.buildArguments(
            executable: "/usr/bin/env",
            prompt: "p",
            allowedTools: [],
            resumeSessionID: nil
        )
        #expect(args.first == "claude")
    }

    @Test("runner streams parsed events from the stub stdout")
    func streamsParsedEvents() async {
        let stub = StubStreamingRunner(
            stdoutChunks: [
                #"{"type":"system","subtype":"init","model":"m","session_id":"s","tools":[]}"# + "\n",
                #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#
                    + "\n",
                #"{"type":"result","result":"ok","total_cost_usd":0.1,"duration_ms":10,"num_turns":1,"session_id":"s"}"#
                    + "\n",
            ],
            stderrChunks: [],
            exitCode: 0
        )
        let runner = HeadlessClaudeRunner(
            processRunner: stub,
            executableResolver: { "/opt/homebrew/bin/claude" }
        )
        var collected: [HeadlessClaudeEvent] = []
        let stream = await runner.run(prompt: "hi", cwd: URL(fileURLWithPath: "/tmp"))
        for await event in stream {
            collected.append(event)
        }
        #expect(collected.count == 3)
        if case .systemInit = collected[0] {} else { Issue.record("expected systemInit") }
        #expect(collected[1] == .textDelta("hi"))
        if case .result(_, _, _, _, let sid) = collected[2] {
            #expect(sid == "s")
        } else {
            Issue.record("expected result")
        }
    }

    @Test("runner forwards --resume to the spawned process")
    func resumeArgumentForwarded() async {
        let stub = StubStreamingRunner(
            stdoutChunks: [
                #"{"type":"result","result":"ok","session_id":"s"}"# + "\n"
            ],
            stderrChunks: [],
            exitCode: 0
        )
        let runner = HeadlessClaudeRunner(
            processRunner: stub,
            executableResolver: { "/opt/homebrew/bin/claude" }
        )
        let stream = await runner.run(
            prompt: "p",
            cwd: URL(fileURLWithPath: "/tmp"),
            resumeSessionID: "prev-session"
        )
        for await _ in stream {}
        let captured = stub.captured.value
        #expect(captured?.arguments.contains("--resume") == true)
        #expect(captured?.arguments.contains("prev-session") == true)
    }

    @Test("non-zero exit with no result event surfaces a synthetic .unknown error event")
    func errorPassthrough() async {
        let stub = StubStreamingRunner(
            stdoutChunks: [],
            stderrChunks: ["claude: not authenticated\n"],
            exitCode: 1
        )
        let runner = HeadlessClaudeRunner(
            processRunner: stub,
            executableResolver: { "/opt/homebrew/bin/claude" }
        )
        var collected: [HeadlessClaudeEvent] = []
        let stream = await runner.run(prompt: "p", cwd: URL(fileURLWithPath: "/tmp"))
        for await event in stream {
            collected.append(event)
        }
        #expect(collected.count == 1)
        guard case .unknown(let raw) = collected[0] else {
            Issue.record("expected unknown error event")
            return
        }
        #expect(raw.contains("error"))
        #expect(raw.contains("not authenticated"))
    }

    @Test("HeadlessSessionStore round-trips the latest session id")
    func sessionStoreRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("headless-session-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = HeadlessSessionStore(workspaceRoot: tmp)
        #expect(store.loadLatestSessionID() == nil)
        try store.recordSessionID("first")
        #expect(store.loadLatestSessionID() == "first")
        try store.recordSessionID("second")
        #expect(store.loadLatestSessionID() == "second")
    }
}

// MARK: - Stub

/// In-memory `HeadlessProcessRunning` that replays a fixed stdout/stderr
/// transcript and records what the runner asked it to spawn.
final class StubStreamingRunner: HeadlessProcessRunning, @unchecked Sendable {
    struct Capture {
        let executable: String
        let arguments: [String]
        let cwd: URL?
    }

    final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                stored = newValue
            }
        }
    }

    let stdoutChunks: [String]
    let stderrChunks: [String]
    let exitCode: Int32
    let captured = Box<Capture?>(nil)

    init(stdoutChunks: [String], stderrChunks: [String], exitCode: Int32) {
        self.stdoutChunks = stdoutChunks
        self.stderrChunks = stderrChunks
        self.exitCode = exitCode
    }

    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        onStdoutChunk: @escaping @Sendable (String) -> Void,
        onStderrChunk: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        captured.value = Capture(
            executable: executable,
            arguments: arguments,
            cwd: currentDirectory
        )
        for chunk in stdoutChunks { onStdoutChunk(chunk) }
        for chunk in stderrChunks { onStderrChunk(chunk) }
        return exitCode
    }
}
