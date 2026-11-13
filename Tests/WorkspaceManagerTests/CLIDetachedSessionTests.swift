//
//  CLIDetachedSessionTests.swift
//  WorkspaceManagerTests
//
//  Drives `ws launch` / `ws read` / `ws send` end to end through the real binary and a
//  real tmux server, because the property that matters — a command launched detached
//  is one a later invocation can read back — lives entirely in the round trip.
//  `TmuxSessionControlTests` pins the composed arguments; only this proves they work.
//
//  Isolation: every run gets its own tmux socket label, its own CLI state directory,
//  its own synthetic workspaces root, and its own `TMUX_TMPDIR`, so the suite can never
//  reach a desktop's live `-L workspaces` sessions — and leaves no socket behind when it
//  is done. See `Fixture.environment` for why the last of those is what closes #1443.
//

import Foundation
import os
import Testing

@testable import WorkspaceManagerCore

@Suite("CLI detached sessions", .serialized)
struct CLIDetachedSessionTests {

    /// One isolated CLI world: a scratch git repo, a workspace made through the CLI's
    /// own `ws new`, and a private tmux socket that lives inside `root` and dies with it.
    private struct Fixture {
        let binary: URL
        let root: URL
        let socketLabel: String
        let workspaceSelector = "repo/detached"

        /// `TMUX_TMPDIR` is what makes this fixture's socket disposable, and it is the
        /// whole of #1443's fix.
        ///
        /// tmux puts a `-L` socket at `$TMUX_TMPDIR/tmux-<uid>/<label>`, defaulting to
        /// `/tmp`, and it does not unlink that file when the server exits — not even on
        /// a clean `kill-server`. A stale socket is cleared only when a *later* server
        /// claims the same label, which never happens here because every fixture invents
        /// a fresh one. That is the leak #1443 measured: not a kill that failed, but a
        /// kill that succeeded and left the file.
        ///
        /// Pointing `TMUX_TMPDIR` at `root` moves the socket inside the directory
        /// teardown already removes, so cleanup is containment rather than a sweep of a
        /// world-writable directory this suite does not own. It also makes the label's
        /// uniqueness irrelevant to isolation: two fixtures that drew the same label
        /// still get separate servers, because they get separate socket directories.
        var environment: [String: String] {
            [
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                ConversationRecordStore.directoryEnvironmentKey: root.appendingPathComponent("conversations").path,
                "WORKSPACES_SYNTHETIC_ROOT": root.appendingPathComponent("workspaces").path,
                "TMUX_TMPDIR": root.path,
                TmuxSessionControl.socketLabelEnvironmentKey: socketLabel,
            ]
        }

        @discardableResult
        func run(
            _ arguments: [String],
            extraEnvironment: [String: String] = [:]
        ) throws -> CLIBinary.Invocation {
            try CLIBinary.run(
                binary,
                arguments: arguments,
                currentDirectory: root,
                environment: environment.merging(extraEnvironment) { _, new in new }
            )
        }

