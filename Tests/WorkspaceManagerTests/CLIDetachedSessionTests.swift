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
//  and its own synthetic workspaces root, so the suite can never reach a desktop's
//  live `-L workspaces` sessions.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLI detached sessions", .serialized)
struct CLIDetachedSessionTests {

    /// One isolated CLI world: a scratch git repo, a workspace made through the CLI's
    /// own `ws new`, and a private tmux socket that is killed on teardown.
    private struct Fixture {
        let binary: URL
        let root: URL
        let socketLabel: String
        let workspaceSelector = "repo/detached"

        var environment: [String: String] {
            [
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                "WORKSPACES_SYNTHETIC_ROOT": root.appendingPathComponent("workspaces").path,
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
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            kill.arguments = ["tmux", "-L", socketLabel, "kill-server"]
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
            removeSocketFileIfPresent()
            try? FileManager.default.removeItem(at: root)
        }

        /// `kill-server` unlinks its socket as tmux's own server exits cleanly, but a
        /// server this fixture never actually started (a test that stopped short of
        /// `ws launch`) leaves nothing to kill, and one killed by signal or wedged past
        /// the command's own timeout can leave the file behind regardless. Sweeping
        /// every `tmux-*` directory under `/tmp` for this fixture's own unique label —
        /// the same lookup #1443's reproduce command uses — makes socket cleanup a
        /// property of teardown rather than of `kill-server` happening to succeed.
        private func removeSocketFileIfPresent() {
            let tmp = URL(fileURLWithPath: "/tmp")
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: tmp,
                    includingPropertiesForKeys: nil
                )
            else { return }
            for entry in entries where entry.lastPathComponent.hasPrefix("tmux-") {
                try? FileManager.default.removeItem(at: entry.appendingPathComponent(socketLabel))
            }
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
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-detached-\(UUID().uuidString)")
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

        let fixture = Fixture(
            binary: binary,
            root: root,
            socketLabel: "wsparity-test-\(UUID().uuidString.prefix(8).lowercased())"
        )
        try fixture.run(["repo", "add", repo.path])
        let created = try fixture.run(["ws", "new", "repo", "detached"])
        #expect(created.status == 0)
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
