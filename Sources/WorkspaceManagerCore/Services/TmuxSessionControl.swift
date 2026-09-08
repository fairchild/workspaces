//
//  TmuxSessionControl.swift
//  WorkspaceManagerCore
//
//  Creates, reads, and writes detached terminal sessions on the dedicated
//  `-L workspaces` tmux socket — the same substrate the app launches its own
//  terminals on, so a session the CLI starts headlessly is one the app can adopt.
//  Command composition is pure and separately testable; execution is injected so
//  every answer is reachable without a real tmux server.
//

import Foundation

public struct TmuxSessionControl: Sendable {
    /// Runs a command and yields its exit code plus captured output, or `nil` on
    /// launch failure or timeout.
    public typealias CommandRunner =
        @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String]?) async
        -> ProcessResult?

    /// The socket label every command carries. Defaults to the app's own
    /// `workspaces` server; an isolated run (a test, a second checkout) names its
    /// own so it cannot reach into a live desktop's sessions.
    public static let defaultSocketLabel = TmuxSessionProbe.defaultSocketLabel

    /// Names the socket label for a launch that must not touch the desktop's
    /// server. Honored by the app as well as the CLI since #1267, so an isolated
    /// run exercises the app's own launch/probe/kill lane end to end.
    public static let socketLabelEnvironmentKey = TmuxSessionProbe.socketLabelEnvironmentKey

    /// Scrollback lines `read` returns when the caller names no bound.
    public static let defaultCaptureLines = 200

    /// Bytes handed to tmux per `send-keys -l` call.
    ///
    /// A pty's input queue holds about 1022 bytes, and everything sitting in it is
    /// discarded when the receiving process flushes its input — which is what a TUI
    /// does the moment it enters raw mode, and what the kernel does when a
    /// canonical-mode line overruns the queue. Neither tmux nor `send-keys` loses
    /// anything; the queue does. So the payload's exposure is however much of it is
    /// undrained at once, and chunking well under the queue's depth is what bounds
    /// that to a chunk instead of a kilobyte.
    public static let defaultSendChunkBytes = 256

    /// The gap between chunks. A reader wakes on input and empties the queue in
    /// well under a millisecond; this is the room it needs, at a cost of a tenth of
    /// a second per kilobyte sent.
    public static let defaultSendChunkPause = Duration.milliseconds(25)

    /// How many trailing characters of the payload the read-back looks for. Long
    /// enough not to match by accident, short enough to survive a composer that
    /// wraps or reflows everything before it.
    public static let verificationFragmentLength = 24

    /// The kernel's limit on a canonical-mode input line, from `<sys/syslimits.h>`:
    /// 1024 on this platform, and the probe agrees — a 1023-byte line arrives, a
    /// 1024-byte one never reaches the reader at all.
    ///
    /// What the kernel does is narrower than "discards the line": it keeps the prefix
    /// it accepted, echoing that much, and drops what arrives once the queue is full —
    /// the terminator included. Dropping the terminator is what strands the line,
    /// because a canonical reader is offered nothing until one arrives. So a line's own
    /// bytes have to fit in one less than the limit, and a payload that overruns leaves
    /// its prefix on the pane while its reader waits for a newline that was thrown
    /// away.
    static let canonicalLineLimit = Int(MAX_CANON)

    /// Captures the read-back will take before calling a send unverified, and the gap
    /// between them. The echo of what was typed reaches the pane through the pty and
    /// tmux's event loop, so the first capture can be early rather than wrong.
    public static let verificationAttempts = 3
    public static let verificationRetryPause = Duration.milliseconds(40)

    /// Geometry a detached session is created at. tmux would otherwise default to
    /// 80x24, and an agent that renders into 80 columns keeps that wrapping in the
    /// scrollback `read` returns — a client attaching later resizes the session but
    /// cannot unwrap what was already written.
    public static let detachedPaneWidth = 200
    public static let detachedPaneHeight = 50

    public let socketLabel: String
    private let run: CommandRunner
    private let environment: [String: String]
    private let sendChunkBytes: Int
    private let sendChunkPause: Duration

    public init(
        socketLabel: String = TmuxSessionControl.defaultSocketLabel,
        run: @escaping CommandRunner = TmuxSessionControl.defaultRunner,
        environment: [String: String] = TmuxSessionProbe.defaultEnvironment,
        sendChunkBytes: Int = TmuxSessionControl.defaultSendChunkBytes,
        sendChunkPause: Duration = TmuxSessionControl.defaultSendChunkPause
    ) {
        self.socketLabel = socketLabel
        self.run = run
        self.environment = environment
        self.sendChunkBytes = sendChunkBytes
        self.sendChunkPause = sendChunkPause
    }

    /// Resolves the socket label from a launch environment, falling back to the
    /// app's server. An empty override reads as unset rather than as a nameless
    /// socket.
    public static func socketLabel(from environment: [String: String]) -> String {
        TmuxSessionProbe.resolvedSocketLabel(from: environment)
    }

    // MARK: - Failure

    public enum ControlError: Error, LocalizedError, Equatable {
        case tmuxUnavailable
        case handleAlreadyLive(handle: String)
        case handleNotLive(handle: String)
        case commandFailed(verb: String, handle: String, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .tmuxUnavailable:
                return "tmux is not available on PATH. Install tmux (brew install tmux) and try again."
            case .handleAlreadyLive(let handle):
                return
                    "A terminal session named '\(handle)' is already running. Read it with "
                    + "'workspaces ws read \(handle)', or pass --name <label> to launch a sibling session."
            case .handleNotLive(let handle):
                return
                    "No terminal session named '\(handle)' is running. It either never started or its "
                    + "command has exited; 'workspaces ws launch' starts a new one."
            case .commandFailed(let verb, let handle, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = detail.isEmpty ? "" : ": \(detail)"
                return "tmux \(verb) failed for '\(handle)'\(suffix)"
            }
        }
    }

    // MARK: - Command composition

    /// `new-session -d` with the pane's command run through a login shell, so a
    /// launched agent resolves the same PATH an interactive `workspaces open`
    /// would give it. Without a command the pane is a plain login shell.
    ///
    /// The session's lifetime is its command's: no `remain-on-exit`, matching both
    /// the app's own launches and what a person typing tmux by hand would get.
    public static func newSessionArguments(
        socketLabel: String,
        handle: String,
        directory: URL,
        command: String?
    ) -> [String] {
        var arguments = [
            "tmux", "-L", socketLabel, "new-session", "-d",
            "-s", handle,
            "-c", directory.path,
            "-x", String(detachedPaneWidth), "-y", String(detachedPaneHeight),
        ]
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append(contentsOf: ["--", "/bin/zsh", "-lc", command])
        }
        return arguments
    }

    /// `capture-pane -p` over the last `lines` rows of scrollback. `-S -<n>` starts
    /// the capture `n` lines above the visible pane, so a caller asking for more
    /// than a screenful gets history rather than padding.
    public static func capturePaneArguments(
        socketLabel: String,
        handle: String,
        lines: Int
    ) -> [String] {
        [
            "tmux", "-L", socketLabel, "capture-pane", "-p",
            "-t", paneTarget(handle),
            "-S", "-\(max(1, lines))",
        ]
    }

    /// `send-keys -l` writes the text literally, so a payload containing `Enter`,
    /// `C-c`, or a stray semicolon reaches the agent as characters rather than as
    /// key names tmux would interpret.
    public static func sendTextArguments(
        socketLabel: String,
        handle: String,
        text: String
    ) -> [String] {
        ["tmux", "-L", socketLabel, "send-keys", "-t", paneTarget(handle), "-l", "--", text]
    }

    /// Splits `text` into pieces of at most `limit` UTF-8 bytes, cut on scalar
    /// boundaries so every piece is itself valid UTF-8 — each one becomes an argv
    /// string, and a scalar cut in half would reach the pane as replacement
    /// characters. Concatenating the pieces reproduces the input exactly.
    ///
    /// The one piece that may exceed `limit` is a single scalar wider than it: the
    /// alternative is to corrupt the character, and the sizes this is called with are
    /// hundreds of bytes against a four-byte maximum.
    public static func textChunks(
        _ text: String,
        limit: Int = TmuxSessionControl.defaultSendChunkBytes
    ) -> [String] {
        let bound = max(1, limit)
        var chunks: [String] = []
        var current = String.UnicodeScalarView()
        var currentBytes = 0

        for scalar in text.unicodeScalars {
            let width = utf8Width(scalar)
            if currentBytes + width > bound, !current.isEmpty {
                chunks.append(String(current))
                current = String.UnicodeScalarView()
                currentBytes = 0
            }
            current.append(scalar)
            currentBytes += width
        }
        if !current.isEmpty {
            chunks.append(String(current))
        }
        return chunks
    }

    static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x1_0000: return 3
        default: return 4
        }
    }

    /// The two fragments a read-back looks for: the start of the payload's first line
    /// with content and the end of its last.
    ///
    /// Both ends, because the loss this exists to catch takes the *front*: a tail that
    /// is present says nothing about the head, and #1450's payloads arrived with their
    /// first kilobyte gone and their tail intact. Fragments are drawn from a single
    /// line each and matched without whitespace, because a composer wraps a long line
    /// wherever its width runs out — a break the capture carries through the middle of
    /// anything long enough to be worth checking — while a composer that decorates
    /// each line puts a prompt marker or a continuation glyph *between* lines, where a
    /// fragment spanning a break would not survive. Payloads routinely start or end
    /// with a blank line, so both ends walk inward to a line with content; too little
    /// content to identify proves nothing, and is not looked for at all.
    struct SendExpectation: Equatable {
        let head: String
        let tail: String
    }

    static func verificationExpectation(for text: String) -> SendExpectation? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.filter { !$0.isWhitespace }) }
            .filter { $0.count >= 4 }
        guard let first = lines.first, let last = lines.last else { return nil }
        return SendExpectation(
            head: String(first.prefix(verificationFragmentLength)),
            tail: String(last.suffix(verificationFragmentLength))
        )
    }

    /// Whitespace-insensitive for the same reason the fragments are.
    static func compacted(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    /// How many times `fragment` appears in an already-compacted capture. A count
    /// rather than a yes/no because a pane keeps its scrollback: the same brief sent
    /// twice would otherwise verify against its own first copy, and the send that
    /// needs proving is the one that just happened.
    static func occurrences(of fragment: String, inCompacted captured: String) -> Int {
        guard !fragment.isEmpty else { return 0 }
        var count = 0
        var searchRange = captured.startIndex..<captured.endIndex
        while let found = captured.range(of: fragment, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<captured.endIndex
        }
        return count
    }

    /// The pane's terminal device — where its reader's line discipline can be asked
    /// what mode it is in.
    public static func paneTTYArguments(socketLabel: String, handle: String) -> [String] {
        ["tmux", "-L", socketLabel, "display-message", "-p", "-t", paneTarget(handle), "#{pane_tty}"]
    }

    /// `stty -a` reads another process's terminal without opening it or changing it,
    /// which is what keeps this a question rather than an intervention.
    public static func ttyModesArguments(tty: String) -> [String] {
        ["stty", "-f", tty, "-a"]
    }

    /// Whether `stty -a` output says the line discipline is canonical, or `nil` when
    /// it does not say. The flag is a bare word when set and `-` prefixed when clear,
    /// so the negation has to be matched as its own token rather than searched for —
    /// `contains("icanon")` on the raw text is true either way.
    static func isCanonical(sttyOutput: String) -> Bool? {
        let tokens = sttyOutput.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "," })
        if tokens.contains("icanon") { return true }
        if tokens.contains("-icanon") { return false }
        return nil
    }

    /// Whether any line of `text` is longer than a canonical input line can hold.
    ///
    /// Measured decomposed, because that is the form a child's arguments reach the
    /// terminal in on this platform, and a line that fits composed can overrun once
    /// it does not.
    ///
    /// This asks only about the payload's own lines. Bytes already queued from an
    /// earlier send that was never submitted count against the same limit, and a short
    /// payload can complete an overrun it did not start — #1600.
    static func overrunsCanonicalLine(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            String(line).decomposedStringWithCanonicalMapping.utf8.count >= canonicalLineLimit
        }
    }

    /// The submit keystroke, sent as a separate call precisely because the text
    /// before it is literal.
    public static func sendEnterArguments(socketLabel: String, handle: String) -> [String] {
        ["tmux", "-L", socketLabel, "send-keys", "-t", paneTarget(handle), "Enter"]
    }

    public static func hasSessionArguments(socketLabel: String, handle: String) -> [String] {
        ["tmux", "-L", socketLabel, "has-session", "-t", "=\(handle)"]
    }

    /// The pane every session verb addresses: the active pane of the exactly-named
    /// session's current window. `=` forces the exact session match `has-session`
    /// already uses; the trailing colon is what makes the string a *pane* target —
    /// `-t =name` alone is a session target and `capture-pane` rejects it.
    static func paneTarget(_ handle: String) -> String {
        "=\(handle):"
    }

    /// Drops the trailing blank rows `capture-pane` pads to the pane's height, so a
    /// young session reads as the few lines it has produced rather than as those
    /// lines followed by a screenful of nothing.
    static func trimmingTrailingBlankLines(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Verbs

    public func isLive(handle: String) async -> Bool {
        let result = await run(
            "/usr/bin/env",
            Self.hasSessionArguments(socketLabel: socketLabel, handle: handle),
            environment
        )
        return result?.success == true
    }

    /// Starts a detached session and returns its handle. Fails closed when the
    /// handle is taken: `new-session` without `-A` would error anyway, and naming
    /// the live session is the answer a caller needs.
    @discardableResult
    public func launch(
        handle: String,
        directory: URL,
        command: String?
    ) async throws -> String {
        if await isLive(handle: handle) {
            throw ControlError.handleAlreadyLive(handle: handle)
        }
        guard
            let result = await run(
                "/usr/bin/env",
                Self.newSessionArguments(
                    socketLabel: socketLabel,
                    handle: handle,
                    directory: directory,
                    command: command
                ),
                environment
            )
        else {
            throw ControlError.tmuxUnavailable
        }
        guard result.success else {
            throw ControlError.commandFailed(verb: "new-session", handle: handle, stderr: result.stderr)
        }
        return handle
    }

    /// The session's scrollback, newest content last — the shape a person reading a
    /// terminal expects, and the shape `tail` already speaks.
    public func read(handle: String, lines: Int = TmuxSessionControl.defaultCaptureLines) async throws -> String {
        guard await isLive(handle: handle) else {
            throw ControlError.handleNotLive(handle: handle)
        }
        guard
            let result = await run(
                "/usr/bin/env",
                Self.capturePaneArguments(socketLabel: socketLabel, handle: handle, lines: lines),
                environment
            )
        else {
            throw ControlError.tmuxUnavailable
        }
        guard result.success else {
            throw ControlError.commandFailed(verb: "capture-pane", handle: handle, stderr: result.stderr)
        }
        return Self.trimmingTrailingBlankLines(result.stdout)
    }

    /// Types `text` into the session, optionally submitting it, and reports what was
    /// handed to tmux and whether the pane came to show it.
    ///
    /// The payload goes out in `sendChunkBytes` pieces with `sendChunkPause` between
    /// them, because the pty input queue between tmux and the pane's process is about
    /// a kilobyte deep and its contents are discarded whenever that process flushes
    /// its input. Chunking bounds how much of the payload is ever sitting there. (The
    /// bound is on the payload's own UTF-8 bytes; where macOS decomposes a composed
    /// character on its way into a child's arguments the wire form is longer — at worst
    /// three times, a precomposed Hangul syllable becoming three 3-byte Jamo — so a
    /// 256-byte chunk can reach 768 on the wire, still under the queue's depth, but by
    /// a smaller margin than the payload's own size suggests.)
    ///
    /// The pane is captured once before the send and again after, so what is looked
    /// for is a *new* occurrence of the payload's ends rather than any occurrence —
    /// scrollback outlives a send, and the same text sent twice would otherwise prove
    /// itself. The read-back runs before the submit keystroke: after Enter the composer
    /// has consumed the text, so the pane could not show it and the check would fail on
    /// every correct send.
    ///
    /// Before any of that, a payload with an over-long line asks the pane's terminal
    /// what mode it is in, because there is one case the read-back cannot judge: a
    /// canonical reader is offered nothing until a line's terminator arrives, and an
    /// over-long line is exactly where the kernel drops that terminator — keeping the
    /// prefix it accepted, and echoing it. Reading that echo back would confirm a
    /// delivery that did not happen, which is why it is answered from the sender side
    /// instead. A terminal that will not say leaves the send `notChecked`: unknown is
    /// not the same answer as safe.
    ///
    /// Not `@discardableResult`: dropping the answer is the bug this closes.
    public func send(handle: String, text: String, submit: Bool) async throws -> SendReport {
        guard await isLive(handle: handle) else {
            throw ControlError.handleNotLive(handle: handle)
        }

        let fate = await canonicalLineFate(handle: handle, text: text)
        let expectation = fate == .delivered ? Self.verificationExpectation(for: text) : nil
        let baseline = expectation == nil ? nil : await capturedPane(handle: handle)

        let chunks = Self.textChunks(text, limit: sendChunkBytes)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            guard
                let result = await run(
                    "/usr/bin/env",
                    Self.sendTextArguments(socketLabel: socketLabel, handle: handle, text: chunk),
                    environment
                )
            else {
                // Only the first chunk can mean "no tmux". After that something was
                // already typed into the pane, and a caller told it was unavailable
                // would retry from the start and double the prefix.
                guard index == 0 else {
                    throw ControlError.commandFailed(
                        verb: "send-keys (chunk \(index + 1) of \(chunks.count))",
                        handle: handle,
                        stderr: "tmux did not answer; \(index) chunk(s) were already typed into the pane"
                    )
                }
                throw ControlError.tmuxUnavailable
            }
            guard result.success else {
                // Which chunk, because a failure after the first one leaves the pane
                // holding part of the payload — a caller that resends blind would
                // double it, and the message is the only place that can say so.
                throw ControlError.commandFailed(
                    verb: "send-keys (chunk \(index + 1) of \(chunks.count))",
                    handle: handle,
                    stderr: result.stderr
                )
            }
            if index + 1 < chunks.count {
                try await Task.sleep(for: sendChunkPause)
            }
        }

        var verification = SendVerification.notChecked
        var cause: String?
        switch fate {
        case .discarded:
            verification = .canonicalOverrun
            cause = Self.canonicalOverrunCause
        case .unknown:
            // Nothing is checked and nothing is claimed. The read-back is skipped
            // rather than run and disbelieved, because running it is what would put a
            // `verified` on a send that may already be lost.
            cause = Self.unreadableModeCause
        case .delivered:
            // No baseline is not an empty baseline: without one, a copy already in the
            // scrollback is indistinguishable from a copy this send put there, which is
            // the false positive the baseline exists to prevent.
            if let expectation, let baseline {
                verification = await paneVerification(handle: handle, expectation: expectation, baseline: baseline)
                if verification == .paneMissingText {
                    cause = Self.paneMissingTextCause
                }
            }
        }

        if submit {
            try Task.checkCancellation()
            guard
                let enterResult = await run(
                    "/usr/bin/env",
                    Self.sendEnterArguments(socketLabel: socketLabel, handle: handle),
                    environment
                )
            else {
                throw ControlError.tmuxUnavailable
            }
            guard enterResult.success else {
                throw ControlError.commandFailed(verb: "send-keys Enter", handle: handle, stderr: enterResult.stderr)
            }
        }

        return SendReport(
            bytesOffered: text.utf8.count,
            chunks: chunks.count,
            verification: verification,
            cause: cause
        )
    }

    /// What the pane's reader will do with this payload's longest line.
    ///
    /// Asked only when the payload has a line past the kernel's limit at all: the
    /// answer costs two commands, and a payload whose lines all fit is offered to its
    /// reader in either mode, so an ordinary send never pays for the question.
    ///
    /// `unknown` is its own answer rather than an optimistic `delivered`, because the
    /// two are not interchangeable on the one payload where it matters. A terminal
    /// that will not say what mode it is in is a terminal whose echo cannot settle
    /// this, and treating silence as "not canonical" hands the question back to the
    /// read-back — the false success this whole probe exists to remove.
    private func canonicalLineFate(handle: String, text: String) async -> CanonicalLineFate {
        guard Self.overrunsCanonicalLine(text) else {
            return .delivered
        }
        guard
            let ttyResult = await run(
                "/usr/bin/env",
                Self.paneTTYArguments(socketLabel: socketLabel, handle: handle),
                environment
            ),
            ttyResult.success
        else {
            return .unknown
        }
        let tty = ttyResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // A device path or nothing: `stty -f` would happily open whatever else tmux
        // handed back, and this is meant to read a terminal, not to find out what else
        // it can open.
        guard tty.hasPrefix("/dev/") else {
            return .unknown
        }
        guard
            let modesResult = await run("/usr/bin/env", Self.ttyModesArguments(tty: tty), environment),
            modesResult.success,
            let canonical = Self.isCanonical(sttyOutput: modesResult.stdout)
        else {
            return .unknown
        }
        return canonical ? .discarded : .delivered
    }

    /// The pane's visible text with its whitespace removed, or `nil` when the capture
    /// did not answer.
    private func capturedPane(handle: String) async -> String? {
        guard
            let result = await run(
                "/usr/bin/env",
                Self.capturePaneArguments(
                    socketLabel: socketLabel,
                    handle: handle,
                    lines: Self.defaultCaptureLines
                ),
                environment
            ),
            result.success
        else {
            return nil
        }
        return Self.compacted(result.stdout)
    }

    /// Whether the pane gained both ends of the payload. A capture that does not
    /// answer leaves the send unchecked rather than failing it — the text may well
    /// have arrived, and the caller is owed the distinction between "looked and did
    /// not find it" and "could not look". A miss already seen is never downgraded to
    /// unchecked by a later capture that failed: the look that succeeded is the one
    /// that carries information.
    ///
    /// Retried, because a pane that has the text and a pane that has not rendered it
    /// yet look identical: the echo travels back through the pty and tmux's event loop
    /// after `send-keys` has already returned. A found payload answers on the first
    /// attempt, so only a send that really is in doubt pays for the waiting.
    private func paneVerification(
        handle: String,
        expectation: SendExpectation,
        baseline: String
    ) async -> SendVerification {
        let beforeHead = Self.occurrences(of: expectation.head, inCompacted: baseline)
        let beforeTail = Self.occurrences(of: expectation.tail, inCompacted: baseline)

        var outcome = SendVerification.notChecked
        for attempt in 0..<Self.verificationAttempts {
            if Task.isCancelled {
                return outcome
            }
            if attempt > 0 {
                try? await Task.sleep(for: Self.verificationRetryPause)
            }
            guard let captured = await capturedPane(handle: handle) else {
                continue
            }
            if Self.occurrences(of: expectation.head, inCompacted: captured) > beforeHead,
                Self.occurrences(of: expectation.tail, inCompacted: captured) > beforeTail
            {
                return .paneShowsText
            }
            outcome = .paneMissingText
        }
        return outcome
    }

    /// Production runner: `ProcessRunner.run` with the same short deadline the
    /// probe uses, so a wedged tmux server surfaces as no answer instead of a
    /// stalled CLI.
    public static let defaultRunner: CommandRunner = { executable, arguments, environment in
        do {
            return try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
        } catch {
            return nil
        }
    }
}

