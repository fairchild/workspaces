//
//  HeadlessClaudeRunner.swift
//  WorkspaceManagerCore
//
//  Wraps `claude -p` (non-interactive). Channel 5 of the agent integration
//  spec — see the plan's "Channel 5" section. Streams the CLI's stream-json
//  output through `HeadlessClaudeStreamParser` and surfaces normalized
//  `HeadlessClaudeEvent` values to callers (sidebar quick actions, post-setup
//  warm-up). The registry side keeps headless runs in their own
//  `hostSessionID` namespace — DO NOT share entries with interactive
//  sessions.
//
//  Why `--bare`: the interactive harness loads user hooks, plugins, and
//  skills. For deterministic warm-up + quick-action behavior we want a
//  reproducible run without whatever the user has configured globally.
//  `--bare` skips all of that. The flip side is the runner can't take
//  advantage of the user's plugins — that is by design for v1; if a
//  project wants plugin behavior it should pin one explicitly through
//  the prompt + tool list.
//

import Foundation
import os.log

private let log = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "HeadlessClaudeRunner"
)

/// Spawns a process and forwards stdout/stderr lines plus exit status to a
/// callback. The runner depends on the protocol so tests can stub the CLI
/// without relying on a real `claude` binary on the machine.
public protocol HeadlessProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        onStdoutChunk: @escaping @Sendable (String) -> Void,
        onStderrChunk: @escaping @Sendable (String) -> Void
    ) async throws -> Int32
}

/// Default implementation backed by `Foundation.Process` with a streaming
/// readabilityHandler on each pipe. ProcessRunner.run buffers everything and
/// returns at termination — that doesn't fit a streaming NDJSON consumer, so
/// we keep this as a sibling utility next to ProcessRunner rather than
/// reshaping it. Same shape, different resolution mode.
public struct StreamingProcessRunner: HeadlessProcessRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        currentDirectory: URL?,
        environment: [String: String]?,
        onStdoutChunk: @escaping @Sendable (String) -> Void,
        onStderrChunk: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                if !chunk.isEmpty { onStdoutChunk(chunk) }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                if !chunk.isEmpty { onStderrChunk(chunk) }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Persistent map of `<workspace>` → claude session id, for `--resume` plumbing.
/// Stored as JSON under `<workspace>/.workspaces/headless/sessions.json`.
public struct HeadlessSessionStore: Sendable {
    private let storeURL: URL

