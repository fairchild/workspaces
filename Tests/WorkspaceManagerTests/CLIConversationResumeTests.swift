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

    /// Stands in for claude: says what it was started with (also into `STUB_LOG`, for a run
    /// whose output lands in a pane), runs the SessionStart hook for each id in
    /// `STUB_HOOK_IDS` the way claude does (a child of this process), and for each id in
    /// `STUB_NESTED_HOOK_IDS` from beneath another program it started, as a tool claude runs
    /// can, then exits, or stays
    /// alive when `STUB_STAY` is set, as an agent holding its conversation does. It stays at
    /// most five minutes, and no longer than its fixture: a killed test run leaves nothing
    /// behind that outlives either. With `STUB_VIA` set to `node` or `env`, it first execs
    /// itself through a stand-in JavaScript runtime with an option before the script, the way
    /// an npm install's wrapper does, so nothing in the final arguments says claude.
    private static let stubClaude = #"""
        #!/bin/sh
        if [ -n "$STUB_VIA" ]; then
          via=$STUB_VIA
          unset STUB_VIA
          here=$(dirname "$0")
          if [ "$via" = env ]; then
            exec /usr/bin/env "$here/node" --no-warnings "$here/../lib/claude-code/cli.js" "$@"
          fi
          exec "$here/node" --no-warnings "$here/../lib/claude-code/cli.js" "$@"
        fi
        printf 'stub argv=%s\n' "$*"
        if [ -n "$STUB_LOG" ]; then
          printf 'argv=%s config=%s\n' "$*" "${CLAUDE_CONFIG_DIR-unset}" >> "$STUB_LOG"
        fi
        printf 'stub config=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
        printf 'stub pwd=%s\n' "$(pwd -P)"
        for id in $STUB_HOOK_IDS; do
          printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s/%s.jsonl"}' \
            "$id" "$PWD" "$STUB_TRANSCRIPTS" "$id" | "$STUB_HOOK_CLI" conversation observe
        done
        for id in $STUB_NESTED_HOOK_IDS; do
          printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s/%s.jsonl"}' \
            "$id" "$PWD" "$STUB_TRANSCRIPTS" "$id" | /usr/bin/time -p "$STUB_HOOK_CLI" conversation observe 2>/dev/null
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
        for stub in [fixture.stub, fixture.bin.appendingPathComponent("node")] {
            try Self.stubClaude.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
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
    /// login shell's can; the records directory is what they share. A runtime harness execs
    /// through a JavaScript runtime whose arguments do not say claude, so only the process
    /// the winning resume recorded as its own can show the loser the conversation is held.
    @Test(
        "Two concurrent resumes of one conversation start one agent",
        arguments: ["same-config", "split-config", "node-runtime", "env-node-runtime"]
    )
    func concurrentResumesStartOneAgent(setup: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)

        let outputs = (0..<2).map { fixture.root.appendingPathComponent("resume-\($0).log") }
        let resumes = try outputs.enumerated().map { index, output in
            var environment = ["STUB_STAY": "1", "CLAUDE_CONFIG_DIR": "/nonexistent-caller-profile"]
            switch setup {
            case "split-config":
                environment["XDG_CONFIG_HOME"] = fixture.root.appendingPathComponent("config-\(index)").path
            case "node-runtime": environment["STUB_VIA"] = "node"
            case "env-node-runtime": environment["STUB_VIA"] = "env"
            default: break
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
        #expect(started.contains("--resume \(conversationID)"))
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

    /// Starts the stub with `arguments` the way a person runs claude in a plain terminal, with
    /// no tmux, and its SessionStart hook run once for each of `conversations`, then from
    /// beneath another program for each of `nested`.
    private func startBareAgent(
        in fixture: Fixture,
        arguments: [String] = [],
        hooking conversations: [String],
        nested: [String] = []
    ) async throws -> Process {
        try FileManager.default.createDirectory(at: fixture.transcripts, withIntermediateDirectories: true)
        for id in conversations + nested {
            FileManager.default.createFile(
                atPath: fixture.transcripts.appendingPathComponent("\(id).jsonl").path, contents: Data())
        }
        let agent = try fixture.start(
            arguments,
            executable: fixture.stub,
            extraEnvironment: [
                "STUB_STAY": "1",
                "STUB_HOOK_IDS": conversations.joined(separator: " "),
                "STUB_NESTED_HOOK_IDS": nested.joined(separator: " "),
                "STUB_HOOK_CLI": fixture.binary.path,
                "STUB_TRANSCRIPTS": fixture.transcripts.path,
            ],
            output: fixture.root.appendingPathComponent("agent.log")
        )
        let last = try #require(conversations.last)
        try await waitUntil(launches: Double(1 + conversations.count + nested.count)) {
            fixture.records.load(conversationID: last)?.lastSeenIn?.harness != nil
                && nested.allSatisfy { fixture.records.load(conversationID: $0) != nil }
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

    /// A harness whose parent never collects it, as an orchestrator that starts the verb and
    /// never waits leaves it, keeps its pid and start time after it exits.
    @Test("A recorded claude that exited and was never reaped holds nothing")
    func unreapedHarnessHoldsNothing() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)
        let neverWaits = try fixture.start(
            [
                "-e", "my $child = fork; if (!$child) { exec @ARGV } sleep 300", fixture.binary.path, "conversation",
                "resume", conversationID, "--here",
            ],
            executable: URL(fileURLWithPath: "/usr/bin/perl"),
            output: fixture.root.appendingPathComponent("first.log"))
        defer { Self.kill([neverWaits]) }
        var harness: ProcessIdentity?
        try await waitUntil(launches: 2) {
            harness = fixture.records.load(conversationID: conversationID)?.lastSeenIn?.harness
            return try harness.map { try Self.isZombie($0.pid) } ?? false
        }
        let dead = try #require(harness)
        #expect(try Self.isZombie(dead.pid), "the first harness never exited")

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 0, "\(resume.stdout)")
        #expect(resume.stdout.contains("stub argv=--resume \(conversationID)"))
    }

    private static func isZombie(_ pid: Int32) throws -> Bool {
        let ps = Process()
        let out = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "stat=", "-p", "\(pid)"]
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        try ps.run()
        let stat = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return stat.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
    }

    /// `/clear` keeps the process and starts a new conversation, and the hook sees it start.
    /// Which conversation the process is in now is only as current as its last hook, so it
    /// holds every one it ran until it exits.
    @Test("A claude that moved on to another conversation holds both until it exits")
    func movedHarnessHoldsEveryConversationItRan() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let before = UUID().uuidString.lowercased()
        let after = UUID().uuidString.lowercased()
        let agent = try await startBareAgent(in: fixture, hooking: [before, after])
        defer { Self.kill([agent]) }

        for conversationID in [after, before] {
            let held = try fixture.run(["conversation", "resume", conversationID, "--here"])
            #expect(held.status == 3)
            #expect(held.stdout.contains("pid \(agent.processIdentifier)"))
            #expect(held.stdout.contains("may have moved to another one"))
            #expect(!held.stdout.contains("stub argv"))
        }
    }

    /// A tool an agent runs can start a claude of its own whose SessionStart fires beneath the
    /// agent, and a hook can be late or misplaced. Neither takes a conversation from the agent
    /// whose arguments name it.
    @Test("A claude whose arguments name the conversation keeps it whatever a later hook records")
    func argumentsHolderKeepsItsConversation() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let held = UUID().uuidString.lowercased()
        let beneath = UUID().uuidString.lowercased()
        let misplaced = UUID().uuidString.lowercased()
        let agent = try await startBareAgent(
            in: fixture, arguments: ["--resume", held], hooking: [held, misplaced], nested: [beneath])
        defer { Self.kill([agent]) }

        let fromBeneath = try #require(fixture.records.load(conversationID: beneath))
        #expect(fromBeneath.lastSeenIn?.harness == nil)
        #expect(fixture.records.load(conversationID: misplaced)?.lastSeenIn?.harness?.pid == agent.processIdentifier)

        let resume = try fixture.run(["conversation", "resume", held, "--here"])
        #expect(resume.status == 3)
        #expect(resume.stdout.contains("pid \(agent.processIdentifier)"))
        #expect(!resume.stdout.contains("stub argv"))
    }

    /// The claude the hook recorded has exited, and a claude that never ran a hook here, such
    /// as one started before the hook was installed, sits in the same session.
    @Test(
        "Once the recorded claude has exited, a claude in the session it ran in still holds the conversation",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the session probe asks it")
    )
    func endedHarnessFallsBackToTheSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let identity = try await startHeldTile(in: fixture)
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ended.arguments = ["0.2"]
        try ended.run()
        let endedIdentity = try #require(ProcessInspector.live.identity(ended.processIdentifier))
        ended.waitUntilExit()
        let conversationID = try recordConversation(
            in: fixture,
            lastSeenIn: .init(
                hostSessionID: nil, tmux: try tmuxSession(identity, recordingSocket: true), harness: endedIdentity,
                harnessObservedAt: Date()))

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here", "--json"])
        #expect(resume.status == 3)
        let result = try JSONDecoder().decode(ConversationResumeResult.self, from: Data(resume.stdout.utf8))
        #expect(result.holders.map(\.foundBy) == [.sessionPaneTree])
        #expect(!resume.stdout.contains("stub argv"))
    }

    private func waitForFile(_ url: URL, toContain text: String) async throws -> String {
        var contents = ""
        try await waitUntil(launches: 3) {
            contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return contents.contains(text)
        }
        return contents
    }

    @Test(
        "ws resume keeps the effort its launch asked for when the conversation's record has none",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; --into starts a session")
    )
    func wsResumeKeepsTheLaunchEffort() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        // The hook made this record, so it has no launch; the transcript names no effort.
        let conversationID = try recordConversation(in: fixture)
        let handle = "wm-parity-\(fixture.socketLabel)"
        try AgentLaunchRecordStore(directory: fixture.root.appendingPathComponent("config/workspaces-cli/launches"))
            .save(
                AgentLaunchRecord(
                    handle: handle, workspacePath: fixture.work.path, socketLabel: fixture.socketLabel,
                    launchedAt: Date(),
                    identity: .init(conversationID: conversationID, requestedModel: nil, requestedEffort: "high")))
        let log = fixture.root.appendingPathComponent("stub.log")

        let resume = try fixture.run(
            ["ws", "resume", handle, "--json"], extraEnvironment: ["STUB_STAY": "1", "STUB_LOG": log.path])
        #expect(resume.status == 0, "\(resume.stderr)")
        let result = try JSONDecoder().decode(WorkspaceResumeResult.self, from: Data(resume.stdout.utf8))
        #expect(result.command == "claude --resume \(conversationID) --effort high")
        let started = try await waitForFile(log, toContain: "argv=")
        #expect(started.contains("argv=--resume \(conversationID) --effort high"))
    }

    /// The shell is the kind a tile leaves behind with someone's own profile exported. What
    /// `--into` types is the `--here` resume, so the harness gets the environment `--here`
    /// would give it: the transcript's config home, here the default, which is never exported.
    @Test(
        "--into hands the harness the same environment --here does, whatever the shell exports",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; --into types into a session")
    )
    func intoMatchesHere() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)
        let log = fixture.root.appendingPathComponent("stub.log")
        _ = try fixture.tmux([
            "new-session", "-d", "-s", "target",
            "env CLAUDE_CONFIG_DIR=/wrong-profile STUB_STAY=1 STUB_LOG=\(log.path) /bin/sh",
        ])
        try await waitUntil(launches: 2) {
            TmuxSessionControl.isIdleShell(
                paneCommand: try fixture.tmux(["display-message", "-p", "-t", "=target:", "#{pane_current_command}"])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let resume = try fixture.run(["conversation", "resume", conversationID, "--into", "target"])
        #expect(resume.status == 0, "\(resume.stderr)")
        #expect(resume.stdout.contains("Resumed conversation \(conversationID) in target"))
        let started = try await waitForFile(log, toContain: "argv=")
        #expect(started.contains("argv=--resume \(conversationID) config=unset"))
    }

    /// A shell running a builtin that waits looks idle to tmux, so the resume is typed and
    /// waits in the terminal's input. When it finally runs, after the resume that typed it
    /// gave up and another agent took the conversation, it has to find that agent.
    @Test(
        "A resume typed into a shell that runs it late refuses once something else holds the conversation",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; --into types into a session")
    )
    func lateTypedResumeRefuses() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)
        let gate = fixture.root.appendingPathComponent("gate")
        try #require(mkfifo(gate.path, 0o600) == 0)
        _ = try fixture.tmux([
            "new-session", "-d", "-s", "busy",
            "env STUB_STAY=1 /bin/sh -c 'read go < \(gate.path); exec /bin/sh'",
        ])
        try await waitUntil(launches: 2) {
            TmuxSessionControl.isIdleShell(
                paneCommand: try fixture.tmux(["display-message", "-p", "-t", "=busy:", "#{pane_current_command}"])
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let typed = try fixture.run(["conversation", "resume", conversationID, "--into", "busy"])
        #expect(typed.status == 1)
        #expect(typed.stderr.contains("nothing took up conversation"))

        let agent = try fixture.start(
            ["conversation", "resume", conversationID, "--here"], extraEnvironment: ["STUB_STAY": "1"],
            output: fixture.root.appendingPathComponent("agent.log"))
        defer { Self.kill([agent]) }
        try await waitUntil(launches: 2) { try await !holders(of: conversationID, in: fixture).isEmpty }

        let writer = try #require(FileHandle(forWritingAtPath: gate.path))
        writer.write(Data("go\n".utf8))
        try writer.close()
        var pane = ""
        try await waitUntil(launches: 3) {
            pane = try fixture.tmux(["capture-pane", "-p", "-t", "=busy:"])
            return pane.contains("already held")
        }
        #expect(pane.contains("already held"))
        let agents = try #require(await ProcessTable.read()).rows.filter {
            $0.arguments.contains(fixture.stub.path) && $0.arguments.contains(conversationID)
        }
        #expect(agents.map(\.pid) == [agent.processIdentifier])
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

    /// The resume runs on a thread that blocks most signals, and here under a shell that
    /// ignores TERM and HUP, as `nohup` or a test runner can; a harness that kept either would
    /// never hear its tile close or its terminal resize.
    @Test("--here starts the harness with no signal blocked or ignored, so a TERM ends it")
    func hereStartsTheHarnessWithDefaultSignals() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)
        let agent = try fixture.start(
            ["-c", "trap '' TERM HUP; exec \"$0\" conversation resume \(conversationID) --here", fixture.binary.path],
            executable: URL(fileURLWithPath: "/bin/sh"), extraEnvironment: ["STUB_STAY": "1"],
            output: fixture.root.appendingPathComponent("agent.log"))
        defer { Self.kill([agent]) }
        try await waitUntil(launches: 2) { try await !holders(of: conversationID, in: fixture).isEmpty }

        let mask = Process()
        let output = Pipe()
        mask.executableURL = URL(fileURLWithPath: "/bin/ps")
        mask.arguments = ["-o", "sigmask=", "-p", "\(agent.processIdentifier)"]
        mask.standardOutput = output
        try mask.run()
        let blocked = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        mask.waitUntilExit()
        #expect(blocked.trimmingCharacters(in: .whitespacesAndNewlines) == "0")

        Darwin.kill(agent.processIdentifier, SIGTERM)
        try await waitUntil(launches: 1) { !agent.isRunning }
        try #require(!agent.isRunning)
        #expect(agent.terminationReason == .uncaughtSignal)
        #expect(agent.terminationStatus == SIGTERM)
    }

    /// Once the harness runs, its sighting is all another resume can find it by, so a resume
    /// that cannot write one starts nothing.
    @Test("A resume that cannot record itself as the holder refuses, and nothing starts")
    func unrecordedResumeRefuses() throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)
        let locks = fixture.root.appendingPathComponent("conversations/.locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let descriptor = open(locks.appendingPathComponent("\(conversationID).write").path, O_CREAT | O_RDWR, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX) == 0)

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("Could not record that this terminal now holds conversation"))
        #expect(resume.stderr.contains("its record stayed locked for two seconds"))
        #expect(!resume.stdout.contains("stub argv"))
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
