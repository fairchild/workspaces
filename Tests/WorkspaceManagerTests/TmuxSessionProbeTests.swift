import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TmuxSessionProbe")
struct TmuxSessionProbeTests {
    @Test("Exit code 0 means the session is alive")
    func exitZeroIsAlive() async {
        let probe = TmuxSessionProbe(run: { _, _, _ in 0 }, environment: [:])
        #expect(await probe.isSessionAlive("wm-repo-abcd1234"))
    }

    @Test("Non-zero exit means the session is not alive")
    func nonZeroExitIsNotAlive() async {
        let probe = TmuxSessionProbe(run: { _, _, _ in 1 }, environment: [:])
        #expect(await probe.isSessionAlive("wm-repo-abcd1234") == false)
    }

    @Test("Attached client lines are counted, blank lines ignored")
    func countsAttachedClients() {
        #expect(TmuxSessionProbe.parseAttachedClientCount(fromListClients: "/dev/ttys001") == 1)
        #expect(
            TmuxSessionProbe.parseAttachedClientCount(fromListClients: "/dev/ttys001\n/dev/ttys002\n") == 2
        )
        #expect(TmuxSessionProbe.parseAttachedClientCount(fromListClients: "\n  \n") == 0)
    }

    @Test("An unanswered probe is unknown, not zero")
    func unansweredProbeIsUnknown() {
        // The distinction guards a live pane: the launch-contract repair types into
        // a surface it believes is unattached, so "tmux did not answer" must not read
        // as "nobody is attached".
        #expect(TmuxSessionProbe.parseAttachedClientCount(fromListClients: nil) == nil)
    }

    @Test("Empty output from a live session is a real zero")
    func emptyOutputIsZero() {
        #expect(TmuxSessionProbe.parseAttachedClientCount(fromListClients: "") == 0)
    }

    @Test("A launch failure (nil exit) is treated as not alive")
    func launchFailureIsNotAlive() async {
        let probe = TmuxSessionProbe(run: { _, _, _ in nil }, environment: [:])
        #expect(await probe.isSessionAlive("wm-repo-abcd1234") == false)
    }

    @Test("Probe invokes has-session on the workspaces socket with an exact-match target")
    func buildsExactMatchHasSessionCommand() async throws {
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            run: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return 0
            },
            environment: [:]
        )
        _ = await probe.isSessionAlive("wm-repo-abcd1234")

        let calls = await recorder.calls
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.executable == "/usr/bin/env")
        #expect(call.arguments.contains("tmux"))
        #expect(call.arguments.contains("has-session"))
        // -L workspaces isolates from the user's default tmux server.
        #expect(adjacent(call.arguments, "-L", "workspaces"))
        // "=name" forces exact match so a hash suffix can't prefix-collide.
        #expect(adjacent(call.arguments, "-t", "=wm-repo-abcd1234"))
    }

    // MARK: - Foreground command

    @Test("parseForegroundCommand prefers the active pane's command")
    func parsePrefersActivePane() {
        let output = "0 zsh\n1 vim\n0 python\n"
        #expect(TmuxSessionProbe.parseForegroundCommand(fromListPanes: output) == "vim")
    }

    @Test("parseForegroundCommand falls back to the first pane when none is marked active")
    func parseFallsBackToFirstPane() {
        #expect(TmuxSessionProbe.parseForegroundCommand(fromListPanes: "0 python\n0 zsh\n") == "python")
    }

    @Test("parseForegroundCommand reports a bare shell as its command")
    func parseReportsBareShell() {
        #expect(TmuxSessionProbe.parseForegroundCommand(fromListPanes: "1 zsh\n") == "zsh")
    }

    @Test("parseForegroundCommand returns nil for empty or absent output")
    func parseReturnsNilForEmpty() {
        #expect(TmuxSessionProbe.parseForegroundCommand(fromListPanes: nil) == nil)
        #expect(TmuxSessionProbe.parseForegroundCommand(fromListPanes: "") == nil)
        #expect(TmuxSessionProbe.parseForegroundCommand(fromListPanes: "1 \n") == nil)
    }

    @Test("foregroundCommand queries list-panes on the workspaces socket with an exact target")
    func buildsListPanesCommand() async throws {
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            runForOutput: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return "1 vim\n"
            },
            environment: [:]
        )
        let command = await probe.foregroundCommand(forSessionNamed: "wm-repo-abcd1234")

        #expect(command == "vim")
        let call = try #require(await recorder.calls.first)
        #expect(call.executable == "/usr/bin/env")
        #expect(call.arguments.contains("list-panes"))
        #expect(adjacent(call.arguments, "-L", "workspaces"))
        #expect(adjacent(call.arguments, "-t", "=wm-repo-abcd1234"))
    }

    @Test("foregroundCommand returns nil when tmux output is unavailable")
    func foregroundCommandNilWhenUnavailable() async {
        let probe = TmuxSessionProbe(runForOutput: { _, _, _ in nil }, environment: [:])
        #expect(await probe.foregroundCommand(forSessionNamed: "wm-repo-abcd1234") == nil)
    }

    @Test("parseSessionName matches a session by its pane's current directory")
    func parseSessionNameMatchesByDirectory() {
        let output = "cli-parity\t/tmp/repo-a\nws-1374\t/tmp/repo-b\n"
        #expect(TmuxSessionProbe.parseSessionName(fromListPanes: output, matchingDirectory: "/tmp/repo-b") == "ws-1374")
    }

    /// Adoption's whole safety argument (#1390): guessing wrong would bind the workspace to the
    /// wrong session's live shell, so an ambiguous match answers "no session" rather than
    /// picking either candidate.
    @Test("parseSessionName refuses to pick between two sessions sharing a directory")
    func parseSessionNameRefusesAmbiguousMatch() {
        let output = "session-a\t/tmp/shared\nsession-b\t/tmp/shared\n"
        #expect(TmuxSessionProbe.parseSessionName(fromListPanes: output, matchingDirectory: "/tmp/shared") == nil)
    }

    @Test("parseSessionName matches through a symlinked directory on either side")
    func parseSessionNameResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmux-probe-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        let output = "issue-1374\t\(link.path)\n"
        #expect(TmuxSessionProbe.parseSessionName(fromListPanes: output, matchingDirectory: real.path) == "issue-1374")
    }

    @Test("parseSessionName returns nil for no match or absent output")
    func parseSessionNameNilForNoMatch() {
        #expect(TmuxSessionProbe.parseSessionName(fromListPanes: nil, matchingDirectory: "/tmp/x") == nil)
        #expect(TmuxSessionProbe.parseSessionName(fromListPanes: "", matchingDirectory: "/tmp/x") == nil)
        #expect(
            TmuxSessionProbe.parseSessionName(
                fromListPanes: "other\t/tmp/elsewhere\n", matchingDirectory: "/tmp/x") == nil)
    }

    @Test("sessionName(withCurrentDirectory:) lists panes across every session")
    func sessionNameQueriesAllPanes() async throws {
        let recorder = ArgumentRecorder()
        let probe = TmuxSessionProbe(
            runForOutput: { executable, arguments, _ in
                await recorder.record(executable: executable, arguments: arguments)
                return "ws-1374\t/tmp/repo\n"
            },
            environment: [:]
        )

        let name = await probe.sessionName(withCurrentDirectory: "/tmp/repo")

        #expect(name == "ws-1374")
        let call = try #require(await recorder.calls.first)
        #expect(call.arguments.contains("list-panes"))
        #expect(call.arguments.contains("-a"))
        #expect(adjacent(call.arguments, "-L", "workspaces"))
    }

    // MARK: - Version capability

    @Test("A tmux version line yields its major.minor across the forms tmux prints")
    func parsesVersionLineForms() {
        func parsed(_ output: String?) -> [Int]? {
            TmuxSessionProbe.parseVersion(fromVersionOutput: output).map { [$0.major, $0.minor] }
        }

        #expect(parsed("tmux 3.5a\n") == [3, 5])
        #expect(parsed("tmux next-3.6\n") == [3, 6])
        #expect(parsed("tmux 3.2-rc3\n") == [3, 2])
        #expect(parsed("tmux 2.8\n") == [2, 8])
        #expect(parsed("tmux master\n") == nil)
        #expect(parsed(nil) == nil)
    }

    /// `new-session -e` arrived in tmux 3.2. Emitting it at an older tmux is not a
    /// degraded launch — tmux rejects the flag and the pane never comes up — so the
    /// gate has to fail closed on anything it cannot read as new enough.
    @Test("Only tmux 3.2 and newer are credited with new-session -e")
    func creditsOnlyThreeTwoAndNewerWithSessionEnvironmentFlag() {
        #expect(TmuxSessionProbe.supportsSessionEnvironmentFlag(version: (major: 3, minor: 2)))
        #expect(TmuxSessionProbe.supportsSessionEnvironmentFlag(version: (major: 3, minor: 6)))
        #expect(TmuxSessionProbe.supportsSessionEnvironmentFlag(version: (major: 4, minor: 0)))
        #expect(TmuxSessionProbe.supportsSessionEnvironmentFlag(version: (major: 3, minor: 1)) == false)
        #expect(TmuxSessionProbe.supportsSessionEnvironmentFlag(version: (major: 2, minor: 9)) == false)
        #expect(TmuxSessionProbe.supportsSessionEnvironmentFlag(version: nil) == false)
    }

    @Test("The capability probe asks tmux -V on the injected runner")
    func capabilityProbeAsksTmuxVersion() throws {
        let recorder = SynchronousArgumentRecorder()
        let probe = TmuxSessionProbe(
            runSynchronouslyForOutput: { executable, arguments, _ in
                recorder.record(executable: executable, arguments: arguments)
                return "tmux 3.5a\n"
            },
            environment: [:]
        )

        #expect(probe.supportsSessionEnvironmentFlag())
        let call = try #require(recorder.calls.first)
        #expect(call.executable == "/usr/bin/env")
        #expect(call.arguments == ["tmux", "-V"])
    }

    @Test("An unavailable tmux -V reads as no new-session -e")
    func unavailableVersionReadsAsUnsupported() {
        let probe = TmuxSessionProbe(runSynchronouslyForOutput: { _, _, _ in nil }, environment: [:])
        #expect(probe.version() == nil)
        #expect(probe.supportsSessionEnvironmentFlag() == false)
    }

    /// The production runner is called from a lazy static initializer on the main
    /// thread — a `swift_once`. Anything that runs the main run loop while that once
    /// is held re-enters AppKit, and a nested SwiftUI layout pass composing another
    /// terminal surface re-enters the same once; libdispatch traps that recursive
    /// lock and the app aborts before a surface exists. So the runner has to block
    /// the calling thread without servicing it.
    @MainActor
    @Test("The synchronous runner blocks without running the caller's run loop")
    func synchronousRunnerLeavesTheCallersRunLoopAlone() {
        let pending = RunLoopBlockFlag()
        RunLoop.main.perform { pending.markRan() }

        // The child closes stdout and then lingers, so the read finishes while the
        // process is still alive. That window is the whole test: a runner that waits
        // by running the run loop services the queued block inside it, and one that
        // parks the thread does not.
        let output = TmuxSessionProbe.defaultSynchronousOutputRunner(
            "/bin/sh",
            ["-c", "echo probe; exec 1>&-; sleep 0.4"],
            nil
        )

        #expect(output?.contains("probe") == true)
        #expect(pending.didRun == false)

        // The block really was queued: it runs only once this test runs the loop,
        // which is what makes the assertion above non-vacuous.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        #expect(pending.didRun)
    }

    /// The deadline verdict is the only thing standing between a wedged `tmux -V` and
    /// a capability answer read off a run that never finished, so it is asserted here
    /// against a child whose output and exit status are otherwise spotless: the same
    /// child answers under the real wait, and answers nothing once the run is scored
    /// as having outlived its deadline. Scoring the child clean anyway hands the
    /// launch a version the run never established.
    @Test("A run scored as outliving its deadline yields no answer, however clean it looks")
    func deadlineMissIsNotACleanRun() {
        let cleanChild = ["-c", "printf 'tmux 3.5a\\n'"]

        let answered = TmuxSessionProbe.synchronousOutput(
            executable: "/bin/sh",
            arguments: cleanChild,
            environment: nil
        )
        #expect(answered?.contains("3.5a") == true)

        let scoredAsTimedOut = TmuxSessionProbe.synchronousOutput(
            executable: "/bin/sh",
            arguments: cleanChild,
            environment: nil,
            awaitExit: { exited, _ in
                // Let the child finish and be reaped first, so its status and output
                // are both clean and the verdict is the only reason to reject the run.
                exited.wait()
                return false
            }
        )
        #expect(scoredAsTimedOut == nil)
    }

    /// The same property through the production wait: a child that closes stdout and
    /// then outlives its deadline is killed and yields nothing, so a wedged `tmux -V`
    /// costs one bounded stall rather than a capability answer or an unbounded one.
    /// The deadline is scaled from this machine's measured child round trip — the
    /// child sleeps far past any of them, so the assertion does not ride a clock.
    @Test("A child that outlives its deadline is killed and yields nothing")
    func wedgedChildYieldsNothing() async {
        let timeout = await LaunchBudget.deadline(launches: 1, floor: 0.5, ceiling: 5)
        let output = TmuxSessionProbe.synchronousOutput(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'tmux 3.5a\\n'; exec 1>&-; exec sleep 30"],
            environment: nil,
            timeout: timeout
        )
        #expect(output == nil)
    }

    private func adjacent(_ arguments: [String], _ first: String, _ second: String) -> Bool {
        guard let index = arguments.firstIndex(of: first), index + 1 < arguments.count else { return false }
        return arguments[index + 1] == second
    }
}

private actor ArgumentRecorder {
    private(set) var calls: [(executable: String, arguments: [String])] = []

    func record(executable: String, arguments: [String]) {
        calls.append((executable, arguments))
    }
}

/// Records whether a run-loop-scheduled block has run yet. Written from the run
/// loop and read from the thread that scheduled it, so it carries its own lock.
private final class RunLoopBlockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false

    var didRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ran
    }

    func markRan() {
        lock.lock()
        ran = true
        lock.unlock()
    }
}

/// The synchronous seam has no suspension point to hop through, so its recorder is
/// a lock rather than an actor.
private final class SynchronousArgumentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(executable: String, arguments: [String])] = []

    var calls: [(executable: String, arguments: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(executable: String, arguments: [String]) {
        lock.lock()
        recorded.append((executable, arguments))
        lock.unlock()
    }
}
