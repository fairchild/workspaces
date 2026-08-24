//
//  TmuxSessionControlTests.swift
//  WorkspaceManagerTests
//
//  Covers the two halves of the detached-session plane separately: the composed
//  tmux argument vectors (which a wrong target silently turns into "can't find
//  pane"), and the verb behavior around them, driven through an injected runner so
//  every outcome is reachable without a tmux server.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TmuxSessionControl")
struct TmuxSessionControlTests {

    /// Records what was run and answers from a scripted queue, so a test states the
    /// tmux outcomes it wants rather than arranging a server that produces them.
    private final class RecordingRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [ProcessResult?]
        private(set) var calls: [[String]] = []

        init(responses: [ProcessResult?]) {
            self.responses = responses
        }

        var runner: TmuxSessionControl.CommandRunner {
            { [self] _, arguments, _ in
                lock.lock()
                defer { lock.unlock() }
                calls.append(arguments)
                guard !responses.isEmpty else { return Self.ok }
                return responses.removeFirst()
            }
        }

        static let ok = ProcessResult(exitCode: 0, stdout: "", stderr: "")
        static let failure = ProcessResult(exitCode: 1, stdout: "", stderr: "no such session")
        static func output(_ text: String) -> ProcessResult {
            ProcessResult(exitCode: 0, stdout: text, stderr: "")
        }
    }

    private static let directory = URL(fileURLWithPath: "/tmp/ws-control-fixture")

    // MARK: - Command composition

    @Test("new-session composes a detached, exactly-named session in the workspace directory")
    func newSessionArgumentsShape() {
        let arguments = TmuxSessionControl.newSessionArguments(
            socketLabel: "workspaces",
            handle: "wm-fixture-abc12345",
            directory: Self.directory,
            command: "claude"
        )

        #expect(arguments.prefix(5) == ["tmux", "-L", "workspaces", "new-session", "-d"])
        #expect(consecutive(arguments, "-s", "wm-fixture-abc12345"))
        #expect(consecutive(arguments, "-c", Self.directory.path))
        // The command is run through a login shell so a launched agent resolves the
        // same PATH `workspaces open` would give it.
        #expect(arguments.suffix(4) == ["--", "/bin/zsh", "-lc", "claude"])
    }

    @Test("new-session sizes the pane past tmux's 80x24 default")
    func newSessionArgumentsCarryGeometry() {
        let arguments = TmuxSessionControl.newSessionArguments(
            socketLabel: "workspaces",
            handle: "wm-fixture-abc12345",
            directory: Self.directory,
            command: nil
        )
        #expect(consecutive(arguments, "-x", String(TmuxSessionControl.detachedPaneWidth)))
        #expect(consecutive(arguments, "-y", String(TmuxSessionControl.detachedPaneHeight)))
    }

    @Test("new-session without a command leaves the pane a plain shell")
    func newSessionArgumentsWithoutCommand() {
        for command in [nil, "", "   "] as [String?] {
            let arguments = TmuxSessionControl.newSessionArguments(
                socketLabel: "workspaces",
                handle: "wm-fixture-abc12345",
                directory: Self.directory,
                command: command
            )
            #expect(!arguments.contains("--"))
            #expect(!arguments.contains("/bin/zsh"))
        }
    }

    /// The regression this pins: `-t =name` is a *session* target, and `capture-pane`
    /// answers it with "can't find pane". The trailing colon is what makes it a pane
    /// target while keeping the exact-match `=`.
    @Test(
        "Pane-addressed verbs target the exactly-named session's active pane",
        arguments: [
            TmuxSessionControl.capturePaneArguments(
                socketLabel: "workspaces", handle: "wm-fixture-abc12345", lines: 10),
            TmuxSessionControl.sendTextArguments(socketLabel: "workspaces", handle: "wm-fixture-abc12345", text: "hi"),
            TmuxSessionControl.sendEnterArguments(socketLabel: "workspaces", handle: "wm-fixture-abc12345"),
        ]
    )
    func paneVerbsUsePaneTarget(arguments: [String]) {
        #expect(consecutive(arguments, "-t", "=wm-fixture-abc12345:"))
    }

    @Test("has-session keeps the bare exact-match session target")
    func hasSessionUsesSessionTarget() {
        let arguments = TmuxSessionControl.hasSessionArguments(
            socketLabel: "workspaces",
            handle: "wm-fixture-abc12345"
        )
        #expect(consecutive(arguments, "-t", "=wm-fixture-abc12345"))
    }

    @Test("capture-pane reaches above the visible pane and never asks for zero lines")
    func capturePaneArgumentsBound() {
        let arguments = TmuxSessionControl.capturePaneArguments(
            socketLabel: "workspaces",
            handle: "wm-fixture-abc12345",
            lines: 500
        )
        #expect(arguments.contains("-p"))
        #expect(consecutive(arguments, "-S", "-500"))

        let clamped = TmuxSessionControl.capturePaneArguments(
            socketLabel: "workspaces",
            handle: "wm-fixture-abc12345",
            lines: 0
        )
        #expect(consecutive(clamped, "-S", "-1"))
    }

    /// `-l` is what keeps a payload spelling `Enter` or `C-c` from reaching tmux as a
    /// keystroke, and `--` keeps a leading dash from reading as a flag.
    @Test("send-keys writes text literally")
    func sendTextArgumentsAreLiteral() {
        let arguments = TmuxSessionControl.sendTextArguments(
            socketLabel: "workspaces",
            handle: "wm-fixture-abc12345",
            text: "-C-c Enter"
        )
        #expect(consecutive(arguments, "-l", "--"))
        #expect(arguments.last == "-C-c Enter")
    }

    @Test("Trailing pane padding is dropped and interior blank lines are kept")
    func trailingBlankLineTrimming() {
        let captured = "first\n\nsecond\n   \n\n"
        #expect(TmuxSessionControl.trimmingTrailingBlankLines(captured) == "first\n\nsecond")
        #expect(TmuxSessionControl.trimmingTrailingBlankLines("\n\n").isEmpty)
        #expect(TmuxSessionControl.trimmingTrailingBlankLines("only") == "only")
    }

    @Test(
        "The socket label falls back to the app's server unless the environment names another",
        arguments: [
            ([:], TmuxSessionControl.defaultSocketLabel),
            (["WORKSPACES_TMUX_SOCKET_LABEL": "scratch"], "scratch"),
            (["WORKSPACES_TMUX_SOCKET_LABEL": "  "], TmuxSessionControl.defaultSocketLabel),
        ] as [([String: String], String)]
    )
    func socketLabelResolution(environment: [String: String], expected: String) {
        #expect(TmuxSessionControl.socketLabel(from: environment) == expected)
    }

    // MARK: - Verbs

    @Test("Launching onto a live handle fails closed and names the session")
    func launchRefusesLiveHandle() async {
        let recorder = RecordingRunner(responses: [RecordingRunner.ok])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        await #expect(throws: TmuxSessionControl.ControlError.handleAlreadyLive(handle: "wm-a-1")) {
            try await control.launch(handle: "wm-a-1", directory: Self.directory, command: "claude")
        }
        // The refusal costs one has-session and never reaches new-session.
        #expect(recorder.calls.count == 1)
    }

    @Test("A free handle launches and comes back as the caller's handle")
    func launchReturnsHandle() async throws {
        let recorder = RecordingRunner(responses: [RecordingRunner.failure, RecordingRunner.ok])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let handle = try await control.launch(handle: "wm-a-1", directory: Self.directory, command: "claude")
        #expect(handle == "wm-a-1")
        #expect(recorder.calls.count == 2)
        #expect(recorder.calls[1].contains("new-session"))
    }

    @Test("A tmux that never answers reads as unavailable, not as a failed command")
    func launchWithoutTmux() async {
        let recorder = RecordingRunner(responses: [RecordingRunner.failure, nil])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        await #expect(throws: TmuxSessionControl.ControlError.tmuxUnavailable) {
            try await control.launch(handle: "wm-a-1", directory: Self.directory, command: nil)
        }
    }

    @Test("Reading a handle that is not running says so instead of returning empty scrollback")
    func readRefusesDeadHandle() async {
        let recorder = RecordingRunner(responses: [RecordingRunner.failure])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        await #expect(throws: TmuxSessionControl.ControlError.handleNotLive(handle: "wm-a-1")) {
            _ = try await control.read(handle: "wm-a-1")
        }
    }

    @Test("Read returns the captured scrollback without its trailing pane padding")
    func readReturnsTrimmedScrollback() async throws {
        let recorder = RecordingRunner(
            responses: [RecordingRunner.ok, RecordingRunner.output("hello\n\n\n")]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let text = try await control.read(handle: "wm-a-1", lines: 5)
        #expect(text == "hello")
    }

    @Test("Send writes the text and reports its byte count")
    func sendReportsBytes() async throws {
        let recorder = RecordingRunner(responses: [RecordingRunner.ok, RecordingRunner.ok])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let bytes = try await control.send(handle: "wm-a-1", text: "héllo", submit: false)
        #expect(bytes == "héllo".utf8.count)
        // has-session, then one send-keys — no submit keystroke was asked for.
        #expect(recorder.calls.count == 2)
        #expect(!recorder.calls[1].contains("Enter"))
    }

    @Test("Submitting sends Enter as its own call, after the literal text")
    func sendSubmitsSeparately() async throws {
        let recorder = RecordingRunner(responses: [RecordingRunner.ok, RecordingRunner.ok, RecordingRunner.ok])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        _ = try await control.send(handle: "wm-a-1", text: "run it", submit: true)
        #expect(recorder.calls.count == 3)
        #expect(recorder.calls[1].contains("-l"))
        #expect(recorder.calls[2].last == "Enter")
    }

    @Test("A tmux failure carries its stderr into the message a caller reads")
    func commandFailureCarriesStderr() async {
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                ProcessResult(exitCode: 1, stdout: "", stderr: "can't find pane: =wm-a-1"),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        do {
            _ = try await control.read(handle: "wm-a-1")
            Issue.record("read should have thrown")
        } catch let error as TmuxSessionControl.ControlError {
            #expect(error.localizedDescription.contains("can't find pane"))
            #expect(error.localizedDescription.contains("capture-pane"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// True when `flag` is immediately followed by `value` — the property that matters
    /// for a tmux argument vector, which `contains` alone would not catch.
    private func consecutive(_ arguments: [String], _ flag: String, _ value: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return false
        }
        return arguments[index + 1] == value
    }
}
