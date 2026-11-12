//
//  TerminalSessionExitTests.swift
//  WorkspaceManagerTests
//
//  How a tmux-backed tile's exit is read, against a real tmux server on an isolated
//  socket label, set up as the app's launch script leaves it: no config file, and kept
//  running when empty. Each test starts its own server, ends it by pid, and never names
//  the app's shared socket.
//

import Darwin
import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TerminalSessionExit")
struct TerminalSessionExitTests {
    /// One throwaway tmux server on a label nothing else uses.
    private struct IsolatedTmuxServer: Sendable {
        let label: String
        let serverPID: Int?
        let socketPath: String

        /// Starts a server holding `session`, with `exit-empty` off as the app's launch
        /// script sets it. `label` reuses a socket whose earlier server is gone.
        static func start(session: String, label: String = Self.freshLabel()) throws -> IsolatedTmuxServer {
            try tmux(
                label, ["new-session", "-d", "-s", session, "sleep 600", ";", "set-option", "-s", "exit-empty", "off"])
            let answer = try tmux(label, ["display-message", "-p", "#{pid}\t#{socket_path}"]).output
            let fields = answer.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
            return IsolatedTmuxServer(
                label: label, serverPID: fields.first.flatMap { Int($0) }, socketPath: fields.last ?? "")
        }

        static func freshLabel() -> String {
            "wstest-\(UUID().uuidString.prefix(8).lowercased())"
        }

        @discardableResult
        static func tmux(_ label: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-f", "/dev/null", "-L", label] + arguments
            process.environment = TmuxSessionProbe.defaultEnvironment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        @discardableResult
        func tmux(_ arguments: [String]) throws -> (status: Int32, output: String) {
            try Self.tmux(label, arguments)
        }

        /// Kills the server by pid and unlinks its socket file, which a killed server leaves.
        func killServer() {
            guard let serverPID else { return }
            kill(pid_t(serverPID), SIGKILL)
            if socketPath.contains("wstest-") {
                try? FileManager.default.removeItem(atPath: socketPath)
            }
        }

        func serverIsGone() -> Bool {
            guard let serverPID else { return true }
            return kill(pid_t(serverPID), 0) != 0
        }

        /// Kills the server by pid and waits until it is gone.
        func killServerAndWait() async -> Bool {
            killServer()
            return await waitUntil(timeout: 10) { serverIsGone() }
        }
    }

    private static var tmuxIsInstalled: Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["tmux", "-V"]
        probe.environment = TmuxSessionProbe.defaultEnvironment
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

    private func classify(
        _ label: String, session: String, launchServerPID: Int?
    ) async
        -> (TmuxHolderState, TerminalSessionExit)
    {
        let state = await TmuxHolderProbe(socketLabel: label).holderState(forSessionNamed: session)
        let exit = TerminalSessionExit.classifyProcessExit(tmuxHolder: state, launchServerPID: launchServerPID)
        return (state, exit)
    }

