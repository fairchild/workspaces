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

    /// Reads the label as the app does: what its server says about `session`, and whether
    /// the server keeps running when empty, as a launch learned it while the server was up.
    private func classify(
        _ label: String, session: String, launchServerPID: Int?, keepsRunningWhenEmpty: Bool?
    ) async
        -> (TmuxHolderState, TerminalSessionExit)
    {
        let state = await TmuxHolderProbe(socketLabel: label).holderState(for: .init(name: session))
        let exit = TerminalSessionExit.classifyProcessExit(
            tmuxHolder: state, launchServerPID: launchServerPID, serverKeepsRunningWhenEmpty: keepsRunningWhenEmpty)
        return (state, exit)
    }

    /// What a launch learns about the label while its server is up.
    private func learnExitEmpty(_ server: IsolatedTmuxServer) async -> Bool? {
        guard let serverPID = server.serverPID else { return nil }
        let capability = TmuxExitEmptyCapability()
        await capability.learn(onSocket: server.label, serverPID: serverPID)
        return await capability.keepsRunningWhenEmpty(onSocket: server.label, serverPID: serverPID)
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

        let (state, exit) = await classify(
            server.label, session: "tile", launchServerPID: server.serverPID,
            keepsRunningWhenEmpty: await learnExitEmpty(server))

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
        let keepsRunningWhenEmpty = await learnExitEmpty(server)
        try server.tmux(["kill-session", "-t", "=tile"])

        let (state, exit) = await classify(
            server.label, session: "tile", launchServerPID: server.serverPID,
            keepsRunningWhenEmpty: keepsRunningWhenEmpty)

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
        let keepsRunningWhenEmpty = await learnExitEmpty(server)
        #expect(await server.killServerAndWait())

        let (state, exit) = await classify(
            server.label, session: "tile", launchServerPID: server.serverPID,
            keepsRunningWhenEmpty: keepsRunningWhenEmpty)

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
        let keepsRunningWhenEmpty = await learnExitEmpty(server)
        #expect(await server.killServerAndWait())

        let (state, exit) = await classify(
            server.label, session: "tile", launchServerPID: nil, keepsRunningWhenEmpty: keepsRunningWhenEmpty)

        #expect(keepsRunningWhenEmpty == true)
        #expect(state == .serverGone)
        #expect(exit == .holderLost)
    }

    /// The launch learns the server's pid only once its ownership read finds the session.
    /// A replacement server answering before then cannot be told from the original, so the
    /// tile's name missing there says nothing about its shell.
    @Test(
        "A replacement server answering before the launch's server was recorded leaves the exit undetermined",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func replacementBeforeLaunchIdentityIsUndetermined() async throws {
        let original = try IsolatedTmuxServer.start(session: "tile")
        defer { original.killServer() }
        let keepsRunningWhenEmpty = await learnExitEmpty(original)
        #expect(await original.killServerAndWait())
        let replacement = try IsolatedTmuxServer.start(session: "other", label: original.label)
        defer { replacement.killServer() }

        let (state, exit) = await classify(
            original.label, session: "tile", launchServerPID: nil, keepsRunningWhenEmpty: keepsRunningWhenEmpty)

        #expect(state == .sessionGone(serverPID: replacement.serverPID))
        #expect(exit == .undetermined)
        #expect(exit.rowOutcome == .keepOpen)
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

        let (state, exit) = await classify(
            original.label, session: "tile", launchServerPID: original.serverPID, keepsRunningWhenEmpty: true)

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

        let (state, exit) = await classify(
            server.label, session: "tile", launchServerPID: server.serverPID, keepsRunningWhenEmpty: true)

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
            let state = TmuxHolderProbe.holderState(
                exitCode: 1, stdout: "", stderr: stderr, session: .init(name: "tile"))
            #expect(state == .serverGone, "\(stderr)")
        }
    }

    @Test("The probe reads the server's pid first and each session's id and name after it")
    func probeOutputParses() {
        #expect(
            TmuxHolderProbe.holderState(
                exitCode: 0, stdout: "4242\n$0\tkeeper\n$1\ttile\n", stderr: "", session: .init(name: "tile"))
                == .sessionPresent(serverPID: 4242))
        #expect(
            TmuxHolderProbe.holderState(exitCode: 0, stdout: "4242\n", stderr: "", session: .init(name: "tile"))
                == .sessionGone(serverPID: 4242))
    }

    /// The app recorded tmux's id for the session the tile launched into. A rename keeps
    /// the id, so the session is still held; the name still counts, since the record can
    /// be older than the session this launch attached to.
    @Test("The probe finds a session by its recorded id after a rename, and by its name")
    func probeFindsTheSessionByIDOrName() {
        func state(_ listing: String, id: String?) -> TmuxHolderState {
            TmuxHolderProbe.holderState(
                exitCode: 0, stdout: listing, stderr: "", session: .init(name: "tile", id: id))
        }
        #expect(state("4242\n$7\trenamed\n", id: "$7") == .sessionPresent(serverPID: 4242))
        #expect(state("4242\n$7\trenamed\n", id: nil) == .sessionGone(serverPID: 4242))
        #expect(state("4242\n$9\ttile\n", id: "$7") == .sessionPresent(serverPID: 4242))
        #expect(state("4242\n$9\tother\n$1\ttiles\n", id: "$7") == .sessionGone(serverPID: 4242))
    }

    @Test(
        "A session renamed after its tile launched is still the tile's, and a detach reads as one",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func renamedSessionIsStillHeld() async throws {
        let server = try IsolatedTmuxServer.start(session: "tile")
        defer { server.killServer() }
        let listing = try server.tmux(["list-sessions", "-F", "#{session_id}\t#{session_name}"]).output
        let rows: [[String]] = listing.split(separator: "\n").map { line in
            line.split(separator: "\t").map(String.init)
        }
        let id = try #require(rows.first { $0.count == 2 && $0[1] == "tile" }?[0])
        try server.tmux(["rename-session", "-t", "=tile", "renamed"])

        let state = await TmuxHolderProbe(socketLabel: server.label).holderState(for: .init(name: "tile", id: id))
        let exit = TerminalSessionExit.classifyProcessExit(
            tmuxHolder: state, launchServerPID: server.serverPID, serverKeepsRunningWhenEmpty: true)

        #expect(id.hasPrefix("$"))
        #expect(state == .sessionPresent(serverPID: server.serverPID))
        #expect(exit == .detached)
    }

    @Test("A tile that did not launch through tmux ends as a shell exit")
    func plainShellExitEndsTheRow() {
        let exit = TerminalSessionExit.classifyProcessExit(
            tmuxHolder: nil, launchServerPID: nil, serverKeepsRunningWhenEmpty: nil)
        #expect(exit == .shellExited)
    }

    /// Before 2.7 an empty server exits, so the last shell ending takes the server with it.
    /// Read as a lost holder, every ordinary last exit would keep its row as restorable.
    @Test("A server gone from a tmux that cannot keep it running when empty leaves the exit undetermined")
    func goneServerWithoutExitEmptyIsUndetermined() {
        for keepsRunningWhenEmpty: Bool? in [false, nil] {
            let exit = TerminalSessionExit.classifyProcessExit(
                tmuxHolder: .serverGone, launchServerPID: 4242, serverKeepsRunningWhenEmpty: keepsRunningWhenEmpty)
            #expect(exit == .undetermined, "\(String(describing: keepsRunningWhenEmpty))")
        }
    }

    @Test(
        "A launch learns that a server keeps running when empty from exit-empty off, and nothing while no server answers",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func exitEmptyIsLearnedFromARunningServer() async throws {
        let capability = TmuxExitEmptyCapability()
        let label = IsolatedTmuxServer.freshLabel()
        await capability.learn(onSocket: label, serverPID: 4242)
        #expect(await capability.keepsRunningWhenEmpty(onSocket: label, serverPID: 4242) == nil)

        let server = try IsolatedTmuxServer.start(session: "tile", label: label)
        defer { server.killServer() }
        let serverPID = try #require(server.serverPID)
        await capability.learn(onSocket: label, serverPID: serverPID)
        #expect(await capability.keepsRunningWhenEmpty(onSocket: label, serverPID: serverPID) == true)
        #expect(await capability.keepsRunningWhenEmpty(onSocket: label, serverPID: serverPID + 1) == nil)
        #expect(await capability.keepsRunningWhenEmpty(onSocket: label, serverPID: nil) == nil)
    }

    @Test(
        "A server whose exit-empty is on is not learned as keeping running when empty",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func exitEmptyOnIsNotKeepingRunning() async throws {
        let server = try IsolatedTmuxServer.start(session: "tile")
        defer { server.killServer() }
        try server.tmux(["set-option", "-s", "exit-empty", "on"])
        #expect(await learnExitEmpty(server) == false)
    }

    @Test("Only exit-empty off keeps a server running when empty; a rejected option keeps nothing")
    func exitEmptyReadings() {
        typealias Reading = TmuxExitEmptyCapability.Reading
        #expect(
            TmuxExitEmptyCapability.reading(exitCode: 0, stdout: "4242\nexit-empty off\n", stderr: "")
                == Reading(serverPID: 4242, keepsRunningWhenEmpty: true))
        #expect(
            TmuxExitEmptyCapability.reading(exitCode: 0, stdout: "4242\nexit-empty on\n", stderr: "")
                == Reading(serverPID: 4242, keepsRunningWhenEmpty: false))
        #expect(
            TmuxExitEmptyCapability.reading(exitCode: 1, stdout: "4242\n", stderr: "unknown option: exit-empty")
                == Reading(serverPID: 4242, keepsRunningWhenEmpty: false))
        #expect(
            TmuxExitEmptyCapability.reading(exitCode: 1, stdout: "4242\n", stderr: "invalid option: exit-empty")
                == Reading(serverPID: 4242, keepsRunningWhenEmpty: false))
        #expect(
            TmuxExitEmptyCapability.reading(
                exitCode: 1, stdout: "", stderr: "no server running on /private/tmp/tmux-501/x") == nil)
    }

    /// Counts reads, holding each while the gate is shut; an open gate answers at once.
    private actor GatedReads {
        private(set) var count = 0
        private var answer: Int?
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func read() async -> TmuxExitEmptyCapability.Reading? {
            count += 1
            if answer == nil {
                await withCheckedContinuation { waiting.append($0) }
            }
            return answer.map { TmuxExitEmptyCapability.Reading(serverPID: $0, keepsRunningWhenEmpty: true) }
        }

        func open(answering serverPID: Int) {
            answer = serverPID
            waiting.forEach { $0.resume() }
            waiting = []
        }

        func shut() {
            answer = nil
        }

        var pending: Int { waiting.count }
    }

    @Test("Concurrent learns share one read, and a new server pid is learned again")
    func learnsAreCoalescedAndKeyedByServer() async {
        let reads = GatedReads()
        let capability = TmuxExitEmptyCapability(read: { _ in await reads.read() })

        async let first: Void = capability.learn(onSocket: "x", serverPID: 4242)
        async let second: Void = capability.learn(onSocket: "x", serverPID: 4242)
        #expect(await waitUntil(timeout: 10) { await reads.pending >= 1 })
        try? await Task.sleep(nanoseconds: 50_000_000)
        await reads.open(answering: 4242)
        _ = await (first, second)
        #expect(await reads.count == 1)
        #expect(await capability.keepsRunningWhenEmpty(onSocket: "x", serverPID: 4242) == true)

        await capability.learn(onSocket: "x", serverPID: 4242)
        #expect(await reads.count == 1)

        await reads.shut()
        async let replaced: Void = capability.learn(onSocket: "x", serverPID: 5353)
        #expect(await waitUntil(timeout: 10) { await reads.pending == 1 })
        await reads.open(answering: 5353)
        await replaced
        #expect(await reads.count == 2)
        #expect(await capability.keepsRunningWhenEmpty(onSocket: "x", serverPID: 5353) == true)
        #expect(await capability.keepsRunningWhenEmpty(onSocket: "x", serverPID: 4242) == nil)
    }

    /// A tmux client attached to `session` under a pseudo-terminal, as a terminal tile's is:
    /// a shell leads the pty's foreground process group, as `login` does for a tile, and runs
    /// the client as a child in that group.
    private struct AttachedClient {
        let script: Process
        let input: Pipe
        /// The pty's foreground process group, led by the shell.
        let group: Int
        let clientPID: Int

        static func attach(_ server: IsolatedTmuxServer, session: String) async throws -> AttachedClient {
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            script.arguments = [
                "-q", "/dev/null", "/bin/sh", "-c",
                "/usr/bin/env tmux -f /dev/null -L \(server.label) attach -t '=\(session)'; :",
            ]
            var environment = TmuxSessionProbe.defaultEnvironment
            environment["TERM"] = "xterm-256color"
            script.environment = environment
            let input = Pipe()
            script.standardInput = input
            script.standardOutput = FileHandle.nullDevice
            script.standardError = FileHandle.nullDevice
            try script.run()
            let scriptPID = Int(script.processIdentifier)
            var found: (group: Int, client: Int)?
            _ = await waitUntil(timeout: 10) {
                guard let listing = try? server.tmux(["list-clients", "-F", "#{client_pid}"]).output else {
                    return false
                }
                return listing.split(separator: "\n").contains { line in
                    guard let client = Int(line), let shell = Self.parent(of: client) else { return false }
                    return Self.parent(of: shell) == scriptPID && Int(getpgid(pid_t(client))) == shell
                }
            }
            let listing = try server.tmux(["list-clients", "-F", "#{client_pid}"]).output
            for client in listing.split(separator: "\n").compactMap({ Int($0) }) {
                if let shell = Self.parent(of: client), Self.parent(of: shell) == scriptPID,
                    Int(getpgid(pid_t(client))) == shell
                {
                    found = (shell, client)
                }
            }
            guard let found else {
                script.terminate()
                throw AttachFailed()
            }
            return AttachedClient(script: script, input: input, group: found.group, clientPID: found.client)
        }

        private struct AttachFailed: Error {}

        private static func parent(of pid: Int) -> Int? {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(pid_t(pid), PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            return size == Int32(MemoryLayout<proc_bsdinfo>.size) ? Int(info.pbi_ppid) : nil
        }

        /// Kills the group only while its shell is still the `script`'s child, so a reused
        /// pid is left alone.
        func detach() {
            if Self.parent(of: group) == Int(script.processIdentifier) {
                kill(-pid_t(group), SIGKILL)
            }
            if script.isRunning {
                kill(script.processIdentifier, SIGKILL)
            }
        }
    }

    @Test(
        "A launch's server is the one a client from its terminal's foreground group is attached to",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func launchServerIsTheOneItsClientIsAttachedTo() async throws {
        let server = try IsolatedTmuxServer.start(session: "tile")
        defer { server.killServer() }
        try server.tmux(["new-session", "-d", "-s", "other", "sleep 600"])
        let client = try await AttachedClient.attach(server, session: "tile")
        defer { client.detach() }
        let probe = TmuxHolderProbe(socketLabel: server.label)

        #expect(client.clientPID != client.group)
        #expect(
            await probe.serverPID(attachingClientInGroup: client.group, toSessionNamed: "tile") == server.serverPID)
        #expect(await probe.serverPID(attachingClientInGroup: client.group, toSessionNamed: "other") == nil)
        #expect(
            await probe.serverPID(attachingClientInGroup: Int(getpgrp()), toSessionNamed: "tile") == nil)
    }

    /// The launch's server died before its identity was read, and a new server on the
    /// label holds a session with the same name and a client of its own. Reading whatever
    /// server answers would certify the replacement as the launch's server.
    @Test(
        "A replacement server holding the same session is not taken for the launch's server",
        .enabled(if: tmuxIsInstalled, "tmux is not installed")
    )
    func replacementServerIsNotTheLaunchServer() async throws {
        let original = try IsolatedTmuxServer.start(session: "tile")
        let launchClient = try await AttachedClient.attach(original, session: "tile")
        defer { launchClient.detach() }
        #expect(await original.killServerAndWait())

        let replacement = try IsolatedTmuxServer.start(session: "tile", label: original.label)
        defer { replacement.killServer() }
        let foreignClient = try await AttachedClient.attach(replacement, session: "tile")
        defer { foreignClient.detach() }
        let probe = TmuxHolderProbe(socketLabel: original.label)

        #expect(
            await probe.serverPID(attachingClientInGroup: launchClient.group, toSessionNamed: "tile") == nil)
        #expect(
            await probe.serverPID(attachingClientInGroup: foreignClient.group, toSessionNamed: "tile")
                == replacement.serverPID)
    }

    @Test("A server's identity needs its listing to show a client from this group on this session")
    func serverIdentityParsing() {
        let listing = "4242\n777\ttile\n888\tother\n999\ttile\n"
        let groups = [777: 70, 888: 80]
        func serverPID(_ listing: String, group: Int, session: String) -> Int? {
            TmuxHolderProbe.serverPID(
                listing: listing, attachingClientInGroup: group, toSessionNamed: session,
                processGroup: { groups[$0] })
        }
        #expect(serverPID(listing, group: 70, session: "tile") == 4242)
        #expect(serverPID(listing, group: 80, session: "tile") == nil)
        #expect(serverPID(listing, group: 777, session: "tile") == nil)
        #expect(serverPID(listing, group: 70, session: "til") == nil)
        #expect(serverPID("4242\n", group: 70, session: "tile") == nil)
        #expect(serverPID("", group: 70, session: "tile") == nil)
    }

    @Test("An unanswered probe keeps the row open, as its own reason")
    func unansweredProbeKeepsTheRow() {
        let state = TmuxHolderProbe.holderState(
            exitCode: 1, stdout: "", stderr: "unknown option -- Z", session: .init(name: "tile"))
        let exit = TerminalSessionExit.classifyProcessExit(
            tmuxHolder: state, launchServerPID: 4242, serverKeepsRunningWhenEmpty: true)
        #expect(state == .unanswered)
        #expect(exit == .undetermined)
        #expect(exit.rowOutcome == .keepOpen)
    }

    @Test("A user close ends the row")
    func userCloseEndsTheRow() {
        #expect(TerminalSessionExit.userClosed.rowOutcome == .end)
    }

    private static let everyExit: [TerminalSessionExit] = [
        .userClosed, .retired, .shellExited, .holderLost, .detached, .undetermined,
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

    /// A pane whose row ends while its pane-scoped session runs on has no way back, so a
    /// pane closed because its tab's shell ended is reclaimed, as closing the tab would.
    @Test("A pane's tmux session is reclaimed only when its tab was closed or its tab's shell ended")
    func panesAreReclaimedOnlyWithAClosedTab() {
        #expect(Self.everyExit.filter(\.collateralExit.reclaimsTmuxSession) == [.userClosed, .shellExited])
    }
}