        /// One session's own environment on this fixture's socket, as `KEY=value` lines.
        func sessionEnvironment(_ handle: String) throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-L", socketLabel, "show-environment", "-t", "=\(handle)"]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        /// The tmux server's global environment on this fixture's socket, as `KEY=value` lines.
        func serverGlobalEnvironment() throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-L", socketLabel, "show-environment", "-g"]
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
                new
            }
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        func teardown() {
            // The kill needs the same `TMUX_TMPDIR` the launches ran under, or it looks
            // for this label in the default socket directory and finds nothing to kill,
            // leaving a live server behind holding the scratch tree open.
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            kill.arguments = ["tmux", "-L", socketLabel, "kill-server"]
            kill.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
                new
            }
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
            // Removing `root` takes the socket directory with it, so the suite leaves
            // nothing behind whether the kill above succeeded, failed, or had no server
            // to find in the first place.
            try? FileManager.default.removeItem(at: root)
        }
    }

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

    private func makeFixture() throws -> Fixture {
        let binary = try #require(CLIBinary.url, CLIBinary.missingBinaryMessage)
        // Rooted at `/tmp` rather than `NSTemporaryDirectory()` because the tmux socket
        // now lives under this directory, and a unix socket path has to fit in
        // `sockaddr_un.sun_path` — 104 bytes on Darwin, so 103 before the terminating
        // NUL. tmux resolves the directory before binding, so `/tmp` counts as
        // `/private/tmp`. The budget, worst case:
        //
        //     /private/tmp  ws-cli-  <uuid32>  /tmux-  <uid>  /  wsparity-test-  <8>
        //           12  + 1 +   7  +    32   +    6  +  10  + 1 +      14      + 8 = 91
        //
        // That spends a ten-digit uid, the widest a 32-bit uid gets, and still leaves 12
        // bytes. The per-user `NSTemporaryDirectory()` is ~49 bytes of prefix on its own
        // and overruns. Lengthening any component here means redoing this arithmetic.
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "ws-cli-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        )
        // Non-recursive and 0700: creation fails rather than adopting anything already at
        // this path, so a name planted in world-writable `/tmp` cannot be inherited, and
        // the scratch tree is no more readable than the per-user directory it replaces.
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let fixture = Fixture(
            binary: binary,
            root: root,
            socketLabel: "wsparity-test-\(UUID().uuidString.prefix(8).lowercased())"
        )

        // The caller's `defer { fixture.teardown() }` is not registered until this
        // returns, so setup owns its own failure path from the moment `root` exists —
        // otherwise a throw here leaks the scratch tree, the same class of litter #1443
        // is about.
        do {
            let repo = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

            for arguments in [["init", "-q", "."], ["commit", "-q", "--allow-empty", "-m", "init"]] {
                let git = Process()
                git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                git.arguments = ["git"] + arguments
                git.currentDirectoryURL = repo
                git.standardOutput = FileHandle.nullDevice
                git.standardError = FileHandle.nullDevice
                try git.run()
                git.waitUntilExit()
            }

            try fixture.run(["repo", "add", repo.path])
            let created = try fixture.run(["ws", "new", "repo", "detached"])
            #expect(created.status == 0)
        } catch {
            fixture.teardown()
            throw error
        }
        return fixture
    }

    /// Waits for `predicate` to hold over the session's scrollback. The wait is over an
    /// observable state change — text appearing in a pane — rather than a tuned sleep,
    /// because what it is really waiting on is a child-process round trip.
    private func readUntil(
        _ fixture: Fixture,
        selector: String,
        predicate: (String) -> Bool
    ) async throws -> String {
        // Each poll is a CLI launch that itself launches tmux, so the budget is sized in
        // those round trips rather than in wall-clock seconds.
        let deadline = Date().addingTimeInterval(
            await LaunchBudget.deadline(launches: 6, floor: 5, ceiling: 120)
        )
        var latest = ""
        while Date() < deadline {
            let read = try fixture.run(["ws", "read", selector, "--lines", "50"])
            latest = read.stdout
            if read.status == 0, predicate(latest) {
                return latest
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return latest
    }

    @Test(
        "A detached launch runs its command and a later read gets the output back",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func launchThenReadRoundTrip() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let launch = try fixture.run(
            ["ws", "launch", fixture.workspaceSelector, "--cmd", "echo detached-marker; exec sleep 120", "--json"]
        )
        #expect(launch.status == 0)

        let result = try JSONDecoder().decode(
            WorkspaceLaunchResult.self,
            from: Data(launch.stdout.utf8)
        )
        // The handle is the workspace's own session name, which is what makes the app's
        // `new-session -A` attach to this agent instead of starting a second one.
        #expect(result.canonicalForWorkspace)
        #expect(result.socketLabel == fixture.socketLabel)
        #expect(result.handle == TmuxSessionNaming.defaultName(for: URL(fileURLWithPath: result.path)))

        let byHandle = try await readUntil(fixture, selector: result.handle) {
            $0.contains("detached-marker")
        }
        #expect(byHandle.contains("detached-marker"))

        // The workspace selector resolves to the same session, so a caller who launched
        // into a workspace never has to re-derive its handle.
        let byWorkspace = try fixture.run(["ws", "read", fixture.workspaceSelector, "--lines", "50"])
        #expect(byWorkspace.status == 0)
        #expect(byWorkspace.stdout.contains("detached-marker"))
    }

    @Test(
        "Text sent to a handle reaches the session and running it shows up in the read",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func sendReachesTheSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let launch = try fixture.run(
            ["ws", "launch", fixture.workspaceSelector, "--cmd", "exec /bin/sh", "--json"]
        )
        #expect(launch.status == 0)
        let handle = try JSONDecoder()
            .decode(WorkspaceLaunchResult.self, from: Data(launch.stdout.utf8)).handle

        let send = try fixture.run(
            ["ws", "send", handle, "--text", "echo sent-marker", "--enter", "--json"]
        )
        #expect(send.status == 0)
        let sendResult = try JSONDecoder().decode(WorkspaceSendResult.self, from: Data(send.stdout.utf8))
        #expect(sendResult.submitted)
        #expect(sendResult.bytes == "echo sent-marker".utf8.count)
        // Short enough for one chunk, and echoed by the shell, so the read-back can
        // say the pane held it rather than restating the count that was handed over.
        #expect(sendResult.chunks == 1)
        #expect(sendResult.verification == .paneShowsText)

        let text = try await readUntil(fixture, selector: handle) { $0.contains("sent-marker") }
        #expect(text.contains("sent-marker"))
    }

    @Test(
        "A second launch onto a live handle is refused, and --name makes a sibling instead",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func siblingSessionsNeedALabel() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let first = try fixture.run(
            ["ws", "launch", fixture.workspaceSelector, "--cmd", "exec sleep 120", "--json"]
        )
        #expect(first.status == 0)

        let collision = try fixture.run(
            ["ws", "launch", fixture.workspaceSelector, "--cmd", "exec sleep 120"]
        )
        #expect(collision.status == 1)
        #expect(collision.stderr.contains("already running"))
        // The refusal has to name the way forward, or a script that hits it is stuck.
        #expect(collision.stderr.contains("--name"))

        let sibling = try fixture.run(
            ["ws", "launch", fixture.workspaceSelector, "--name", "review", "--cmd", "exec sleep 120", "--json"]
        )
        #expect(sibling.status == 0)
        let siblingResult = try JSONDecoder()
            .decode(WorkspaceLaunchResult.self, from: Data(sibling.stdout.utf8))
        #expect(!siblingResult.canonicalForWorkspace)
        #expect(siblingResult.handle.hasSuffix("-review"))
    }

    /// What an agent session hands its children, plus one ordinary variable as the control
    /// showing the launcher's environment reached the server at all.
    private static let callerEnvironment = [
        "CLAUDECODE": "1",
        "CLAUDE_CODE_CHILD_SESSION": "1",
        "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/cc-socks/1.sock",
        "CLAUDE_CODE_SESSION_ID": "00000000-0000-0000-0000-000000000000",
        "CLAUDE_EFFORT": "xhigh",
        "CLAUDE_PID": "1",
        "AI_AGENT": "claude-code",
        "CODEX_THREAD_ID": "thread",
        "CODEX_SANDBOX_NETWORK_DISABLED": "1",
        "WORKSPACES_HOST_SESSION_ID": "00000000-0000-0000-0000-000000000000",
        "WORKSPACES_AUTOMATION_HANDLE": "caller-tile",
        "WS_DETACHED_CONTROL": "ordinary",
    ]

    private static func callerKeys(in environmentLines: String) -> [String] {
        environmentLines.split(separator: "\n").compactMap { line in
            let key = String(line.prefix { $0 != "=" })
            return AgentSessionEnvironment.belongsToCaller(key) ? key : nil
        }
    }

    /// A launched pane's tile-scoped keys: only the conversations directory, set by the launch
    /// to the one it resolved rather than inherited, so the pane's SessionStart observer
    /// writes where the launch did.
    private static func expectOnlyTheLaunchConversationsDirectory(in paneEnvironment: String, fixture: Fixture) {
        let key = ConversationRecordStore.directoryEnvironmentKey
        #expect(callerKeys(in: paneEnvironment) == [key])
        #expect(paneEnvironment.contains("\(key)=\(fixture.root.appendingPathComponent("conversations").path)\n"))
    }

    /// Waits for a file a launched command writes, past the moment it starts existing.
    private func contentsOnceWritten(_ url: URL) async throws -> String {
        let deadline = Date().addingTimeInterval(
            await LaunchBudget.deadline(launches: 6, floor: 5, ceiling: 120)
        )
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("__done__") {
                return text
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test(
        "A launch from inside an agent session carries none of its identity, in the pane or on the server",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func launchShedsTheCallersIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let captured = fixture.root.appendingPathComponent("pane-env.txt")
        let launch = try fixture.run(
            [
                "ws", "launch", fixture.workspaceSelector,
                "--cmd", "env > \(captured.path); echo __done__ >> \(captured.path); exec sleep 120",
            ],
            extraEnvironment: Self.callerEnvironment
        )
        #expect(launch.status == 0)

        let paneEnvironment = try await contentsOnceWritten(captured)
        #expect(paneEnvironment.contains("__done__"))
        Self.expectOnlyTheLaunchConversationsDirectory(in: paneEnvironment, fixture: fixture)

        let serverEnvironment = try fixture.serverGlobalEnvironment()
        #expect(serverEnvironment.contains("WS_DETACHED_CONTROL=ordinary"))
        #expect(Self.callerKeys(in: serverEnvironment).isEmpty)
    }

    @Test(
        "A launch onto a server an agent session started does not inherit from it, and cleans it",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func launchCleansAPollutedServer() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        // A plain tmux client stands in for an older launcher: nothing scrubs its
        // environment, so the server keeps all of it for its whole life.
        let polluter = Process()
        polluter.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        polluter.arguments = ["tmux", "-L", fixture.socketLabel, "new-session", "-d", "-s", "polluted"]
        polluter.environment = ProcessInfo.processInfo.environment
            .merging(fixture.environment) { _, new in new }
            .merging(Self.callerEnvironment) { _, new in new }
        polluter.standardOutput = FileHandle.nullDevice
        polluter.standardError = FileHandle.nullDevice
        try polluter.run()
        polluter.waitUntilExit()
        #expect(polluter.terminationStatus == 0)
        #expect(!Self.callerKeys(in: try fixture.serverGlobalEnvironment()).isEmpty)

        let captured = fixture.root.appendingPathComponent("pane-env.txt")
        let launch = try fixture.run([
            "ws", "launch", fixture.workspaceSelector,
            "--cmd", "env > \(captured.path); echo __done__ >> \(captured.path); exec sleep 120",
        ])
        #expect(launch.status == 0)

        let paneEnvironment = try await contentsOnceWritten(captured)
        #expect(paneEnvironment.contains("__done__"))
        Self.expectOnlyTheLaunchConversationsDirectory(in: paneEnvironment, fixture: fixture)
        #expect(Self.callerKeys(in: try fixture.serverGlobalEnvironment()).isEmpty)
    }

    @Test("A race agent started from inside an agent session carries none of its identity")
    func raceShedsTheCallersIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let captured = fixture.root.appendingPathComponent("race-env.txt")
        // `race` appends ` -p '<prompt>'`, which `true` ignores.
        let race = try fixture.run(
            [
                "ws", "race", "repo", "--n", "2", "--name", "leak",
                "--cmd", "env > \(captured.path); echo __done__ >> \(captured.path); true",
                "say something",
            ],
            extraEnvironment: Self.callerEnvironment
        )
        #expect(race.status == 0)

        let agentEnvironment = try await contentsOnceWritten(captured)
        #expect(agentEnvironment.contains("__done__"))
        #expect(agentEnvironment.contains("WS_DETACHED_CONTROL=ordinary"))
        #expect(Self.callerKeys(in: agentEnvironment).isEmpty)
    }

    // MARK: - Conversations

    /// Stands in for claude: names the conversation it was given, writes the transcript
    /// entry real claude writes, draws an input box, and stays alive under its own name.
    /// `--stub-*` flags choose what it does instead, which the launch path has to pass
    /// through untouched.
    private static let stubClaude = #"""
        #!/bin/sh
        id=""; effort="medium"; model="claude-opus-5-5"; ran_effort=""; mode="run"; resumed=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --session-id) id="$2"; shift ;;
            --resume) id="$2"; resumed=1; shift ;;
            --model) model="$2"; shift ;;
            --effort) effort="$2"; shift ;;
            --stub-ran-effort) ran_effort="$2"; shift ;;
            --stub-dialog) mode="dialog" ;;
            --stub-quit) mode="quit" ;;
          esac
          shift
        done
        if [ "$mode" = "dialog" ]; then
          printf '  Yes, I trust this folder\nEnter to confirm\n'
          while :; do sleep 1; done
        fi
        dir="$HOME/.claude/projects/$(pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
        mkdir -p "$dir"
        # A resumed agent takes no turn until it is sent something, as the real one does. A
        # launched one reaches a model first, which takes longer than `ps` can resolve.
        if [ -z "$resumed" ]; then
          sleep 2
          now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
          printf '{"type":"assistant","isSidechain":false,"timestamp":"%s","effort":"%s","message":{"model":"%s"}}\n' \
            "$now" "${ran_effort:-$effort}" "$model" >> "$dir/$id.jsonl"
        fi
        printf 'stub-records=%s\n' "${WORKSPACES_CONVERSATIONS_DIR:-none}"
        printf 'stub-started id=%s effort=%s\n' "$id" "$effort"
        printf '────\n❯ \n────\n'
        [ "$mode" = "quit" ] && exit 0
        while :; do sleep 1; done
        """#

    /// `fixture` with the stub on `PATH` and a `HOME` of its own, so transcripts land in
    /// the scratch tree. Every call has to carry both: a fresh server takes its environment
    /// from whichever client starts it.
    private func installStubClaude(in fixture: Fixture) throws -> [String: String] {
        let bin = fixture.root.appendingPathComponent("bin")
        let home = fixture.root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let stub = bin.appendingPathComponent("claude")
        try Self.stubClaude.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
    }

    private func launchResult(_ invocation: CLIBinary.Invocation) throws -> WorkspaceLaunchResult {
        try JSONDecoder().decode(WorkspaceLaunchResult.self, from: Data(invocation.stdout.utf8))
    }

    private func checkResult(_ invocation: CLIBinary.Invocation) throws -> WorkspaceCheckResult {
        try JSONDecoder().decode(WorkspaceCheckResult.self, from: Data(invocation.stdout.utf8))
    }

    private func resumeResult(_ invocation: CLIBinary.Invocation) throws -> WorkspaceResumeResult {
        try JSONDecoder().decode(WorkspaceResumeResult.self, from: Data(invocation.stdout.utf8))
    }

    private func waitUntilGone(
        _ handle: String,
        fixture: Fixture,
        environment: [String: String]
    ) async throws {
        let deadline = Date().addingTimeInterval(
            await LaunchBudget.deadline(launches: 6, floor: 10, ceiling: 120)
        )
        while try fixture.run(["ws", "read", handle], extraEnvironment: environment).status == 0,
            Date() < deadline
        {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// A session under `handle` that no launch recorded, the way another client makes one.
    private func startSession(
        _ handle: String,
        running command: String,
        fixture: Fixture,
        environment: [String: String]
    ) throws {
        let tmux = Process()
        tmux.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        tmux.arguments = ["tmux", "-L", fixture.socketLabel, "new-session", "-d", "-s", handle, command]
        tmux.environment = ProcessInfo.processInfo.environment
            .merging(fixture.environment) { _, new in new }
            .merging(environment) { _, new in new }
        try tmux.run()
        tmux.waitUntilExit()
        #expect(tmux.terminationStatus == 0)
    }

    /// Long enough for a login shell, a stub, and a transcript write on a loaded runner.
    private func waitSeconds() async -> String {
        String(Int(await LaunchBudget.deadline(launches: 6, floor: 10, ceiling: 120)))
    }

    @Test(
        "A launch names its conversation, and a check finds one agent running as requested",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func launchThenCheckVerifies() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)

        let launch = try launchResult(
            fixture.run(
                [
                    "ws", "launch", fixture.workspaceSelector,
                    "--cmd", "claude --model claude-haiku-5-5 --effort low 'do the work'", "--json",
                ],
                extraEnvironment: environment
            )
        )
        let conversationID = try #require(launch.conversationID)
        #expect(launch.command?.contains("--session-id \(conversationID)") == true)
        #expect(launch.requestedModel == "claude-haiku-5-5")
        #expect(launch.requestedEffort == "low")

        let check = try fixture.run(
            ["ws", "check", launch.handle, "--wait", await waitSeconds(), "--json"],
            extraEnvironment: environment
        )
        #expect(check.status == 0)
        let result = try checkResult(check)
        #expect(result.verdict == .verified)
        #expect(result.agentProcesses == 1)
        #expect(result.observedModel == "claude-haiku-5-5")
        #expect(result.observedEffort == "low")
    }

    @Test(
        "A check says when the last turn did not run as requested",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func checkReportsMismatch() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)

        let launch = try launchResult(
            fixture.run(
                [
                    "ws", "launch", fixture.workspaceSelector,
                    "--cmd", "claude --effort xhigh --stub-ran-effort low", "--json",
                ],
                extraEnvironment: environment
            )
        )
        let check = try fixture.run(
            ["ws", "check", launch.handle, "--wait", await waitSeconds(), "--json"],
            extraEnvironment: environment
        )
        #expect(check.status == 2)
        #expect(try checkResult(check).verdict == .mismatch)
    }

    @Test(
        "A prompt holding the launch comes back at once as blocked and names itself",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func checkReportsABlockingPrompt() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)

        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --stub-dialog", "--json"],
                extraEnvironment: environment
            )
        )
        let check = try fixture.run(
            ["ws", "check", launch.handle, "--wait", await waitSeconds(), "--json"],
            extraEnvironment: environment
        )
        #expect(check.status == 2)
        let result = try checkResult(check)
        #expect(result.verdict == .blocked)
        #expect(result.blocker == "trust-folder")
    }

    @Test(
        "A command that names no conversation is reported as such, and has nothing to resume",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func opaqueLaunch() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let launch = try launchResult(
            fixture.run(["ws", "launch", fixture.workspaceSelector, "--cmd", "exec sleep 120", "--json"])
        )
        #expect(launch.conversationID == nil)
        #expect(launch.command == "exec sleep 120")

        let check = try fixture.run(["ws", "check", launch.handle, "--json"])
        #expect(check.status == 2)
        #expect(try checkResult(check).verdict == .unverifiable)

        let resume = try fixture.run(["ws", "resume", launch.handle])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("names no conversation"))
    }

    @Test(
        "After the agent quits, resume continues the same conversation at the same effort",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func resumeAfterTheAgentQuits() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)

        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --effort low --stub-quit", "--json"],
                extraEnvironment: environment
            )
        )
        let conversationID = try #require(launch.conversationID)

        try await waitUntilGone(launch.handle, fixture: fixture, environment: environment)
        let check = try fixture.run(["ws", "check", launch.handle, "--json"], extraEnvironment: environment)
        #expect(try checkResult(check).verdict == .notRunning)

        let resume = try resumeResult(
            fixture.run(["ws", "resume", launch.handle, "--json"], extraEnvironment: environment)
        )
        #expect(resume.resumed)
        #expect(resume.conversationID == conversationID)
        #expect(resume.command == "claude --resume \(conversationID) --effort low")

        let text = try await readUntil(fixture, selector: launch.handle) {
            $0.contains("stub-started id=\(conversationID) effort=low")
        }
        #expect(text.contains("stub-started id=\(conversationID) effort=low"))

        // Up and able to take input, and not yet proof of anything: the last turn in the
        // transcript belongs to the process that quit.
        let unproven = try fixture.run(["ws", "check", launch.handle, "--json"], extraEnvironment: environment)
        #expect(unproven.status == 2)
        #expect(try checkResult(unproven).verdict == .ready)
        let ready = try fixture.run(
            ["ws", "check", launch.handle, "--wait", await waitSeconds(), "--ready", "--json"],
            extraEnvironment: environment
        )
        #expect(ready.status == 0)
        #expect(try checkResult(ready).verdict == .ready)

        // The agent is back, so asking again starts nothing.
        let again = try resumeResult(
            fixture.run(["ws", "resume", launch.handle, "--json"], extraEnvironment: environment)
        )
        #expect(!again.resumed)
        #expect(again.command == nil)
    }

    @Test(
        "Resume types into a bare shell left under the handle, and refuses anything else",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func resumeIntoAWaitingShell() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)

        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --stub-quit", "--json"],
                extraEnvironment: environment
            )
        )
        let conversationID = try #require(launch.conversationID)
        try await waitUntilGone(launch.handle, fixture: fixture, environment: environment)

        // What the app leaves behind when it opens the workspace after the session died.
        try startSession(launch.handle, running: "/bin/sh", fixture: fixture, environment: environment)
        // The app prefills a resume command into such a shell, and what is typed has to
        // replace that line rather than land after it.
        let leftover = try fixture.run(
            ["ws", "send", launch.handle, "--text", "prefilled-text"],
            extraEnvironment: environment
        )
        #expect(leftover.status == 0)

        let resume = try resumeResult(
            fixture.run(["ws", "resume", launch.handle, "--json"], extraEnvironment: environment)
        )
        #expect(resume.resumed)
        let text = try await readUntil(fixture, selector: launch.handle) {
            $0.contains("stub-started id=\(conversationID)")
        }
        #expect(text.contains("stub-started id=\(conversationID)"))
    }

    @Test(
        "Resume into a shell older than the records directory hands the agent the directory",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func resumeIntoAPreRecordsShell() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let directory = fixture.root.appendingPathComponent("conversations").path

        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --stub-quit", "--json"],
                extraEnvironment: environment
            )
        )
        try await waitUntilGone(launch.handle, fixture: fixture, environment: environment)
        try startSession(
            launch.handle, running: "env -u \(ConversationRecordStore.directoryEnvironmentKey) /bin/sh",
            fixture: fixture, environment: environment
        )

        let resume = try resumeResult(
            fixture.run(["ws", "resume", launch.handle, "--json"], extraEnvironment: environment)
        )
        #expect(resume.resumed)
        let text = try await readUntil(fixture, selector: launch.handle) { $0.contains("stub-started") }
        #expect(text.contains("stub-records=\(directory)"))
        let assignment = "\(ConversationRecordStore.directoryEnvironmentKey)=\(directory)"
        #expect(try fixture.sessionEnvironment(launch.handle).contains(assignment))
    }

    @Test(
        "A hook in a shell older than its session's records directory reads it from the session",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func hookInAPreRecordsShellReadsTheSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let key = ConversationRecordStore.directoryEnvironmentKey
        let directory = fixture.root.appendingPathComponent("conversations")
        let script = try installHookScript(in: fixture)
        let trigger = fixture.root.appendingPathComponent("go")
        let conversationID = UUID().uuidString.lowercased()
        let payload = #"{"session_id":"\#(conversationID)","cwd":"\#(fixture.root.path)"}"#
        let handle = "wm-pre-records-00000000"

        // A shell started without the key, waiting until the session has it, then a
        // SessionStart hook in that same shell.
        try startSession(
            handle,
            running: "env -u \(key) -u WORKSPACES_HOST_SESSION_ID /bin/sh -c "
                + RaceGroupPlanner.shellQuoted(
                    "while [ ! -e '\(trigger.path)' ]; do sleep 0.1; done; "
                        + "printf '%s' '\(payload)' | '\(script.path)'; sleep 60"
                ),
            fixture: fixture, environment: environment
        )
        let control = TmuxSessionControl(
            socketLabel: fixture.socketLabel,
            environment: ProcessInfo.processInfo.environment.merging(fixture.environment) { _, new in new }
                .filter { $0.key != key },
            sessionEnvironment: [key: directory.path]
        )
        try await control.adoptSessionEnvironment(handle: handle)
        FileManager.default.createFile(atPath: trigger.path, contents: nil)

        let records = ConversationRecordStore(directory: directory)
        let deadline = Date().addingTimeInterval(await LaunchBudget.deadline(launches: 2, floor: 10, ceiling: 60))
        var record = try records.load(conversationID: conversationID)
        while record == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            record = try records.load(conversationID: conversationID)
        }
        let written = try #require(record, "the hook in the surviving shell wrote no record")
        #expect(written.observedBy == .hook)
        #expect(written.lastSeenIn?.tmux?.sessionID.hasPrefix("$") == true)
    }

    /// The hook script as the app extracts it, naming this fixture's CLI.
    private func installHookScript(in fixture: Fixture) throws -> URL {
        let template = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/WorkspaceManager/Resources/HookForwarders/conversation-observer.sh"),
            encoding: .utf8
        )
        let script = fixture.root.appendingPathComponent("conversation-observer.sh")
        try template.replacingOccurrences(of: "@WORKSPACES_CLI@", with: fixture.binary.path)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A session made without the records directory, which the session's environment then
    /// names, as a surviving session has it after a resume or a tile attaches. Returns the
    /// `$TMUX` its panes see: socket path, server pid, session number.
    private func sessionNamingTheRecordsDirectory(
        _ handle: String,
        fixture: Fixture,
        environment: [String: String]
    ) async throws -> (socket: String, serverPID: Int32, session: String) {
        let key = ConversationRecordStore.directoryEnvironmentKey
        try startSession(handle, running: "env -u \(key) sleep 120", fixture: fixture, environment: environment)
        let tmuxEnvironment = ProcessInfo.processInfo.environment.merging(fixture.environment) { _, new in new }
            .filter { $0.key != key }
        try await TmuxSessionControl(
            socketLabel: fixture.socketLabel,
            environment: tmuxEnvironment,
            sessionEnvironment: [key: fixture.root.appendingPathComponent("conversations").path]
        ).adoptSessionEnvironment(handle: handle)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "tmux", "-L", fixture.socketLabel, "display-message", "-p", "-t", "=\(handle):",
            "#{socket_path}\t#{pid}\t#{session_id}",
        ]
        process.environment = tmuxEnvironment
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let fields = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            .split(separator: "\t").map(String.init)
        try #require(fields.count == 3)
        return (fields[0], try #require(Int32(fields[1])), String(fields[2].dropFirst()))
    }

    /// Runs the hook outside any tile key with `tmux` as `$TMUX`, and how long it took. With
    /// `signal`, sends it that signal `signalAfter` seconds in. A hook that outlives `limit`
    /// is killed, so a hang fails the test rather than the suite.
    private func runHook(
        _ script: URL,
        tmux: String,
        conversationID: String,
        fixture: Fixture,
        temporaryDirectory: URL? = nil,
        signal: Int32? = nil,
        signalAfter: TimeInterval = 0.3,
        limit: TimeInterval = 15
    ) throws -> TimeInterval {
        let process = Process()
        let input = Pipe()
        process.executableURL = script
        process.environment = [
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": fixture.root.path, "TMUX": tmux,
            "XDG_CONFIG_HOME": fixture.root.appendingPathComponent("config").path,
            "TMPDIR": (temporaryDirectory ?? fixture.root).path,
        ]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        try process.run()
        input.fileHandleForWriting.write(
            Data(#"{"session_id":"\#(conversationID)","cwd":"\#(fixture.root.path)"}"#.utf8))
        try input.fileHandleForWriting.close()
        var signalled = signal == nil
        while process.isRunning, Date().timeIntervalSince(started) < limit {
            if !signalled, let signal, Date().timeIntervalSince(started) >= signalAfter {
                kill(process.processIdentifier, signal)
                signalled = true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return Date().timeIntervalSince(started)
    }

    @Test(
        "A hook declines the records directory of a server other than the one its $TMUX names",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func hookDeclinesAnotherServersDirectory() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let script = try installHookScript(in: fixture)
        let records = ConversationRecordStore(directory: fixture.root.appendingPathComponent("conversations"))
        let tmux = try await sessionNamingTheRecordsDirectory(
            "wm-replaced-00000000", fixture: fixture, environment: environment)

        let elsewhere = UUID().uuidString.lowercased()
        _ = try runHook(
            script, tmux: "\(tmux.socket),\(tmux.serverPID + 1),\(tmux.session)",
            conversationID: elsewhere, fixture: fixture)
        #expect(records.load(conversationID: elsewhere) == nil)

        let here = UUID().uuidString.lowercased()
        _ = try runHook(
            script, tmux: "\(tmux.socket),\(tmux.serverPID),\(tmux.session)",
            conversationID: here, fixture: fixture)
        #expect(records.load(conversationID: here) != nil)
    }

    @Test(
        "A hook whose tmux server does not answer gives up within its bound and writes nothing",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func hookGivesUpOnAStoppedServer() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let script = try installHookScript(in: fixture)
        let records = ConversationRecordStore(directory: fixture.root.appendingPathComponent("conversations"))
        let tmux = try await sessionNamingTheRecordsDirectory(
            "wm-stopped-00000000", fixture: fixture, environment: environment)

        let conversationID = UUID().uuidString.lowercased()
        kill(tmux.serverPID, SIGSTOP)
        let elapsed: TimeInterval
        do {
            defer { kill(tmux.serverPID, SIGCONT) }
            elapsed = try runHook(
                script, tmux: "\(tmux.socket),\(tmux.serverPID),\(tmux.session)",
                conversationID: conversationID, fixture: fixture)
        }
        #expect(elapsed < 5, "the hook took \(elapsed) s against a stopped server")
        #expect(records.load(conversationID: conversationID) == nil)
    }

    @Test(
        "A hook signalled while its tmux server does not answer leaves no lookup behind",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it"),
        arguments: [SIGTERM, SIGINT]
    )
    func signalledHookCleansUp(_ signal: Int32) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let script = try installHookScript(in: fixture)
        let temporary = fixture.root.appendingPathComponent("hook-tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let tmux = try await sessionNamingTheRecordsDirectory(
            "wm-signalled-00000000", fixture: fixture, environment: environment)

        kill(tmux.serverPID, SIGSTOP)
        let elapsed: TimeInterval
        let clientsLeft: Int32
        do {
            defer { kill(tmux.serverPID, SIGCONT) }
            elapsed = try runHook(
                script, tmux: "\(tmux.socket),\(tmux.serverPID),\(tmux.session)",
                conversationID: UUID().uuidString.lowercased(), fixture: fixture,
                temporaryDirectory: temporary, signal: signal)
            // Asked while the server is still stopped, when a leaked client would still be waiting.
            let clients = Process()
            clients.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            clients.arguments = ["-f", "-q", "\(tmux.socket) display-message -p -t \\$\(tmux.session) "]
            try clients.run()
            clients.waitUntilExit()
            clientsLeft = clients.terminationStatus
        }
        #expect(elapsed < 5, "the hook took \(elapsed) s to end after the signal")
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == [])
        #expect(clientsLeft == 1, "a lookup client outlived the hook")
    }

    @Test(
        "Resume refuses to type into a session running something else",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func resumeRefusesABusyPane() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)

        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --stub-quit", "--json"],
                extraEnvironment: environment
            )
        )
        try await waitUntilGone(launch.handle, fixture: fixture, environment: environment)
        try startSession(launch.handle, running: "exec sleep 120", fixture: fixture, environment: environment)

        let paneDeadline = Date().addingTimeInterval(await LaunchBudget.deadline(launches: 2, floor: 3, ceiling: 30))
        var resume = try fixture.run(["ws", "resume", launch.handle], extraEnvironment: environment)
        while !resume.stderr.contains("not a shell"), Date() < paneDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            resume = try fixture.run(["ws", "resume", launch.handle], extraEnvironment: environment)
        }
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("not a shell"))
    }

    /// A terminal showing the session, the way a tile in the app does. `script` gives tmux the
    /// pty it needs, and its stdin stays an open pipe because an ended one is typed into the
    /// pane as a Control-D.
    private func attachClient(
        to handle: String,
        fixture: Fixture,
        environment: [String: String]
    ) async throws -> Process {
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        client.arguments = ["-q", "/dev/null", "tmux", "-L", fixture.socketLabel, "attach-session", "-t", "=\(handle)"]
        client.environment = ProcessInfo.processInfo.environment
            .merging(fixture.environment) { _, new in new }
            .merging(environment) { _, new in new }
            .merging(["TERM": "xterm-256color"]) { _, new in new }
        client.standardInput = Pipe()
        client.standardOutput = Pipe()
        client.standardError = Pipe()
        try client.run()

        let control = TmuxSessionControl(
            socketLabel: fixture.socketLabel,
            environment: TmuxSessionProbe.defaultEnvironment.merging(fixture.environment) { _, new in new }
        )
        let deadline = Date().addingTimeInterval(await LaunchBudget.deadline(launches: 2, floor: 3, ceiling: 30))
        while await control.attachedClients(handle: handle) != 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return client
    }

    /// A conversation with a transcript and no agent, and a shell under its handle.
    private func quitIntoAShell(
        fixture: Fixture,
        environment: [String: String]
    ) async throws -> (handle: String, conversationID: String) {
        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --effort low --stub-quit", "--json"],
                extraEnvironment: environment
            )
        )
        let conversationID = try #require(launch.conversationID)
        try await waitUntilGone(launch.handle, fixture: fixture, environment: environment)
        try startSession(launch.handle, running: "/bin/sh", fixture: fixture, environment: environment)
        return (launch.handle, conversationID)
    }

    @Test(
        "Resume leaves a prompt alone when a terminal is attached to it",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func resumeLeavesAnAttachedPrompt() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let (handle, conversationID) = try await quitIntoAShell(fixture: fixture, environment: environment)
        let client = try await attachClient(to: handle, fixture: fixture, environment: environment)
        defer { client.terminate() }

        let typed = try fixture.run(["ws", "send", handle, "--text", "half-a-command"], extraEnvironment: environment)
        #expect(typed.status == 0)

        let resume = try fixture.run(["ws", "resume", handle], extraEnvironment: environment)
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("open in a terminal"))
        #expect(resume.stderr.contains("claude --resume \(conversationID) --effort low"))

        let pane = try fixture.run(["ws", "read", handle], extraEnvironment: environment)
        #expect(pane.stdout.contains("half-a-command"))
        #expect(!pane.stdout.contains("stub-started"))
    }

    @Test(
        "Two resumes at once start one agent",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func concurrentResumes() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let (handle, conversationID) = try await quitIntoAShell(fixture: fixture, environment: environment)

        let results = DispatchQueue.global()
        let outcomes = try await withThrowingTaskGroup(of: WorkspaceResumeResult.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        results.async {
                            continuation.resume(
                                with: Result {
                                    let run = try fixture.run(
                                        ["ws", "resume", handle, "--json"],
                                        extraEnvironment: environment
                                    )
                                    return try JSONDecoder().decode(
                                        WorkspaceResumeResult.self,
                                        from: Data(run.stdout.utf8)
                                    )
                                }
                            )
                        }
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(outcomes.filter(\.resumed).count == 1)
        let check = try checkResult(fixture.run(["ws", "check", handle, "--json"], extraEnvironment: environment))
        #expect(check.conversationID == conversationID)
        #expect(check.agentProcesses == 1)
    }

    @Test(
        "A launch naming a conversation something already holds is refused",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func launchRefusesAHeldConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude", "--json"],
                extraEnvironment: environment
            )
        )
        let conversationID = try #require(launch.conversationID)
        _ = try await readUntil(fixture, selector: launch.handle) { $0.contains("stub-started") }

        let second = try fixture.run(
            [
                "ws", "launch", fixture.workspaceSelector, "--name", "other", "--cmd",
                "claude --resume \(conversationID)",
            ],
            extraEnvironment: environment
        )
        #expect(second.status == 1)
        #expect(second.stderr.contains("already running"))
    }

    @Test(
        "Resume refuses a record from an earlier workspace at the same path",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func resumeRefusesAnEarlierWorkspace() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --stub-quit", "--json"],
                extraEnvironment: environment
            )
        )
        try await waitUntilGone(launch.handle, fixture: fixture, environment: environment)

        let launches = fixture.root.appendingPathComponent("config/workspaces-cli/launches")
        let record = try #require(
            AgentLaunchRecordStore(directory: launches).load(socketLabel: fixture.socketLabel, handle: launch.handle)
        )
        try FileManager.default.removeItem(atPath: record.workspacePath)
        try FileManager.default.createDirectory(atPath: record.workspacePath, withIntermediateDirectories: true)

        let resume = try fixture.run(["ws", "resume", launch.handle], extraEnvironment: environment)
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("earlier workspace"))
    }

    @Test(
        "A resume that starts nothing says so",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func resumeReportsAFailedStart() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let launch = try launchResult(
            fixture.run(
                ["ws", "launch", fixture.workspaceSelector, "--cmd", "claude --stub-quit", "--json"],
                extraEnvironment: environment
            )
        )
        try await waitUntilGone(launch.handle, fixture: fixture, environment: environment)

        // Found on PATH and never becomes a process, so no listing can catch it in passing.
        let bin = fixture.root.appendingPathComponent("bin/claude")
        try "#!/nonexistent/interpreter\n".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let resume = try fixture.run(["ws", "resume", launch.handle], extraEnvironment: environment)
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("nothing took up conversation"))
    }

    @Test(
        "ws launch writes the conversation record and the launch record together",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func launchWritesTheConversationRecord() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)

        let launch = try launchResult(
            fixture.run(
                [
                    "ws", "launch", fixture.workspaceSelector, "--cmd", "claude --model claude-opus-5-5 --effort low",
                    "--json",
                ],
                extraEnvironment: environment
            )
        )

        let launches = fixture.root.appendingPathComponent("config/workspaces-cli/launches")
        let launchRecord = try #require(
            AgentLaunchRecordStore(directory: launches).load(socketLabel: fixture.socketLabel, handle: launch.handle)
        )
        let conversationID = try #require(launchRecord.identity?.conversationID)
        let record = try #require(
            ConversationRecordStore(directory: fixture.root.appendingPathComponent("conversations"))
                .load(conversationID: conversationID)
        )
        #expect(launch.conversationID == conversationID)
        #expect(record.observedBy == .wsLaunch)
        #expect(record.launch == .init(handle: launch.handle, model: "claude-opus-5-5", effort: "low"))
        #expect(record.cwd == launchRecord.workspacePath)
        #expect(record.workspacePath == launchRecord.workspacePath)
        #expect(record.socketLabel == fixture.socketLabel)
        #expect(record.lastSeenIn?.hostSessionID == nil)
        #expect(record.lastSeenIn?.tmux?.name == launch.handle)
        #expect(record.lastSeenIn?.tmux?.sessionID.hasPrefix("$") == true)
    }

    /// The client that starts a detached session has tile-scoped keys stripped, so without
    /// `-e` the pane would carry no conversations directory and the SessionStart observer
    /// inside it would treat itself as outside WorkSpaces and write nothing.
    @Test(
        "An observer inside a detached session writes to the launch's conversations directory",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func detachedSessionCarriesTheConversationsDirectory() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let environment = try installStubClaude(in: fixture)
        let conversationID = UUID().uuidString.lowercased()
        let payload = #"{"session_id":"\#(conversationID)","cwd":"\#(fixture.root.path)"}"#
        let command = "printf '%s' '\(payload)' | '\(fixture.binary.path)' conversation observe; sleep 30"

        try fixture.run(
            ["ws", "launch", fixture.workspaceSelector, "--cmd", command, "--json"],
            extraEnvironment: environment.merging([
                "WORKSPACES_HOST_SESSION_ID": UUID().uuidString
            ]) { _, new in new }
        )

        let records = ConversationRecordStore(directory: fixture.root.appendingPathComponent("conversations"))
        let deadline = Date().addingTimeInterval(
            await LaunchBudget.deadline(launches: 2, floor: 10, ceiling: 60)
        )
        var record = try records.load(conversationID: conversationID)
        while record == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            record = try records.load(conversationID: conversationID)
        }
        let written = try #require(record, "the observer in the detached pane wrote no record")
        #expect(written.observedBy == .hook)
        #expect(written.lastSeenIn?.hostSessionID == nil)
        #expect(written.lastSeenIn?.tmux?.sessionID.hasPrefix("$") == true)
        #expect(!(try fixture.serverGlobalEnvironment()).contains(ConversationRecordStore.directoryEnvironmentKey))
    }

    /// The launch a tmux older than 3.2 gets, run on the real tmux here with only its version
    /// answer replaced: no `-e`, the command under `env`, and a chained `set-environment`.
    /// The observer in the first pane still writes where the launch named, and the session
    /// names the directory for any later pane.
    @Test(
        "Without new-session -e, an observer in the detached pane still writes to the launch's directory",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func detachedSessionWithoutTheEnvironmentFlag() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let key = ConversationRecordStore.directoryEnvironmentKey
        let directory = fixture.root.appendingPathComponent("conversations")
        let conversationID = UUID().uuidString.lowercased()
        let payload = #"{"session_id":"\#(conversationID)","cwd":"\#(fixture.root.path)"}"#
        let handle = "wm-old-tmux-00000000"
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let control = TmuxSessionControl(
            socketLabel: fixture.socketLabel,
            run: { executable, arguments, environment in
                calls.withLock { $0.append(arguments) }
                if arguments == ["tmux", "-V"] { return ProcessResult(exitCode: 0, stdout: "tmux 3.1c\n", stderr: "") }
                return await TmuxSessionControl.defaultRunner(executable, arguments, environment)
            },
            environment: ProcessInfo.processInfo.environment.merging(fixture.environment) { _, new in new }
                .filter { $0.key != key },
            sessionEnvironment: [key: directory.path]
        )

        try await control.launch(
            handle: handle, directory: fixture.root,
            command: "printf '%s' '\(payload)' | '\(fixture.binary.path)' conversation observe; sleep 30")

        let created = try #require(calls.withLock { $0.first { $0.contains("new-session") } })
        #expect(!created.contains("-e"))
        let records = ConversationRecordStore(directory: directory)
        let deadline = Date().addingTimeInterval(await LaunchBudget.deadline(launches: 1, floor: 10, ceiling: 60))
        var record = try records.load(conversationID: conversationID)
        while record == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            record = try records.load(conversationID: conversationID)
        }
        let written = try #require(record, "the observer in the first pane wrote no record")
        #expect(written.observedBy == .hook)
        #expect(try fixture.sessionEnvironment(handle).contains("\(key)=\(directory.path)"))
        #expect(!(try fixture.serverGlobalEnvironment()).contains(key))
    }

    /// tmux ends a command at a `;` closing any argument, so each value here would split or
    /// trim a launch handed to it raw; U+0600 makes the last `;` share a `Character` with
    /// it. The command ends in `\;` for the same reason: the pane's shell receives it as an
    /// argument only if the command reached tmux intact.
    @Test(
        "Values ending in ;, \\; or \\ reach the pane and the session intact, with new-session -e and without",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func sessionEnvironmentSurvivesTmuxsArgumentParser() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let key = "WORKSPACES_PROBE_VALUE"
        let values = ["/tmp/records;", #"/tmp/records\;"#, #"/tmp/records\"#, "/tmp/records\u{0600};"]

        for (index, value) in values.enumerated() {
            for seeds in [true, false] {
                let control = TmuxSessionControl(
                    socketLabel: fixture.socketLabel,
                    run: { executable, arguments, environment in
                        guard arguments == ["tmux", "-V"] else {
                            return await TmuxSessionControl.defaultRunner(executable, arguments, environment)
                        }
                        return ProcessResult(exitCode: 0, stdout: seeds ? "tmux 3.2\n" : "tmux 3.1c\n", stderr: "")
                    },
                    environment: ProcessInfo.processInfo.environment.merging(fixture.environment) { _, new in new },
                    sessionEnvironment: [key: value]
                )
                let path = seeds ? "e" : "env"
                let withCommand = "wm-escape-\(index)-\(path)-cmd"
                let bare = "wm-escape-\(index)-\(path)-bare"
                let out = fixture.root.appendingPathComponent("\(withCommand).out")
                let script = #"printf "%s|%s|__done__" "$\#(key)" "$2" > "$1"; exec sleep 30"#

                try await control.launch(
                    handle: withCommand, directory: fixture.root,
                    command: #"exec /bin/sh -c '\#(script)' sh '\#(out.path)' \;"#
                )
                try await control.launch(handle: bare, directory: fixture.root, command: nil)

                #expect(try await contentsOnceWritten(out) == "\(value)|;|__done__", "\(withCommand)")
                for handle in [withCommand, bare] {
                    let query = ["tmux", "-u", "-L", fixture.socketLabel, "show-environment", "-t", "=\(handle)", key]
                    let shown = await TmuxSessionControl.defaultRunner(
                        "/usr/bin/env", query,
                        ProcessInfo.processInfo.environment.merging(fixture.environment) { _, new in new })
                    #expect(shown?.stdout == "\(key)=\(value)\n", "\(handle): \(shown?.stdout ?? "no answer")")
                }
            }
        }
    }

    @Test("Resuming a handle nothing was launched under says so")
    func resumeWithoutARecord() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let resume = try fixture.run(["ws", "resume", "wm-nothing-00000000"])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("No launch is recorded"))
    }

    @Test("A check on a handle nothing is running under is an answer, not an error")
    func checkOnADeadHandle() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let check = try fixture.run(["ws", "check", "wm-nothing-00000000", "--json"])
        #expect(check.status == 2)
        #expect(try checkResult(check).verdict == .notRunning)
    }

    @Test(
        "Reading a handle nothing is running under says so rather than returning nothing",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the verbs are a thin shell over it")
    )
    func readingADeadHandleExplainsItself() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let read = try fixture.run(["ws", "read", "wm-nothing-00000000"])
        #expect(read.status == 1)
        #expect(read.stderr.contains("No terminal session named 'wm-nothing-00000000' is running"))
        #expect(read.stdout.isEmpty)
    }
}