// MARK: - Send reporting

extension TmuxSessionControl {

    /// Whether the pane was seen to gain what was sent. `bytesOffered` is a count of
    /// what tmux was handed, which is why it is named that and not `bytesDelivered`:
    /// only `verification` speaks to arrival, and only as far as a pane can.
    public enum SendVerification: String, Codable, Sendable, Equatable {
        /// The pane gained both ends of the payload. Evidence the terminal received
        /// the text — not that the program behind it read the text: an echo is
        /// produced by the line discipline, which is also the layer that discards an
        /// over-long canonical line. A pane can show what its reader never got.
        case paneShowsText = "verified"
        /// The read-back ran and the pane did not gain it.
        case paneMissingText = "unverified"
        /// The pane's reader is in canonical mode and a line of the payload is longer
        /// than the kernel will hold, so the terminator that would hand it over is
        /// dropped with everything else that arrives after the queue fills — while the
        /// prefix it did accept stays echoed on the pane. Its own case because that
        /// echo would otherwise read as proof of exactly the delivery that did not
        /// happen.
        case canonicalOverrun = "canonical-overrun"
        /// Nothing identifiable to look for, no capture answered, or a payload with an
        /// over-long line whose reader would not say what mode it is in — where the
        /// read-back is skipped rather than run and disbelieved.
        case notChecked = "not-checked"
    }

