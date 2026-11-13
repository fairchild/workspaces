//
//  CLIConversationResumeTests.swift
//  WorkspaceManagerTests
//
//  Drives `workspaces conversation resume` through the real binary with a stub claude, so the
//  guards are proven where they matter: across processes, through an exec, and against a real
//  tmux server. Every run gets its own config, records directory, `HOME`, and tmux socket
//  inside a scratch root, and the CLI never sees the caller's `TMUX`, so nothing here reads or
//  writes a live session.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("CLI conversation resume", .serialized)
struct CLIConversationResumeTests {

    /// Stands in for claude: says what it was started with, runs the SessionStart hook for
    /// each id in `STUB_HOOK_IDS` the way claude does (a child of this process), then exits,
    /// or stays alive under its own name when `STUB_STAY` is set, as an agent holding its
    /// conversation does. It stays at most five minutes, and no longer than its fixture: a
    /// killed test run leaves nothing behind that outlives either.
    private static let stubClaude = #"""
        #!/bin/sh
        printf 'stub argv=%s\n' "$*"
        printf 'stub config=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
        printf 'stub pwd=%s\n' "$(pwd -P)"
        for id in $STUB_HOOK_IDS; do
          printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s/%s.jsonl"}' \
            "$id" "$PWD" "$STUB_TRANSCRIPTS" "$id" | "$STUB_HOOK_CLI" conversation observe
        done
        if [ -n "$STUB_STAY" ]; then
          n=0
          while [ -e "$0" ] && [ "$n" -lt 300 ]; do sleep 1; n=$((n + 1)); done
        fi
        """#

    private struct Fixture {
        let binary: URL
        let root: URL
        let socketLabel = "cr-\(UUID().uuidString.prefix(8).lowercased())"

        var bin: URL { root.appendingPathComponent("bin") }
        var home: URL { root.appendingPathComponent("home") }
        var work: URL { root.appendingPathComponent("work") }
        var stub: URL { bin.appendingPathComponent("claude") }
        var records: ConversationRecordStore {
            ConversationRecordStore(directory: root.appendingPathComponent("conversations"))
        }

        /// The caller's environment without anything that names a session, a tile, or another
        /// agent's account, plus this fixture's world.
        var environment: [String: String] {
            ProcessInfo.processInfo.environment
                .filter { key, _ in
                    !["TMUX", "TMUX_PANE"].contains(key) && !key.hasPrefix("WORKSPACES_") && !key.hasPrefix("CLAUDE")
                }
                .merging([
                    "HOME": home.path,
                    "PATH": "\(bin.path):/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                    "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                    ConversationRecordStore.directoryEnvironmentKey: root.appendingPathComponent("conversations").path,
                    "TMUX_TMPDIR": root.path,
                    TmuxSessionControl.socketLabelEnvironmentKey: socketLabel,
                ]) { _, new in new }
        }

        var transcripts: URL { home.appendingPathComponent(".claude/projects/p") }

        func start(
            _ arguments: [String],
            executable: URL? = nil,
            extraEnvironment: [String: String] = [:],
            output: URL
        ) throws -> Process {
            let process = Process()
            process.executableURL = executable ?? binary
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.environment = environment.merging(extraEnvironment) { _, new in new }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            return process
        }

        /// Runs to completion with exactly this fixture's environment, less `without`.
        /// `CLIBinary.run` merges the caller's own back in, which would hand `--here` the test
        /// runner's `$TMUX`.
        func run(
            _ arguments: [String],
            extraEnvironment: [String: String] = [:],
            without: (String) -> Bool = { _ in false }
        ) throws -> CLIBinary.Invocation {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.environment = environment.filter { !without($0.key) }.merging(extraEnvironment) { _, new in new }
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return CLIBinary.Invocation(
                status: process.terminationStatus,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self)
            )
        }

        func tmux(_ arguments: [String]) throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-L", socketLabel] + arguments
            process.environment = environment
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        func teardown() {
            _ = try? tmux(["kill-server"])
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static var tmuxIsInstalled: Bool {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["tmux", "-V"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0
    }

    /// Rooted at `/tmp` because a tmux socket path has to fit in `sun_path`.
    private func makeFixture() throws -> Fixture {
        let binary = try #require(CLIBinary.url, CLIBinary.missingBinaryMessage)
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("wscr-\(UUID().uuidString.prefix(8))")
        let fixture = Fixture(binary: binary, root: root)
        for directory in [fixture.bin, fixture.home, fixture.work] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Self.stubClaude.write(to: fixture.stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.stub.path)
        return fixture
    }

    /// A conversation recorded on this host, with a transcript where the hook said it is.
    private func recordConversation(
        in fixture: Fixture,
        host: String = ConversationHost.current,
        lastSeenIn: ConversationRecord.LastSeenIn? = nil
    ) throws -> String {
        let conversationID = UUID().uuidString.lowercased()
        let transcript = fixture.home.appendingPathComponent(".claude/projects/p/\(conversationID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: transcript.path, contents: Data())
        try fixture.records.record(
            ConversationObservation(
                conversationID: conversationID,
                host: host,
                cwd: fixture.work.path,
                transcriptPath: transcript.path,
                socketLabel: lastSeenIn?.tmux == nil ? nil : fixture.socketLabel,
                observedBy: .hook,
                lastSeenIn: lastSeenIn
            )
        )
        return conversationID
    }

    private func holders(of conversationID: String, in fixture: Fixture) async throws -> [ConversationHolder] {
        let probe = ConversationHolderProbe(records: fixture.records, fallbackSocketLabel: fixture.socketLabel)
        guard case .held(let holders, _) = await probe.probe(conversationID: conversationID) else { return [] }
        return holders
    }

    /// SIGKILL, because the test runner ignores SIGTERM and its children inherit that.
    private static func kill(_ processes: [Process]) {
        for process in processes where process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Until `condition` holds or the launch budget for `launches` runs out.
    private func waitUntil(launches: Double, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(
            await LaunchBudget.deadline(launches: launches, floor: 10, ceiling: 60))
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A split config is two callers whose `XDG_CONFIG_HOME` differ, as a tile's and a
    /// login shell's can; the records directory is what they share.
    @Test("Two concurrent resumes of one conversation start one agent", arguments: [false, true])
    func concurrentResumesStartOneAgent(splitConfig: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)

        let outputs = (0..<2).map { fixture.root.appendingPathComponent("resume-\($0).log") }
        let resumes = try outputs.enumerated().map { index, output in
            var environment = ["STUB_STAY": "1", "CLAUDE_CONFIG_DIR": "/nonexistent-caller-profile"]
            if splitConfig {
                environment["XDG_CONFIG_HOME"] = fixture.root.appendingPathComponent("config-\(index)").path
            }
            return try fixture.start(
                ["conversation", "resume", conversationID, "--here"], extraEnvironment: environment, output: output)
        }
        defer { Self.kill(resumes) }

        let deadline = Date().addingTimeInterval(await LaunchBudget.deadline(launches: 4, floor: 20, ceiling: 120))
        while resumes.allSatisfy(\.isRunning), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let refused = try #require(resumes.firstIndex { !$0.isRunning }, "neither resume finished: two agents run")
        let agent = resumes[1 - refused]
        #expect(resumes[refused].terminationStatus == 3)
        #expect(agent.isRunning)

        let refusal = try String(contentsOf: outputs[refused], encoding: .utf8)
        #expect(refusal.contains("already held"))
        #expect(refusal.contains("pid \(agent.processIdentifier)"))
        #expect(!refusal.contains("may have switched"))
        let started = try String(contentsOf: outputs[1 - refused], encoding: .utf8)
        #expect(started.contains("stub argv=--resume \(conversationID)"))
        #expect(started.contains("stub config=unset"))
        #expect(try await holders(of: conversationID, in: fixture).map(\.pid) == [agent.processIdentifier])
    }

    /// A bare stub in a tmux session on the fixture's socket: nothing in its arguments names
    /// a conversation, the way a person types `claude` before switching with /resume. Its
    /// server's pid, the session's id, creation time and socket path, in that order.
    private func startHeldTile(in fixture: Fixture) async throws -> [String] {
        _ = try fixture.tmux(["new-session", "-d", "-s", "held-tile", "STUB_STAY=1 \(fixture.stub.path)"])
        try await waitUntil(launches: 2) {
            try await ProcessTable.read()?.rows.contains { $0.arguments.contains(fixture.stub.path) } == true
        }
        let identity = try fixture.tmux([
            "-u", "display-message", "-p", "-t", "=held-tile:",
            "#{pid}\t#{session_id}\t#{session_created}\t#{socket_path}",
        ]).trimmingCharacters(in: .newlines).split(separator: "\t").map(String.init)
        try #require(identity.count == 4)
        return identity
    }

    private func tmuxSession(_ identity: [String], recordingSocket: Bool) throws -> ConversationRecord.TmuxSession {
        let serverPID = try #require(Int32(identity[0]))
        return .init(
            serverPID: Int(serverPID),
            sessionID: identity[1],
            createdAt: Date(timeIntervalSince1970: try #require(TimeInterval(identity[2]))),
            name: "held-tile",
            socketPath: recordingSocket ? identity[3] : nil,
            serverStartedAtMicroseconds: recordingSocket
                ? try #require(ProcessInspector.live.identity(serverPID)).startedAtMicroseconds : nil
        )
    }

    /// Without a UTF-8 locale tmux prints a format's tabs as `_`, and a probe that read that
    /// as "no such session" would let a second agent start beside the first.
    @Test(
        "A held conversation refuses and names the tile and session holding it, in any locale",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the session probe asks it"),
        arguments: ["UTF-8", "C"]
    )
    func heldConversationNamesWhere(locale: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let identity = try await startHeldTile(in: fixture)
        let tile = UUID().uuidString
        let conversationID = try recordConversation(
            in: fixture,
            lastSeenIn: .init(hostSessionID: tile, tmux: try tmuxSession(identity, recordingSocket: false))
        )
        let localeKeys: (String) -> Bool = { $0 == "LANG" || $0.hasPrefix("LC_") }
        let localeEnvironment = locale == "C" ? ["LC_ALL": "C"] : ["LANG": "en_US.UTF-8"]
        let run = { (arguments: [String]) throws -> CLIBinary.Invocation in
            try fixture.run(arguments, extraEnvironment: localeEnvironment, without: localeKeys)
        }

        let resume = try run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 3)
        #expect(resume.stdout.contains("tmux session 'held-tile' (\(identity[1]))"))
        #expect(resume.stdout.contains("tile \(tile)"))
        #expect(resume.stdout.contains("runs claude without naming this conversation"))
        #expect(resume.stdout.contains("resumes once that process exits"))
        #expect(!resume.stdout.contains("stub argv"))

        let json = try run(["conversation", "resume", conversationID, "--here", "--json"])
        #expect(json.status == 3)
        let result = try JSONDecoder().decode(ConversationResumeResult.self, from: Data(json.stdout.utf8))
        #expect(!result.resumed)
        #expect(result.holders.first?.hostSessionID == tile)
        #expect(result.holders.first?.foundBy == .sessionPaneTree)
    }

    /// A `-L` label resolves under each client's own `TMUX_TMPDIR`, so a resume run with
    /// another one would ask a server that is not there and read the session as gone.
    @Test(
        "A session recorded with its socket path is found from a shell with another TMUX_TMPDIR",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the session probe asks it")
    )
    func heldConversationFoundByItsSocketPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let identity = try await startHeldTile(in: fixture)
        let conversationID = try recordConversation(
            in: fixture,
            lastSeenIn: .init(hostSessionID: nil, tmux: try tmuxSession(identity, recordingSocket: true))
        )
        let elsewhere = fixture.root.appendingPathComponent("other-tmpdir")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        let resume = try fixture.run(
            ["conversation", "resume", conversationID, "--here"], extraEnvironment: ["TMUX_TMPDIR": elsewhere.path])
        #expect(resume.status == 3)
        #expect(resume.stdout.contains("tmux session 'held-tile' (\(identity[1]))"))
        #expect(!resume.stdout.contains("stub argv"))
    }

    /// Starts the stub the way a person runs claude in a plain terminal: no tmux, nothing in
    /// its arguments, and its SessionStart hook run once for each of `conversations`.
    private func startBareAgent(in fixture: Fixture, hooking conversations: [String]) async throws -> Process {
        try FileManager.default.createDirectory(at: fixture.transcripts, withIntermediateDirectories: true)
        for id in conversations {
            FileManager.default.createFile(
                atPath: fixture.transcripts.appendingPathComponent("\(id).jsonl").path, contents: Data())
        }
        let agent = try fixture.start(
            [],
            executable: fixture.stub,
            extraEnvironment: [
                "STUB_STAY": "1",
                "STUB_HOOK_IDS": conversations.joined(separator: " "),
                "STUB_HOOK_CLI": fixture.binary.path,
                "STUB_TRANSCRIPTS": fixture.transcripts.path,
            ],
            output: fixture.root.appendingPathComponent("agent.log")
        )
        let last = try #require(conversations.last)
        try await waitUntil(launches: Double(1 + conversations.count)) {
            fixture.records.load(conversationID: last)?.lastSeenIn?.harness != nil
        }
        return agent
    }

    @Test("A claude outside tmux whose arguments name nothing holds the conversation its hook recorded")
    func recordedHarnessOutsideTmuxHolds() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        let agent = try await startBareAgent(in: fixture, hooking: [conversationID])
        defer { Self.kill([agent]) }
        let harness = try #require(fixture.records.load(conversationID: conversationID)?.lastSeenIn?.harness)
        #expect(harness.pid == agent.processIdentifier)

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here", "--json"])
        #expect(resume.status == 3)
        let result = try JSONDecoder().decode(ConversationResumeResult.self, from: Data(resume.stdout.utf8))
        #expect(result.holders.map(\.pid) == [agent.processIdentifier])
        #expect(result.holders.first?.foundBy == .recordedHarness)
    }

    /// `/clear` keeps the process and starts a new conversation, and the hook sees it start.
    @Test("A claude that moved on to another conversation holds the new one, and the old one resumes")
    func movedHarnessReleasesTheOldConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let before = UUID().uuidString.lowercased()
        let after = UUID().uuidString.lowercased()
        let agent = try await startBareAgent(in: fixture, hooking: [before, after])
        defer { Self.kill([agent]) }

        let held = try fixture.run(["conversation", "resume", after, "--here"])
        #expect(held.status == 3)
        #expect(held.stdout.contains("pid \(agent.processIdentifier)"))

        let resumed = try fixture.run(["conversation", "resume", before, "--here"])
        #expect(resumed.status == 0)
        #expect(resumed.stdout.contains("stub argv=--resume \(before)"))
    }

    @Test("A record from another host refuses with fork advice, and nothing starts")
    func otherHostRefuses() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture, host: "elsewhere.invalid")

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("recorded on elsewhere.invalid"))
        #expect(resume.stderr.contains("claude --resume \(conversationID) --fork-session"))
        #expect(!resume.stdout.contains("stub argv"))
    }

    @Test("--here hands the recorded config home to the harness, in the conversation's directory")
    func hereHandsTheRecordedConfigHome() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        let profile = fixture.root.appendingPathComponent("profile")
        let resolvedWork = try #require(
            realpath(fixture.work.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })
        let transcript =
            profile
            .appendingPathComponent("projects")
            .appendingPathComponent(ClaudeTranscriptLocator.encodeProjectDirectory(resolvedWork))
            .appendingPathComponent("\(conversationID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: transcript.path, contents: Data())
        try fixture.records.record(
            ConversationObservation(
                conversationID: conversationID,
                cwd: fixture.work.path,
                configHome: profile.path,
                observedBy: .hook,
                launch: .init(handle: "wm-launched", model: nil, effort: "high")
            )
        )

        let resume = try fixture.run(
            ["conversation", "resume", conversationID, "--here"],
            extraEnvironment: ["CLAUDE_CONFIG_DIR": "/nonexistent-caller-profile"]
        )
        #expect(resume.status == 0)
        #expect(resume.stdout.contains("stub argv=--resume \(conversationID) --effort high"))
        #expect(resume.stdout.contains("stub config=\(profile.path)"))
        #expect(resume.stdout.contains("stub pwd=\(resolvedWork)"))

        let record = try #require(fixture.records.load(conversationID: conversationID))
        #expect(record.observedBy == .resume)
        #expect(record.lastSeenIn?.outsideTmux == true)
    }

    @Test("A config home recorded as the default is not exported, so claude finds its own settings")
    func explicitDefaultConfigHomeIsNotExported() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        let defaultHome = fixture.home.appendingPathComponent(".claude")
        let transcript = defaultHome.appendingPathComponent("projects/p/\(conversationID).jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: transcript.path, contents: Data())
        try fixture.records.record(
            ConversationObservation(
                conversationID: conversationID,
                cwd: fixture.work.path,
                configHome: defaultHome.path,
                transcriptPath: transcript.path,
                observedBy: .hook
            )
        )

        let resume = try fixture.run(
            ["conversation", "resume", conversationID, "--here"],
            extraEnvironment: ["CLAUDE_CONFIG_DIR": "/nonexistent-caller-profile"]
        )
        #expect(resume.status == 0)
        #expect(resume.stdout.contains("stub config=unset"))
    }

    /// `ws launch` records the workspace directory's creation time. A directory at that path
    /// made later is a workspace archived and recreated under the same name, and the
    /// conversation is no part of the new one: resuming would run it against other files.
    @Test("A workspace directory made after the conversation was recorded refuses, and nothing starts")
    func recreatedWorkspaceRefuses() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)
        let created = try #require(
            try FileManager.default.attributesOfItem(atPath: fixture.work.path)[.creationDate] as? Date)
        try fixture.records.record(
            ConversationObservation(
                conversationID: conversationID,
                workspacePath: fixture.work.path,
                workspaceCreatedAt: created.addingTimeInterval(-60),
                observedBy: .wsLaunch
            )
        )

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("may belong to an earlier workspace at that path"))
        #expect(!resume.stdout.contains("stub argv"))
    }

    @Test("A conversation nothing recorded refuses")
    func unrecordedConversationRefuses() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        let resume = try fixture.run(["conversation", "resume", UUID().uuidString, "--here"])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("No record names conversation"))
    }
}
