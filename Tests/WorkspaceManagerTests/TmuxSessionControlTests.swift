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

    @Test("Send writes the text and reports what tmux was handed")
    func sendReportsBytes() async throws {
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                RecordingRunner.output("$ héllo there, run it"),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: "héllo there, run it", submit: false)
        #expect(report.bytesOffered == "héllo there, run it".utf8.count)
        #expect(report.chunks == 1)
        #expect(report.verification == .paneShowsText)
        // has-session, the pane before, one send-keys, the pane after — and no submit
        // keystroke, which was not asked for.
        #expect(recorder.calls.count == 4)
        #expect(recorder.calls.contains { $0.contains("Enter") } == false)
    }

    @Test("Submitting sends Enter as its own call, after the literal text")
    func sendSubmitsSeparately() async throws {
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                RecordingRunner.output("$ run it"),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        _ = try await control.send(handle: "wm-a-1", text: "run it", submit: true)
        // has-session, the pane before, the text, the pane after, then the submit. Both
        // read-backs sit before Enter because after it the composer has consumed the text.
        // Required rather than expected: the assertions below index into this array, and
        // a wrong count should read as a failed count, not as a trap that ends the run.
        try #require(recorder.calls.count == 5)
        #expect(recorder.calls[1].contains("capture-pane"))
        #expect(recorder.calls[2].contains("-l"))
        #expect(recorder.calls[3].contains("capture-pane"))
        #expect(recorder.calls[4].last == "Enter")
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

    // MARK: - Chunking

    /// The payload is reassembled by the receiver from bytes, so the only thing the
    /// split may not do is change them.
    @Test("Chunks concatenate back to the input and none exceeds the byte bound")
    func chunksReproduceTheInput() {
        let text = String(repeating: "h\u{00E9}llo w\u{00F6}rld \u{4E2D}\u{6587} \u{1F600} ", count: 60)
        let chunks = TmuxSessionControl.textChunks(text, limit: 256)

        #expect(chunks.count > 1)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf8.count <= 256 })
    }

    /// Each chunk becomes its own argv string, so a scalar cut in half would reach the
    /// pane as replacement characters rather than as the character that was sent.
    @Test("A chunk boundary never lands inside a multi-byte scalar")
    func chunksCutOnScalarBoundaries() {
        // Every scalar here is four UTF-8 bytes and the bound is not a multiple of
        // four, so a byte-wise split would have to land inside one.
        let text = String(repeating: "\u{1F600}", count: 200)
        let chunks = TmuxSessionControl.textChunks(text, limit: 10)

        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.utf8.count == 8 || $0.utf8.count == 4 })
    }

    /// The limit is honoured down to one byte; the documented exception is a single
    /// scalar wider than it, which is emitted whole rather than corrupted.
    @Test("A limit under one scalar's width yields one scalar per chunk")
    func chunksHonourASmallLimit() {
        #expect(TmuxSessionControl.textChunks("abcd", limit: 1) == ["a", "b", "c", "d"])
        #expect(TmuxSessionControl.textChunks("\u{1F600}a", limit: 3) == ["\u{1F600}", "a"])
    }

    @Test("Empty text is a no-op rather than an empty keystroke")
    func emptyTextSendsNothing() async throws {
        #expect(TmuxSessionControl.textChunks("").isEmpty)

        let recorder = RecordingRunner(responses: [])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: "", submit: false)

        #expect(report.chunks == 0)
        #expect(report.bytesOffered == 0)
        #expect(report.verification == .notChecked)
        // Nothing to type and nothing to look for, so the pane is never even captured.
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].contains("has-session"))
    }

    /// 1200 bytes is the size class #1450 reported losing: over the pty input queue's
    /// depth, so a single call leaves the whole payload sitting in a buffer that is
    /// discarded whenever the receiving process flushes its input.
    @Test("A 1200-byte payload is handed over in chunks under the queue's depth")
    func longPayloadIsChunked() async throws {
        let recorder = RecordingRunner(responses: [])
        let control = TmuxSessionControl(
            socketLabel: "scratch",
            run: recorder.runner,
            environment: [:],
            sendChunkPause: .zero
        )

        let report = try await control.send(handle: "wm-a-1", text: Self.payload1200, submit: false)

        let sendKeys = recorder.calls.filter { $0.contains("send-keys") && $0.contains("-l") }
        #expect(report.bytesOffered == 1200)
        #expect(report.chunks == 5)
        #expect(sendKeys.count == 5)
        #expect(sendKeys.compactMap(\.last).joined() == Self.payload1200)
        #expect(sendKeys.allSatisfy { ($0.last?.utf8.count ?? 0) <= TmuxSessionControl.defaultSendChunkBytes })
    }

    /// A failure partway through leaves the pane holding part of the payload, and the
    /// message is the only place a caller can learn that before resending.
    @Test("A chunk that fails names its position in the payload")
    func failedChunkNamesItself() async {
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output(""),
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                RecordingRunner.failure,
            ]
        )
        let control = TmuxSessionControl(
            socketLabel: "scratch",
            run: recorder.runner,
            environment: [:],
            sendChunkPause: .zero
        )

        do {
            _ = try await control.send(handle: "wm-a-1", text: Self.payload1200, submit: false)
            Issue.record("send should have thrown")
        } catch let error as TmuxSessionControl.ControlError {
            #expect(error.localizedDescription.contains("chunk 2 of 5"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// The gap between chunks is the mitigation itself — it is what lets a reader empty
    /// the pty input queue between writes — so a wall-clock lower bound is the property
    /// here rather than a proxy for it. Safe as a deadline because it only ever fails
    /// low: a slow machine makes the send take longer, never shorter.
    @Test("Chunks are paced apart, not fired back to back")
    func chunksArePaced() async throws {
        let pause = Duration.milliseconds(50)
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                // The payload is one long line, so the tty is asked what mode it is in;
                // no answer leaves the send to the read-back, which is this test's path.
                RecordingRunner.output(""),
                RecordingRunner.output("$ "),
                RecordingRunner.ok, RecordingRunner.ok, RecordingRunner.ok, RecordingRunner.ok, RecordingRunner.ok,
                RecordingRunner.output(Self.payload1200),
            ]
        )
        let control = TmuxSessionControl(
            socketLabel: "scratch",
            run: recorder.runner,
            environment: [:],
            sendChunkPause: pause
        )

        let started = ContinuousClock.now
        let report = try await control.send(handle: "wm-a-1", text: Self.payload1200, submit: false)
        let elapsed = ContinuousClock.now - started

        #expect(report.chunks == 5)
        #expect(report.verification == .paneShowsText)
        #expect(elapsed >= pause * 4)
    }

    // MARK: - Canonical line limit

    /// `stty -a` spells a cleared flag `-icanon`, which contains `icanon`, so the
    /// negation has to be read as its own token.
    @Test("Canonical mode is read from stty's tokens, not from a substring")
    func canonicalModeParsing() {
        let canonical = "lflags: icanon isig iexten echo echoe -echok echoke -echonl echoctl"
        let raw = "lflags: -icanon -isig -iexten -echo -echoe -echok echoke -echonl echoctl"

        #expect(TmuxSessionControl.isCanonical(sttyOutput: canonical) == true)
        #expect(TmuxSessionControl.isCanonical(sttyOutput: raw) == false)
        // A terminal that did not say leaves the caller to decide, rather than being
        // read as either answer.
        #expect(TmuxSessionControl.isCanonical(sttyOutput: "speed 9600 baud; 50 rows;") == nil)
    }

    /// The limit counts the terminator, so a line's own bytes have to fit in one less
    /// — and it counts the bytes that reach the terminal, which on this platform are
    /// the decomposed ones.
    @Test("A line overruns the canonical limit at the size the kernel discards")
    func canonicalOverrunBoundary() {
        let limit = TmuxSessionControl.canonicalLineLimit
        #expect(limit == 1024)
        #expect(TmuxSessionControl.overrunsCanonicalLine(String(repeating: "a", count: limit - 1)) == false)
        #expect(TmuxSessionControl.overrunsCanonicalLine(String(repeating: "a", count: limit)))
        // Short lines either side of a long one do not excuse it.
        let mixed = "short\n" + String(repeating: "a", count: limit) + "\nshort"
        #expect(TmuxSessionControl.overrunsCanonicalLine(mixed))
        #expect(TmuxSessionControl.overrunsCanonicalLine("short\nlines\nonly") == false)
        // 800 bytes composed, 1200 decomposed: it is the decomposed form that arrives.
        let composed = String(repeating: "\u{00E9}", count: 400)
        #expect(composed.utf8.count < limit)
        #expect(TmuxSessionControl.overrunsCanonicalLine(composed))
    }

    // MARK: - Read-back

    /// A composer wraps a long line wherever its width runs out, and the capture
    /// carries that break through the middle of the text. Matching without
    /// whitespace is what keeps a correct send from reading as a lost one.
    @Test("The read-back finds the payload's tail across a line the composer wrapped")
    func verificationSeesWrappedText() async throws {
        let text = "please run the full test suite and report the failing line"
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                RecordingRunner.output("> please run the full test suite and report the\nfailing line\n"),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: text, submit: false)

        #expect(report.verification == .paneShowsText)
    }

    /// The bug #1450 reports: the send succeeded, the count was right, and none of it
    /// arrived. Only the read-back can tell those apart.
    @Test("A pane that does not show the text reports unverified, not a byte count")
    func verificationReportsAbsentText() async throws {
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: "the whole brief goes here", submit: false)

        #expect(report.verification == .paneMissingText)
        #expect(report.bytesOffered == "the whole brief goes here".utf8.count)
    }

    /// The loss #1450 reports takes the front, so a check that only looked at the tail
    /// would have called the reported failure a success.
    @Test("A payload whose front was cut reads as unverified even though its tail is there")
    func verificationCatchesAFrontCut() async throws {
        let text = "read the brief before you start\nthen run the whole suite and report"
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                // Everything before the cut is gone; the tail rendered intact.
                RecordingRunner.output("> run the whole suite and report"),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: text, submit: false)

        #expect(report.verification == .paneMissingText)
    }

    /// Scrollback outlives a send, so presence alone would let the second copy of a
    /// resent brief verify against the first — precisely when a caller is resending
    /// because the first attempt is in doubt.
    @Test("A send that adds nothing to a pane already showing the text reads as unverified")
    func verificationIsScopedToThisSend() async throws {
        let text = "run the whole suite and report"
        let onScreen = "> run the whole suite and report"
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output(onScreen),
                RecordingRunner.ok,
                RecordingRunner.output(onScreen),
                RecordingRunner.output(onScreen),
                RecordingRunner.output(onScreen),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: text, submit: false)

        #expect(report.verification == .paneMissingText)
    }

    /// Without a baseline there is no way to tell a copy this send put on the pane from
    /// one that was already there, which is the whole point of taking one.
    @Test("A failed baseline capture leaves the send unchecked, not compared against nothing")
    func failedBaselineIsNotAnEmptyBaseline() async throws {
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.failure,
                RecordingRunner.ok,
                // The pane does show the text — but it may have shown it before, too.
                RecordingRunner.output("the whole brief goes here"),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: "the whole brief goes here", submit: false)

        #expect(report.verification == .notChecked)
    }

    /// A capture that failed carries no information, so it must not overwrite one that
    /// looked and came back empty-handed.
    @Test("A failed capture after a successful miss leaves the miss standing")
    func failedCaptureDoesNotEraseAMiss() async throws {
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.failure,
                RecordingRunner.failure,
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: "the whole brief goes here", submit: false)

        #expect(report.verification == .paneMissingText)
    }

    @Test("A capture that does not answer leaves the send unchecked rather than failed")
    func verificationUnavailableIsNotAFailure() async throws {
        // Every attempt fails, so the answer is "could not look" rather than a miss
        // that happened to be the last capture in the queue.
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok, RecordingRunner.failure, RecordingRunner.ok,
                RecordingRunner.failure, RecordingRunner.failure, RecordingRunner.failure,
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: "the whole brief goes here", submit: false)

        #expect(report.verification == .notChecked)
    }

    /// Briefs are read from files and end in a newline, so anchoring on the literal
    /// last line would leave the commonest payload of all unchecked.
    @Test("A payload ending in a newline is still checked, against its last line with content")
    func verificationSkipsTrailingBlankLines() async throws {
        let text = "read the brief\nthen run the suite\n\n"
        let recorder = RecordingRunner(
            responses: [
                RecordingRunner.ok,
                RecordingRunner.output("$ "),
                RecordingRunner.ok,
                RecordingRunner.output("> read the brief\n> then run the suite"),
            ]
        )
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: text, submit: false)

        #expect(report.verification == .paneShowsText)
    }

    @Test("Text too short to prove anything is not looked for at all")
    func shortTextIsNotChecked() async throws {
        let recorder = RecordingRunner(responses: [])
        let control = TmuxSessionControl(socketLabel: "scratch", run: recorder.runner, environment: [:])

        let report = try await control.send(handle: "wm-a-1", text: "y", submit: false)

        #expect(report.verification == .notChecked)
        #expect(recorder.calls.contains { $0.contains("capture-pane") } == false)
    }

    // MARK: - Live tmux

    /// 1200 bytes — the size class #1450 lost — in mixed scalar widths, so a split
    /// landing inside a character shows up as corruption rather than as a byte count
    /// that still adds up.
    private static let payload1200: String =
        String(repeating: "abcdefghij", count: 100) + String(repeating: "\u{00E9}", count: 100)

    /// 900 bytes on one line: under the kernel's canonical limit, so the same reader
    /// that loses `payload1200` keeps this one.
    private static let payload900 = String(repeating: "abcdefghij", count: 90)

    /// tmux is the whole substrate of these verbs, so a machine without it has nothing
    /// to prove and skips rather than fails.
    private static var tmuxIsInstalled: Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["tmux", "-V"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
        } catch {
            return false
        }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    /// One disposable tmux world: its own socket label and a `TMUX_TMPDIR` inside the
    /// directory teardown removes, so the socket file leaves with it (#1443). Nothing
    /// here can reach a desktop's `-L workspaces` sessions.
    private struct ScratchTmux {
        let root: URL
        let label: String
        let handle = "ws1450-receiver"

        init() throws {
            let token = UUID().uuidString.prefix(8).lowercased()
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws1450-\(token)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            label = "ws1450-\(token)"
        }

        var environment: [String: String] {
            var environment = TmuxSessionProbe.defaultEnvironment
            environment["TMUX_TMPDIR"] = root.path
            return environment
        }

        var control: TmuxSessionControl {
            TmuxSessionControl(socketLabel: label, environment: environment)
        }

        func path(_ name: String) -> URL {
            root.appendingPathComponent(name)
        }

        func teardown() {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            kill.arguments = ["tmux", "-L", label, "kill-server"]
            kill.environment = environment
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            do {
                try kill.run()
                kill.waitUntilExit()
            } catch {
                // Nothing to kill is the outcome teardown wanted anyway.
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Waits on the file the receiver writes rather than on a clock, and returns
    /// whatever it holds when the budget runs out so the failure names what arrived.
    private func waitForText(
        at url: URL,
        deadline: TimeInterval,
        until satisfied: (String) -> Bool
    ) async -> String {
        let end = Date().addingTimeInterval(deadline)
        var text = ""
        repeat {
            let data = (try? Data(contentsOf: url)) ?? Data()
            text = String(decoding: data, as: UTF8.self)
            if satisfied(text) {
                return text
            }
            try? await Task.sleep(for: .milliseconds(50))
        } while Date() < end
        return text
    }

    /// The regression this closes: a payload over the pty input queue's depth,
    /// delivered whole to a reader that drains it.
    @Test(
        "A 1200-byte payload reaches a draining reader byte for byte",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; only a real server can prove the send")
    )
    func longPayloadReachesTheReader() async throws {
        let scratch = try ScratchTmux()
        defer { scratch.teardown() }
        let control = scratch.control
        let ready = scratch.path("ready")
        let out = scratch.path("received")

        try await control.launch(
            handle: scratch.handle,
            directory: scratch.root,
            command: "stty raw -echo; : > '\(ready.path)'; exec cat > '\(out.path)'"
        )
        let budget = await LaunchBudget.deadline(launches: 3, floor: 5, ceiling: 60)
        _ = await waitForText(at: ready, deadline: budget) { _ in FileManager.default.fileExists(atPath: ready.path) }

        let report = try await control.send(handle: scratch.handle, text: Self.payload1200, submit: false)
        // Canonically equivalent rather than byte-identical: Foundation hands a child
        // its arguments in the file-system representation, which on macOS is
        // decomposed, so a composed character reaches the pane as its decomposition.
        // `chunksReproduceTheInput` is what pins the chunker itself to the bytes.
        let received = await waitForText(at: out, deadline: budget) {
            $0.precomposedStringWithCanonicalMapping == Self.payload1200
        }

        #expect(report.chunks == 5)
        #expect(received.precomposedStringWithCanonicalMapping == Self.payload1200)
        // A receiver that does not echo is why an unverified send is a warning rather
        // than an error: every character arrived and the pane still shows none of it.
        #expect(report.verification == .paneMissingText)
    }

    /// The bug's own shape, with the echo turned off so the loss is visible on its own:
    /// a canonical-mode reader discards a line longer than the kernel will hold, and
    /// nothing arrives. What changed is that the send names the cause instead of
    /// reporting the byte count it was handed.
    @Test(
        "A canonical reader over the line limit loses the line, and the send says why",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; only a real server can prove the send")
    )
    func lostPayloadIsReportedUnverified() async throws {
        let scratch = try ScratchTmux()
        defer { scratch.teardown() }
        let control = scratch.control
        let ready = scratch.path("ready")
        let out = scratch.path("received")

        try await control.launch(
            handle: scratch.handle,
            directory: scratch.root,
            command: "stty -echo; : > '\(ready.path)'; exec cat > '\(out.path)'"
        )
        let budget = await LaunchBudget.deadline(launches: 3, floor: 5, ceiling: 60)
        _ = await waitForText(at: ready, deadline: budget) { _ in FileManager.default.fileExists(atPath: ready.path) }

        let report = try await control.send(handle: scratch.handle, text: Self.payload1200, submit: true)
        // Waiting for an arrival that cannot happen is pure cost, so this negative
        // check gets its own small bound: the kernel discarded the line before the
        // reader was ever offered it, and no amount of machine slowness changes that.
        let negativeBudget = await LaunchBudget.deadline(launches: 2, floor: 1, ceiling: 20)
        let received = await waitForText(at: out, deadline: negativeBudget) { !$0.isEmpty }

        #expect(report.bytesOffered == 1200)
        #expect(report.verification == .canonicalOverrun)
        #expect(received.utf8.count < Self.payload1200.utf8.count)
    }

    /// The case the read-back cannot judge, and the reason the mode is asked from the
    /// sender side: this is a pane's *default* state, echo and all. The line discipline
    /// puts every byte on the screen and then throws the line away, so a check that
    /// reads the pane back sees both ends of a payload its reader never got.
    @Test(
        "A default-mode reader that will discard the line is reported, not confirmed by its own echo",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; only a real server can prove the send")
    )
    func echoingCanonicalReaderIsNotProof() async throws {
        let scratch = try ScratchTmux()
        defer { scratch.teardown() }
        let control = scratch.control
        let ready = scratch.path("ready")
        let out = scratch.path("received")

        // No `stty` at all: the pane's own default, which is canonical with echo on.
        try await control.launch(
            handle: scratch.handle,
            directory: scratch.root,
            command: ": > '\(ready.path)'; exec cat > '\(out.path)'"
        )
        let budget = await LaunchBudget.deadline(launches: 3, floor: 5, ceiling: 60)
        _ = await waitForText(at: ready, deadline: budget) { _ in FileManager.default.fileExists(atPath: ready.path) }

        let report = try await control.send(handle: scratch.handle, text: Self.payload1200, submit: true)

        #expect(report.verification == .canonicalOverrun)
    }

    /// The other side of the same probe: canonical mode is not itself the problem. A
    /// line the kernel will hold is kept, and its echo is the evidence it was.
    @Test(
        "A default-mode reader under the line limit still verifies by its echo",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; only a real server can prove the send")
    )
    func echoingCanonicalReaderUnderTheLimitVerifies() async throws {
        let scratch = try ScratchTmux()
        defer { scratch.teardown() }
        let control = scratch.control
        let ready = scratch.path("ready")
        let out = scratch.path("received")

        try await control.launch(
            handle: scratch.handle,
            directory: scratch.root,
            command: ": > '\(ready.path)'; exec cat > '\(out.path)'"
        )
        let budget = await LaunchBudget.deadline(launches: 3, floor: 5, ceiling: 60)
        _ = await waitForText(at: ready, deadline: budget) { _ in FileManager.default.fileExists(atPath: ready.path) }

        let report = try await control.send(handle: scratch.handle, text: Self.payload900, submit: false)

        #expect(report.chunks == 4)
        #expect(report.verification == .paneShowsText)
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
