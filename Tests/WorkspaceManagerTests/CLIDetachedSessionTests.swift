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
                "WORKSPACES_SYNTHETIC_ROOT": root.appendingPathComponent("workspaces").path,
                "TMUX_TMPDIR": root.path,
                TmuxSessionControl.socketLabelEnvironmentKey: socketLabel,
            ]
        }

        @discardableResult
        func run(_ arguments: [String]) throws -> CLIBinary.Invocation {
            try CLIBinary.run(
                binary,
                arguments: arguments,
                currentDirectory: root,
                environment: environment
            )
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