    @Test(
        "A shell that exited on a live server is not restorable",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func shellExitOnLiveServerEndsTheRow() async throws {
        let server = try IsolatedTmuxServer.start(session: "keeper")
        defer { server.killServer() }
        try server.tmux(["new-session", "-d", "-s", "tile", "sleep 600"])
        try server.tmux(["kill-session", "-t", "=tile"])

        let (state, exit) = await classify(server.label, session: "tile", launchServerPID: server.serverPID)

        #expect(state == .sessionGone(serverPID: server.serverPID))
        #expect(exit == .shellExited)
        #expect(exit.rowOutcome == .end)
    }

    /// With `exit-empty` off, the server outlives the tile's session, so the last session
    /// ending is told apart from the server dying.
    @Test(
        "The last session ending reads as the shell's exit",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func lastSessionEndingIsTheShells() async throws {
        let server = try IsolatedTmuxServer.start(session: "tile")
        defer { server.killServer() }
        try server.tmux(["kill-session", "-t", "=tile"])

        let (state, exit) = await classify(server.label, session: "tile", launchServerPID: server.serverPID)

        #expect(!server.serverIsGone())
        #expect(state == .sessionGone(serverPID: server.serverPID))
        #expect(exit == .shellExited)
    }

    @Test(
        "A tile whose tmux server died stays restorable",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func serverDeathKeepsTheRow() async throws {
        let server = try IsolatedTmuxServer.start(session: "keeper")
        defer { server.killServer() }
        try server.tmux(["new-session", "-d", "-s", "tile", "sleep 600"])
        #expect(await server.killServerAndWait())

        let (state, exit) = await classify(server.label, session: "tile", launchServerPID: server.serverPID)

        #expect(state == .serverGone)
        #expect(exit == .holderLost)
        #expect(exit.rowOutcome == .markHolderLost)
    }

    @Test(
        "The only tile on a server that was killed stays restorable",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func loneTileServerDeathKeepsTheRow() async throws {
        let server = try IsolatedTmuxServer.start(session: "tile")
        defer { server.killServer() }
        #expect(await server.killServerAndWait())

        let (state, exit) = await classify(server.label, session: "tile", launchServerPID: nil)

        #expect(state == .serverGone)
        #expect(exit == .holderLost)
    }

    /// A server started on the socket after the tile's own died answers for the name, maybe
    /// with a session of the same name. It is not the tile's holder.
    @Test(
        "A server that restarted under the tile reads as a lost holder",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func restartedServerIsALostHolder() async throws {
        let original = try IsolatedTmuxServer.start(session: "tile")
        defer { original.killServer() }
        #expect(await original.killServerAndWait())
        let replacement = try IsolatedTmuxServer.start(session: "tile", label: original.label)
        defer { replacement.killServer() }
        #expect(replacement.serverPID != original.serverPID)

        let (state, exit) = await classify(original.label, session: "tile", launchServerPID: original.serverPID)

        #expect(state == .sessionPresent(serverPID: replacement.serverPID))
        #expect(exit == .holderLost)
    }

    @Test(
        "A client that left a running session keeps the row open",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func detachedSessionKeepsTheRowOpen() async throws {
        let server = try IsolatedTmuxServer.start(session: "tile")
        defer { server.killServer() }

        let (state, exit) = await classify(server.label, session: "tile", launchServerPID: server.serverPID)

        #expect(state == .sessionPresent(serverPID: server.serverPID))
        #expect(exit == .detached)
        #expect(exit.rowOutcome == .keepOpen)
    }

    @Test("A probe that reaches a server as it dies reads the server as gone")
    func dyingServerMessagesReadAsServerGone() {
        for stderr in [
            "server exited unexpectedly",
            "lost server",
            "no server running on /private/tmp/tmux-501/x",
            "error connecting to /private/tmp/tmux-501/x (No such file or directory)",
        ] {
            let state = TmuxHolderProbe.holderState(exitCode: 1, stdout: "", stderr: stderr, sessionName: "tile")
            #expect(state == .serverGone, "\(stderr)")
        }
    }

    @Test("The probe reads the server's pid first and the session names after it")
    func probeOutputParses() {
        #expect(
            TmuxHolderProbe.holderState(exitCode: 0, stdout: "4242\nkeeper\ntile\n", stderr: "", sessionName: "tile")
                == .sessionPresent(serverPID: 4242))
        #expect(
            TmuxHolderProbe.holderState(exitCode: 0, stdout: "4242\n", stderr: "", sessionName: "tile")
                == .sessionGone(serverPID: 4242))
    }

    @Test("A tile that did not launch through tmux ends as a shell exit")
    func plainShellExitEndsTheRow() {
        let exit = TerminalSessionExit.classifyProcessExit(tmuxHolder: nil, launchServerPID: nil)
        #expect(exit == .shellExited)
    }

    @Test("An unanswered probe keeps the row open, as its own reason")
    func unansweredProbeKeepsTheRow() {
        let state = TmuxHolderProbe.holderState(
            exitCode: 1, stdout: "", stderr: "unknown option -- Z", sessionName: "tile")
        let exit = TerminalSessionExit.classifyProcessExit(tmuxHolder: state, launchServerPID: 4242)
        #expect(state == .unanswered)
        #expect(exit == .undetermined)
        #expect(exit.rowOutcome == .keepOpen)
    }

    @Test("A user close ends the row")
    func userCloseEndsTheRow() {
        #expect(TerminalSessionExit.userClosed.rowOutcome == .end)
    }

    private static let everyExit: [TerminalSessionExit] = [
        .userClosed, .shellExited, .holderLost, .detached, .undetermined,
    ]

    @Test("Only a user close reclaims the tile's own tmux session")
    func onlyAUserCloseReclaims() {
        #expect(Self.everyExit.filter(\.reclaimsTmuxSession) == [.userClosed])
    }

    @Test("Split panes torn down with their tab keep or end their rows as the tab does")
    func panesFollowTheirTab() {
        for exit in Self.everyExit {
            #expect(exit.collateralExit.rowOutcome == exit.rowOutcome, "\(exit)")
        }
    }
}
