//
//  TerminalSessionExitTests.swift
//  WorkspaceManagerTests
//
//  How a tmux-backed tile's exit is read, against a real tmux server on an isolated
//  socket label. Each test starts its own server, ends it by pid, and never names the
//  app's shared socket.
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
        let serverPID: pid_t?

        /// Starts a server whose `keeperSession` keeps it running.
        static func start(keeperSession: String) throws -> IsolatedTmuxServer {
            let label = "wstest-\(UUID().uuidString.prefix(8).lowercased())"
            try tmux(label, ["new-session", "-d", "-s", keeperSession, "sleep 600"])
            let pid = try tmux(label, ["display-message", "-p", "-t", "=\(keeperSession)", "#{pid}"]).output
            return IsolatedTmuxServer(
                label: label, serverPID: pid_t(pid.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        @discardableResult
        static func tmux(_ label: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-L", label] + arguments
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

        func killServer() {
            guard let serverPID else { return }
            kill(serverPID, SIGKILL)
        }

        func serverIsGone() -> Bool {
            guard let serverPID else { return true }
            return kill(serverPID, 0) != 0
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
        _ server: IsolatedTmuxServer, session: String, serverHeldOtherSessions: Bool
    ) async
        -> (TmuxHolderState, TerminalSessionExit)
    {
        let state = await TmuxHolderProbe(socketLabel: server.label).holderState(forSessionNamed: session)
        let exit = TerminalSessionExit.classifyProcessExit(
            tmuxHolder: state, serverHeldOtherSessions: serverHeldOtherSessions)
        return (state, exit)
    }

    @Test(
        "A shell that exited on a live server is not restorable",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func shellExitOnLiveServerEndsTheRow() async throws {
        let server = try IsolatedTmuxServer.start(keeperSession: "keeper")
        defer { server.killServer() }
        try server.tmux(["new-session", "-d", "-s", "tile", "sleep 600"])
        try server.tmux(["kill-session", "-t", "=tile"])

        let (state, exit) = await classify(server, session: "tile", serverHeldOtherSessions: true)

        #expect(state == .sessionGone)
        #expect(exit == .shellExited)
        #expect(exit.rowOutcome == .end)
    }

    @Test(
        "A tile whose tmux server died stays restorable",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func serverDeathKeepsTheRow() async throws {
        let server = try IsolatedTmuxServer.start(keeperSession: "keeper")
        defer { server.killServer() }
        try server.tmux(["new-session", "-d", "-s", "tile", "sleep 600"])
        server.killServer()
        #expect(await waitUntil(timeout: 10) { server.serverIsGone() })

        let (state, exit) = await classify(server, session: "tile", serverHeldOtherSessions: true)

        #expect(state == .serverGone)
        #expect(exit == .holderLost)
        #expect(exit.rowOutcome == .markHolderLost)
    }

    @Test(
        "A client that left a running session keeps the row open",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func detachedSessionKeepsTheRowOpen() async throws {
        let server = try IsolatedTmuxServer.start(keeperSession: "tile")
        defer { server.killServer() }

        let (state, exit) = await classify(server, session: "tile", serverHeldOtherSessions: false)

        #expect(state == .sessionPresent)
        #expect(exit == .detached)
        #expect(exit.rowOutcome == .keepOpen)
    }

    /// tmux exits its server when the last session ends, which from outside looks exactly
    /// like the server being killed. Without another tile on the server, the exit is the
    /// shell's.
    @Test(
        "The last session ending reads as the shell's exit, not a lost holder",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func lastSessionEndingIsTheShells() async throws {
        let server = try IsolatedTmuxServer.start(keeperSession: "tile")
        defer { server.killServer() }
        try server.tmux(["kill-session", "-t", "=tile"])
        #expect(await waitUntil(timeout: 10) { server.serverIsGone() })

        let (state, exit) = await classify(server, session: "tile", serverHeldOtherSessions: false)

        #expect(state == .serverGone)
        #expect(exit == .shellExited)
    }

    @Test("A tile that did not launch through tmux ends as a shell exit")
    func plainShellExitEndsTheRow() {
        let exit = TerminalSessionExit.classifyProcessExit(tmuxHolder: nil, serverHeldOtherSessions: true)
        #expect(exit == .shellExited)
    }

    @Test("An unanswered probe reads as the shell's exit")
    func unansweredProbeEndsTheRow() {
        let state = TmuxHolderProbe.holderState(
            exitCode: 1, stdout: "", stderr: "unknown option -- Z", sessionName: "tile")
        #expect(state == .unanswered)
        #expect(
            TerminalSessionExit.classifyProcessExit(tmuxHolder: state, serverHeldOtherSessions: true)
                == .shellExited)
    }

    @Test("A user close ends the row")
    func userCloseEndsTheRow() {
        #expect(TerminalSessionExit.userClosed.rowOutcome == .end)
    }
}
