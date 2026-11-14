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
    /// `STUB_HOOK_IDS` the way claude does (a child of this process, running `STUB_HOOK_COMMAND`
    /// in a shell when it is set, as claude runs a settings hook), and for each id in
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
          payload=$(printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s/%s.jsonl"}' \
            "$id" "$PWD" "$STUB_TRANSCRIPTS" "$id")
          if [ -n "$STUB_HOOK_COMMAND" ]; then
            printf '%s' "$payload" | /bin/sh -c "$STUB_HOOK_COMMAND"
          else
            printf '%s' "$payload" | "$STUB_HOOK_CLI" conversation observe
          fi
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

    /// A conversation recorded on this host, with a transcript where the hook said it is, and
    /// the hook's `harness` kept whether or not it still runs.
    private func recordConversation(
        in fixture: Fixture,
        host: String = ConversationHost.current,
        lastSeenIn: ConversationRecord.LastSeenIn? = nil,
        harness: ProcessIdentity? = nil
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
                lastSeenIn: lastSeenIn,
                harnessProcess: harness.map { .named($0) }
            ),
            ended: { _ in false }
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
    /// no tmux, and its SessionStart hook run once for each of `conversations`, through
    /// `hookCommand` when one is given, then from beneath another program for each of `nested`.
    private func startBareAgent(
        in fixture: Fixture,
        arguments: [String] = [],
        hooking conversations: [String],
        hookCommand: String? = nil,
        nested: [String] = [],
        environment: [String: String] = [:]
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
                "STUB_HOOK_COMMAND": hookCommand ?? "",
                "STUB_TRANSCRIPTS": fixture.transcripts.path,
            ].merging(environment) { _, new in new },
            output: fixture.root.appendingPathComponent("agent.log")
        )
        let last = try #require(conversations.last)
        try await waitUntil(launches: Double(1 + conversations.count + nested.count)) {
            fixture.records.load(conversationID: last).map {
                !$0.harnessProcesses.entries.isEmpty || !$0.harnessProcesses.unattributed.isEmpty
            } == true
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
        let harness = try #require(
            fixture.records.load(conversationID: conversationID)?.harnessProcesses.entries.first?.process)
        #expect(harness.pid == agent.processIdentifier)

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here", "--json"])
        #expect(resume.status == 3)
        let result = try JSONDecoder().decode(ConversationResumeResult.self, from: Data(resume.stdout.utf8))
        #expect(result.holders.map(\.pid) == [agent.processIdentifier])
        #expect(result.holders.first?.foundBy == .recordedHarness)
    }

    /// The forwarder as the app extracts it, naming this fixture's CLI, and a link to it under
    /// another name, as a person might add to their own hooks.
    private func installForwarder(in fixture: Fixture) throws -> (installed: URL, link: URL) {
        let template = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/WorkspaceManager/Resources/HookForwarders/conversation-observer.sh"),
            encoding: .utf8
        )
        let hooks = fixture.root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let installed = hooks.appendingPathComponent(ConversationHookObserver.forwarderName)
        try template.replacingOccurrences(of: "@WORKSPACES_CLI@", with: fixture.binary.path)
            .write(to: installed, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        let link = hooks.appendingPathComponent("observer.sh")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: installed)
        return (installed, link)
    }

    /// Outside tmux, a hook that names its claude is all that guards a bare one, so the hook
    /// names the nearest claude above it however its command reaches the forwarder.
    @Test(
        "A hook names its claude through the installed forwarder, a link to it, a script of its own or a deeper chain",
        arguments: ["installed", "link", "script", "deeper"]
    )
    func hookNamesItsClaudeHoweverItIsReached(path: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let forwarder = try installForwarder(in: fixture)
        let script = fixture.bin.appendingPathComponent("my-session-start")
        try "#!/bin/sh\n\(forwarder.link.path)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let conversationID = UUID().uuidString.lowercased()
        let hookCommand =
            switch path {
            case "installed": forwarder.installed.path
            case "link": forwarder.link.path
            case "script": script.path
            default: "/bin/sh -c '/bin/bash -c \"\(forwarder.installed.path); true\"; true'"
            }
        let agent = try await startBareAgent(in: fixture, hooking: [conversationID], hookCommand: hookCommand)
        defer { Self.kill([agent]) }
        let named = try #require(fixture.records.load(conversationID: conversationID)?.harnessProcesses)
        #expect(named.entries.map(\.process.pid) == [agent.processIdentifier])

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(!resume.stdout.contains("stub argv"))
        #expect(resume.status == 3)
        #expect(resume.stdout.contains("pid \(agent.processIdentifier)"))
    }

    /// A harness this build does not recognize runs the conversation, and its hook finds no
    /// claude above it. A claude named later, and gone, says nothing about it.
    @Test(
        "A conversation a hook saw start under no claude refuses until what it ran under exits, whatever is named later"
    )
    func unattributedHarnessRefusesUntilItExits() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: fixture.transcripts, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fixture.transcripts.appendingPathComponent("\(conversationID).jsonl").path, contents: Data())
        let unrecognized = fixture.bin.appendingPathComponent("harness-a")
        try FileManager.default.copyItem(at: fixture.stub, to: unrecognized)
        try detach(
            [unrecognized.path], in: fixture,
            extraEnvironment: [
                "STUB_STAY": "1", "STUB_HOOK_IDS": conversationID, "STUB_HOOK_CLI": fixture.binary.path,
                "STUB_TRANSCRIPTS": fixture.transcripts.path,
            ])
        var chain: [ProcessIdentity] = []
        try await waitUntil(launches: 2) {
            chain =
                fixture.records.load(conversationID: conversationID)?.harnessProcesses.unattributed.first?.chain ?? []
            return !chain.isEmpty
        }
        let a = try #require(chain.first)
        defer { if ProcessInspector.live.liveness(a) == .running { Darwin.kill(a.pid, SIGKILL) } }
        #expect(chain.count == 1)
        #expect(ProcessInspector.live.arguments(a.pid)?.contains(unrecognized.path) == true)
        #expect(try fixture.run(["conversation", "resume", conversationID, "--here"]).status == 1)

        let b = try await startBareAgent(in: fixture, hooking: [conversationID])
        try await waitUntil(launches: 1) {
            fixture.records.load(conversationID: conversationID)?.harnessProcesses.entries.map(\.process.pid)
                == [b.processIdentifier]
        }
        #expect(try fixture.run(["conversation", "resume", conversationID, "--here"]).status == 3)
        Self.kill([b])
        try await waitUntil(launches: 1) { !b.isRunning }
        let afterB = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(afterB.status == 1, "\(afterB.stdout)")
        #expect(afterB.stderr.contains("with no claude above it, and process \(a.pid) it ran under still runs"))
        #expect(!afterB.stdout.contains("stub argv"), "a second agent started beside the unrecognized one")

        Darwin.kill(a.pid, SIGKILL)
        try await waitUntil(launches: 1) { ProcessInspector.live.liveness(a) == .ended }
        let afterA = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(afterA.status == 0, "\(afterA.stderr)")
        #expect(afterA.stdout.contains("stub argv=--resume \(conversationID)"))
    }

    /// A claude starts a runtime the adapter does not recognize, and that runtime runs the
    /// conversation. The hook names the claude above it, and the processes it passed on the
    /// way still hold the conversation once that claude has gone. The second case gives the
    /// runtime claude's own options and script, run as a shell script, so the argument rule
    /// cannot see it either way.
    @Test(
        "A runtime between the hook and the claude it names holds the conversation after that claude exits",
        arguments: ["agent-rt", "node-inspect"])
    func passedRuntimeHoldsAfterTheNamedClaude(shape: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(at: fixture.transcripts, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fixture.transcripts.appendingPathComponent("\(conversationID).jsonl").path, contents: Data())
        let runtime = fixture.bin.appendingPathComponent(shape == "agent-rt" ? "agent-rt" : "node")
        if shape == "agent-rt" { try FileManager.default.copyItem(at: fixture.stub, to: runtime) }
        let runtimeArguments =
            shape == "agent-rt" ? "" : "--inspect-port 0 \(fixture.root.path)/lib/claude-code/cli.js"
        let outerDirectory = fixture.root.appendingPathComponent("outer")
        try FileManager.default.createDirectory(at: outerDirectory, withIntermediateDirectories: true)
        let outerScript = outerDirectory.appendingPathComponent("claude")
        try "#!/bin/sh\n\"$STUB_RUNTIME\" $STUB_RUNTIME_ARGS &\nwhile [ -e \"$0\" ]; do sleep 1; done\n".write(
            to: outerScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outerScript.path)
        let outer = try fixture.start(
            [], executable: outerScript,
            extraEnvironment: [
                "STUB_RUNTIME": runtime.path, "STUB_RUNTIME_ARGS": runtimeArguments, "STUB_STAY": "1",
                "STUB_HOOK_IDS": conversationID,
                "STUB_HOOK_CLI": fixture.binary.path, "STUB_TRANSCRIPTS": fixture.transcripts.path,
            ],
            output: fixture.root.appendingPathComponent("outer.log"))
        defer { Self.kill([outer]) }
        var processes = ConversationRecord.HarnessProcesses()
        try await waitUntil(launches: 2) {
            processes = fixture.records.load(conversationID: conversationID)?.harnessProcesses ?? .init()
            return !processes.entries.isEmpty
        }
        #expect(processes.entries.map(\.process.pid) == [outer.processIdentifier])
        let passed = try #require(processes.unattributed.first?.chain.first)
        defer { if ProcessInspector.live.liveness(passed) == .running { Darwin.kill(passed.pid, SIGKILL) } }
        #expect(ProcessInspector.live.arguments(passed.pid)?.contains(runtime.path) == true)
        #expect(try fixture.run(["conversation", "resume", conversationID, "--here"]).status == 3)

        Self.kill([outer])
        try await waitUntil(launches: 1) { !outer.isRunning }
        let afterOuter = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(afterOuter.status == 1, "\(afterOuter.stdout)")
        #expect(afterOuter.stderr.contains("process \(passed.pid) it ran under still runs"), "\(afterOuter.stderr)")
        #expect(!afterOuter.stdout.contains("stub argv"), "a second agent started beside the runtime")
    }

    /// A harness whose parent never collects it, as an orchestrator that starts the verb and
    /// never waits leaves it, keeps its pid and start time after it exits. A `--here` whose
    /// exec failed has recorded itself and exited the same way.
    @Test(
        "A recorded claude that exited and was never reaped holds nothing, nor does a resume whose exec failed",
        arguments: [false, true])
    func unreapedHarnessHoldsNothing(execFails: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)
        if execFails { try "#!/no/such/interpreter\n".write(to: fixture.stub, atomically: true, encoding: .utf8) }
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
            harness = fixture.records.load(conversationID: conversationID)?.harnessProcesses.entries.first?.process
            return try harness.map { try Self.isZombie($0.pid) } ?? false
        }
        let dead = try #require(harness)
        #expect(try Self.isZombie(dead.pid), "the first harness never exited")
        if execFails {
            let first = try String(contentsOf: fixture.root.appendingPathComponent("first.log"), encoding: .utf8)
            #expect(first.contains("Could not start"), "\(first)")
            try Self.stubClaude.write(to: fixture.stub, atomically: true, encoding: .utf8)
        }

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

    /// Runs `command` with launchd as its parent, so no process of the test run is above it:
    /// what a hook beneath it records cannot depend on what runs the tests. Returns once the
    /// detaching process has exited; `command` runs on.
    private func detach(_ command: [String], in fixture: Fixture, extraEnvironment: [String: String] = [:]) throws {
        let detacher = try fixture.start(
            [
                "-e",
                "if (my $c = fork) { waitpid($c, 0); exit } exit if fork; "
                    + "select(undef, undef, undef, 0.01) while getppid() != 1; exec @ARGV",
            ] + command,
            executable: URL(fileURLWithPath: "/usr/bin/perl"), extraEnvironment: extraEnvironment,
            output: fixture.root.appendingPathComponent("detached-\(UUID().uuidString.prefix(8)).log"))
        detacher.waitUntilExit()
    }

    /// A SessionStart hook for `conversationID` from `tile`, run by nothing that is claude, as
    /// a hook delayed past a later one lands. The shell it runs under exits once it has.
    private func deliverHook(_ conversationID: String, from tile: String, in fixture: Fixture) async throws {
        let payload = fixture.root.appendingPathComponent("hook-\(UUID().uuidString).json")
        let done = payload.appendingPathExtension("done")
        try Data(#"{"session_id":"\#(conversationID)","cwd":"\#(fixture.work.path)"}"#.utf8).write(to: payload)
        try detach(
            [
                "/bin/sh", "-c", "\"$0\" conversation observe < \"$1\"; : > \"$2\"", fixture.binary.path, payload.path,
                done.path,
            ],
            in: fixture, extraEnvironment: ["WORKSPACES_HOST_SESSION_ID": tile])
        try await waitUntil(launches: 1) { FileManager.default.fileExists(atPath: done.path) }
        #expect(FileManager.default.fileExists(atPath: done.path), "the hook never finished")
    }

    /// The previous build's write: its own sightings, a `lastSeenIn` with nothing this build
    /// adds, and every top-level key it does not know kept.
    private func rewriteAsThePreviousBuild(_ conversationID: String, at tile: String, in fixture: Fixture) throws {
        let url = try #require(fixture.records.fileURL(conversationID: conversationID))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let now = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        object["sightings"] = [["hostSessionID": tile, "observedAt": now]]
        object["sightingsAfter"] = ["observedAt": now, "key": "|"]
        object["lastSeenIn"] = ["hostSessionID": tile]
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// A hook from another tile that lands late, or the previous build writing where the
    /// conversation is now, moves its place; neither takes the running agent away.
    @Test("A claude stays the holder after a delayed hook from another tile and a write by the previous build")
    func laterSightingsElsewhereKeepTheHolder() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        let tileB = UUID().uuidString
        let agent = try await startBareAgent(
            in: fixture, hooking: [conversationID], environment: ["WORKSPACES_HOST_SESSION_ID": tileB])
        defer { Self.kill([agent]) }

        func expectHeld(_ moment: String) throws {
            let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
            #expect(resume.status == 3, "\(moment): \(resume.stdout)\(resume.stderr)")
            #expect(resume.stdout.contains("pid \(agent.processIdentifier)"), "\(moment)")
            #expect(!resume.stdout.contains("stub argv"), "\(moment): a second agent started")
        }
        try expectHeld("after its own hook")
        try await deliverHook(conversationID, from: UUID().uuidString, in: fixture)
        #expect(fixture.records.load(conversationID: conversationID)?.lastSeenIn?.hostSessionID != tileB)
        try expectHeld("after a delayed hook from another tile")
        try rewriteAsThePreviousBuild(conversationID, at: UUID().uuidString, in: fixture)
        try expectHeld("after the previous build wrote another tile")
    }

    /// A writer that moves a damaged record aside starts a fresh one that cannot say who held
    /// the conversation: the previous build's writers, or this build's followed by a fresh
    /// owner that has since exited. The moved-aside copy keeps it unknown until a person
    /// deletes it.
    @Test(
        "A record moved aside as damaged refuses, after any writer, until its copy is deleted",
        arguments: ["previous-build", "replacement-exits"]
    )
    func movedAsideRecordRefuses(schedule: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        let agent = try await startBareAgent(in: fixture, hooking: [conversationID])
        defer { Self.kill([agent]) }
        let url = try #require(fixture.records.fileURL(conversationID: conversationID))
        try Data("[]".utf8).write(to: url)
        let aside = URL(fileURLWithPath: url.path + ".corrupt-1794625090-162d2aeb")
        if schedule == "previous-build" {
            try FileManager.default.moveItem(at: url, to: aside)
            try fixture.records.record(
                ConversationObservation(
                    conversationID: conversationID, cwd: fixture.work.path,
                    transcriptPath: fixture.transcripts.appendingPathComponent("\(conversationID).jsonl").path,
                    observedAt: Date(), observedBy: .hook))
        } else {
            try fixture.records.record(
                ConversationObservation(
                    conversationID: conversationID, cwd: fixture.work.path, observedAt: Date(), observedBy: .app))
            let replacement = try await startBareAgent(in: fixture, hooking: [conversationID])
            try await waitUntil(launches: 1) {
                fixture.records.load(conversationID: conversationID)?.harnessProcesses.entries.map(\.process.pid)
                    == [replacement.processIdentifier]
            }
            Self.kill([replacement])
            try await waitUntil(launches: 1) { !replacement.isRunning }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        let movedAside = try #require(names.first { $0.hasPrefix(url.lastPathComponent + ".corrupt-") })

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("moved aside to \(url.deletingLastPathComponent().path)/\(movedAside)"))
        #expect(resume.stderr.contains("delete that file to resume"))
        #expect(!resume.stdout.contains("stub argv"), "a second agent started beside the first")

        Self.kill([agent])
        try await waitUntil(launches: 1) { !agent.isRunning }
        try FileManager.default.removeItem(
            atPath: url.deletingLastPathComponent().appendingPathComponent(movedAside).path)
        let afterDelete = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(afterDelete.status == 0, "\(afterDelete.stderr)")
    }

    /// Ownership that does not decode is damage, not the absence of an owner.
    @Test("A record whose owner's entry is malformed refuses while that owner runs")
    func malformedOwnerRefuses() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        let agent = try await startBareAgent(in: fixture, hooking: [conversationID])
        defer { Self.kill([agent]) }
        let url = try #require(fixture.records.fileURL(conversationID: conversationID))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var processes = try #require(object["harnessProcesses"] as? [String: Any])
        var entries = try #require(processes["entries"] as? [[String: Any]])
        entries[0]["observedAt"] = "invalid"
        processes["entries"] = entries
        object["harnessProcesses"] = processes
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 1)
        #expect(resume.stderr.contains("\(url.path) cannot be read"), "\(resume.stderr)")
        #expect(!resume.stdout.contains("stub argv"), "a second agent started")
    }

    /// A record that will not parse may still name the agent running the conversation, so it
    /// is never read as absent: not through a launch record, and not by moving it aside.
    @Test("A damaged record refuses, naming its file, even with a launch record to fall back on")
    func damagedRecordRefuses() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = UUID().uuidString.lowercased()
        let agent = try await startBareAgent(in: fixture, hooking: [conversationID])
        defer { Self.kill([agent]) }
        let handle = "wm-damaged-\(fixture.socketLabel)"
        try AgentLaunchRecordStore(directory: fixture.root.appendingPathComponent("config/workspaces-cli/launches"))
            .save(
                AgentLaunchRecord(
                    handle: handle, workspacePath: fixture.work.path,
                    socketLabel: fixture.socketLabel, launchedAt: Date(),
                    identity: .init(conversationID: conversationID, requestedModel: nil, requestedEffort: nil)))
        #expect(try fixture.run(["conversation", "resume", conversationID, "--here"]).status == 3)
        let url = try #require(fixture.records.fileURL(conversationID: conversationID))
        let damaged = Data("{ not json".utf8)
        try damaged.write(to: url)

        for arguments in [["conversation", "resume", conversationID, "--here"], ["ws", "resume", handle]] {
            let resume = try fixture.run(arguments)
            #expect(resume.status == 1, "\(arguments)")
            #expect(resume.stderr.contains("\(url.path) cannot be read"), "\(resume.stderr)")
            #expect(!resume.stdout.contains("stub argv"), "a second agent started")
        }
        #expect(try Data(contentsOf: url) == damaged)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.contains("corrupt") })
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
    /// whose arguments name it; the one beneath is held by the agent too, until it exits.
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
        #expect(fromBeneath.harnessProcesses.entries.map(\.process.pid) == [agent.processIdentifier])
        #expect(
            fixture.records.load(conversationID: misplaced)?.harnessProcesses.entries.map(\.process.pid)
                == [agent.processIdentifier])

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
            lastSeenIn: .init(hostSessionID: nil, tmux: try tmuxSession(identity, recordingSocket: true)),
            harness: endedIdentity)

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