    /// What the pane's reader will do with this payload's longest line, as far as the
    /// sender can establish it.
    enum CanonicalLineFate: Equatable {
        /// Every line fits, or the reader is not canonical: the line reaches it.
        case delivered
        /// The reader is canonical and a line is over the limit, so it is never
        /// offered that line however much of it the pane shows.
        case discarded
        /// A line is over the limit and the terminal would not say what mode it is in.
        case unknown
    }

    /// Why a verification landed where it did, where the case alone does not say it.
    /// Carried on the report so the sentence lives with the code that knows it rather
    /// than being reconstructed by each caller that prints it.
    static let canonicalOverrunCause =
        "the reader is in canonical mode and a line exceeds the kernel's line limit; "
        + "the echo does not prove delivery"
    static let unreadableModeCause =
        "the reader's tty mode could not be read, so the echo is not trusted"
    static let paneMissingTextCause = "the pane does not show both ends of the sent text"

    /// What a send can honestly say about itself: how much text tmux accepted, in
    /// how many calls, what the pane showed afterwards, and why that is the answer.
    public struct SendReport: Sendable, Equatable {
        public let bytesOffered: Int
        public let chunks: Int
        public let verification: SendVerification
        public let cause: String?

        public init(bytesOffered: Int, chunks: Int, verification: SendVerification, cause: String? = nil) {
            self.bytesOffered = bytesOffered
            self.chunks = chunks
            self.verification = verification
            self.cause = cause
        }
    }
}