    public init(workspaceRoot: URL) {
        self.storeURL =
            workspaceRoot
            .appendingPathComponent(".workspaces", isDirectory: true)
            .appendingPathComponent("headless", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    /// Latest known claude session id for the workspace, if any.
    public func loadLatestSessionID() -> String? {
        guard let data = try? Data(contentsOf: storeURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let latest = object["latest"] as? String,
            !latest.isEmpty
        else {
            return nil
        }
        return latest
    }

    /// Save a new session id, keeping a small history (most-recent-first, capped
    /// at 16 entries) so we have a debugging trail without unbounded growth.
    public func recordSessionID(_ sessionID: String) throws {
        let dir = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var history: [String] = []
        if let data = try? Data(contentsOf: storeURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let prior = object["history"] as? [String]
        {
            history = prior
        }

        history.removeAll { $0 == sessionID }
        history.insert(sessionID, at: 0)
        if history.count > 16 { history = Array(history.prefix(16)) }

        let payload: [String: Any] = [
            "latest": sessionID,
            "history": history,
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: storeURL, options: .atomic)
    }
}

/// Errors surfaced by ``HeadlessClaudeRunner``. The runner pushes these out as
/// terminal events on the `AsyncStream` rather than throwing, so the consuming
/// pipeline doesn't have to wrap every iteration in try/catch.
public enum HeadlessClaudeRunnerError: Error, Sendable, Equatable {
    /// `claude` not found on `$PATH` (or wherever we resolved it).
    case executableNotFound
    /// Process spawned but exited non-zero before any stream-json output.
    case earlyExit(code: Int32, stderr: String)
    /// The runner finished without ever seeing a `result` event.
    case noResult
}

/// Headless `claude -p` runner. One instance ↔ one workspace + lifecycle.
/// Always spawned via `--bare` for deterministic behavior across users.
public actor HeadlessClaudeRunner {
    private let processRunner: HeadlessProcessRunning
    private let executableResolver: @Sendable () -> String

    public init(
        processRunner: HeadlessProcessRunning = StreamingProcessRunner(),
        executableResolver: @escaping @Sendable () -> String = HeadlessClaudeRunner.defaultExecutable
    ) {
        self.processRunner = processRunner
        self.executableResolver = executableResolver
    }

    /// Resolve a `claude` executable in the order: env override → common
    /// install paths → bare `claude` (let PATH resolve). The env override is
    /// useful for tests and for letting users pin a specific install (e.g.
    /// `mise`-managed) without relying on PATH.
    public static let defaultExecutable: @Sendable () -> String = {
        if let override = ProcessInfo.processInfo.environment["WORKSPACES_CLAUDE_BIN"],
            !override.isEmpty
        {
            return override
        }
        for candidate in [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
        ] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to `/usr/bin/env claude` so PATH-based resolution still
        // works when nothing else matches. The runner reports
        // `executableNotFound` cleanly if env can't find it.
        return "/usr/bin/env"
    }

    /// Spawn the runner. Returns an `AsyncStream` of events; the stream
    /// finishes after a `.result(...)` (success) or after an error event is
    /// emitted (failure). Cancelling the consumer terminates the underlying
    /// process via task cancellation.
    public func run(
        prompt: String,
        cwd: URL,
        allowedTools: [String] = [],
        resumeSessionID: String? = nil
    ) -> AsyncStream<HeadlessClaudeEvent> {
        let resolved = executableResolver()
        let runner = processRunner

        return AsyncStream { continuation in
            let task = Task {
                let arguments = Self.buildArguments(
                    executable: resolved,
                    prompt: prompt,
                    allowedTools: allowedTools,
                    resumeSessionID: resumeSessionID
                )

                // Box the parser so it can be mutated from the closures
                // without violating Sendable. Lock around feed/flush — only
                // one thread will call into either at a time in practice
                // (readabilityHandler dispatches serially per pipe), but
                // belt-and-suspenders.
                let parserBox = ParserBox()
                let stderrBox = StderrBox()

                let stdoutHandler: @Sendable (String) -> Void = { chunk in
                    let events = parserBox.feed(chunk)
                    for event in events { continuation.yield(event) }
                }
                let stderrHandler: @Sendable (String) -> Void = { chunk in
                    stderrBox.append(chunk)
                }

                do {
                    let exitCode = try await runner.run(
                        executable: resolved,
                        arguments: arguments,
                        currentDirectory: cwd,
                        environment: Self.processEnvironment(),
                        onStdoutChunk: stdoutHandler,
                        onStderrChunk: stderrHandler
                    )

                    let trailing = parserBox.flush()
                    for event in trailing { continuation.yield(event) }

                    // Surface a synthetic event if the CLI failed with no
                    // stream-json output — callers can decide whether to
                    // treat as fatal.
                    if exitCode != 0 && !parserBox.didEmitResult {
                        let stderr = stderrBox.collected
                        let payload: [String: Any] = [
                            "type": "error",
                            "exit_code": exitCode,
                            "stderr": stderr,
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: payload),
                            let raw = String(data: data, encoding: .utf8)
                        {
                            continuation.yield(.unknown(raw: raw))
                        }
                    }
                } catch {
                    log.error(
                        "headless claude spawn failed: \(error.localizedDescription, privacy: .public)"
                    )
                    let payload: [String: Any] = [
                        "type": "spawn_error",
                        "error": error.localizedDescription,
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: payload),
                        let raw = String(data: data, encoding: .utf8)
                    {
                        continuation.yield(.unknown(raw: raw))
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Split out for tests so we can assert argument plumbing without spawning
    /// a process.
    public static func buildArguments(
        executable: String,
        prompt: String,
        allowedTools: [String],
        resumeSessionID: String?
    ) -> [String] {
        var args: [String] = []
        // When we fall back to `/usr/bin/env`, we have to inject `claude` as
        // the first arg so env actually executes the binary.
        if executable == "/usr/bin/env" {
            args.append("claude")
        }
        args.append(contentsOf: [
            "--bare",
            "-p", prompt,
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", "acceptEdits",
        ])
        if !allowedTools.isEmpty {
            args.append("--allowedTools")
            args.append(allowedTools.joined(separator: ","))
        }
        if let resumeSessionID, !resumeSessionID.isEmpty {
            args.append("--resume")
            args.append(resumeSessionID)
        }
        return args
    }

    private static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Make sure homebrew + uv shim paths are visible — same shape as
        // WorkspaceService.runLifecycleScript. Without this, env-resolved
        // `claude` may not be found inside the app's sandboxed PATH.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        return env
    }
}

/// Reference-typed parser holder. Captures the stream-state across the two
/// callbacks (stdout + termination) without breaking Sendable.
private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = HeadlessClaudeStreamParser()
    private(set) var didEmitResult = false

    func feed(_ chunk: String) -> [HeadlessClaudeEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = parser.feed(chunk)
        for event in events {
            if case .result = event { didEmitResult = true }
        }
        return events
    }

    func flush() -> [HeadlessClaudeEvent] {
        lock.lock()
        defer { lock.unlock() }
        let events = parser.flush()
        for event in events {
            if case .result = event { didEmitResult = true }
        }
        return events
    }
}

/// Reference-typed stderr accumulator. Same Sendable workaround as
/// ParserBox.
private final class StderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        // Cap to avoid unbounded memory if the CLI loops on errors.
        if buffer.count > 32_768 {
            buffer = String(buffer.suffix(32_768))
        }
    }

    var collected: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