// MARK: - Verb results

/// `workspaces ws launch --json`. `canonicalForWorkspace` distinguishes the
/// workspace's own session name — the one the app's workspace terminal attaches to
/// when it runs in tmux-per-session mode — from a `--name` sibling, which nothing
/// but this handle reaches.
public struct WorkspaceLaunchResult: Codable, Sendable, Equatable {
    public let handle: String
    public let workspace: String
    public let workspaceID: UUID
    public let path: String
    public let command: String?
    public let socketLabel: String
    public let canonicalForWorkspace: Bool

    public init(
        handle: String,
        workspace: String,
        workspaceID: UUID,
        path: String,
        command: String?,
        socketLabel: String,
        canonicalForWorkspace: Bool
    ) {
        self.handle = handle
        self.workspace = workspace
        self.workspaceID = workspaceID
        self.path = path
        self.command = command
        self.socketLabel = socketLabel
        self.canonicalForWorkspace = canonicalForWorkspace
    }
}

/// `workspaces ws read --json`. `lines` is what was asked for, not what came back:
/// a young session has less scrollback than the bound, and the difference is the
/// caller's to notice.
public struct WorkspaceReadResult: Codable, Sendable, Equatable {
    public let handle: String
    public let socketLabel: String
    public let lines: Int
    public let text: String

    public init(handle: String, socketLabel: String, lines: Int, text: String) {
        self.handle = handle
        self.socketLabel = socketLabel
        self.lines = lines
        self.text = text
    }
}

/// `workspaces ws send --json`. `bytes` is the UTF-8 length of the payload that was
/// handed to tmux — not the decomposed length that reached the wire, and not a
/// delivered count. `verification` is the only field that speaks to arrival.
public struct WorkspaceSendResult: Codable, Sendable, Equatable {
    public let handle: String
    public let socketLabel: String
    public let bytes: Int
    public let chunks: Int
    public let submitted: Bool
    public let verification: TmuxSessionControl.SendVerification

    public init(
        handle: String,
        socketLabel: String,
        bytes: Int,
        chunks: Int,
        submitted: Bool,
        verification: TmuxSessionControl.SendVerification
    ) {
        self.handle = handle
        self.socketLabel = socketLabel
        self.bytes = bytes
        self.chunks = chunks
        self.submitted = submitted
        self.verification = verification
    }
}
