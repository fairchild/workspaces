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

    /// Stands in for claude: says what it was started with, then exits, or stays alive under
    /// its own name when `STUB_STAY` is set, as an agent holding its conversation does.
    private static let stubClaude = #"""
        #!/bin/sh
        printf 'stub argv=%s\n' "$*"
        printf 'stub config=%s\n' "${CLAUDE_CONFIG_DIR-unset}"
        printf 'stub pwd=%s\n' "$(pwd -P)"
        if [ -n "$STUB_STAY" ]; then
          while :; do sleep 1; done
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

        func start(_ arguments: [String], extraEnvironment: [String: String] = [:], output: URL) throws -> Process {
            let process = Process()
            process.executableURL = binary
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

        /// Runs to completion with exactly this fixture's environment. `CLIBinary.run` merges
        /// the caller's own back in, which would hand `--here` the test runner's `$TMUX`.
        func run(_ arguments: [String], extraEnvironment: [String: String] = [:]) throws -> CLIBinary.Invocation {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = binary
            process.arguments = arguments
            process.currentDirectoryURL = root
            process.environment = environment.merging(extraEnvironment) { _, new in new }
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

    private func holders(of conversationID: String) async throws -> [ConversationHolder] {
        let table = try #require(await ProcessTable.read())
        let record = ConversationRecord(
            schema: 1, harness: "claude", conversationID: conversationID, host: "", cwd: "/", configHome: nil,
            transcriptPath: nil, workspacePath: nil, workspaceCreatedAt: nil, socketLabel: nil, createdAt: Date(),
            observedAt: Date(), observedBy: .hook, launch: nil, lastSeenIn: nil, endedByUserAt: nil)
        return ClaudeHarnessAdapter().holders(of: record, processTable: table, recordedSession: .notRecorded)
    }

    @Test("Two concurrent resumes of one conversation start one agent")
    func concurrentResumesStartOneAgent() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }
        let conversationID = try recordConversation(in: fixture)

        let outputs = (0..<2).map { fixture.root.appendingPathComponent("resume-\($0).log") }
        let resumes = try outputs.map {
            try fixture.start(
                ["conversation", "resume", conversationID, "--here"],
                extraEnvironment: ["STUB_STAY": "1", "CLAUDE_CONFIG_DIR": "/nonexistent-caller-profile"],
                output: $0
            )
        }
        defer { resumes.filter(\.isRunning).forEach { $0.terminate() } }

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
        #expect(try await holders(of: conversationID).map(\.pid) == [agent.processIdentifier])
    }

    @Test(
        "A held conversation refuses and names the tile and session holding it",
        .enabled(if: tmuxIsInstalled, "tmux is not installed; the session probe asks it")
    )
    func heldConversationNamesWhere() async throws {
        let fixture = try makeFixture()
        defer { fixture.teardown() }

        // Started bare, the way a person types it before switching with /resume: nothing in
        // its arguments names the conversation, so only the session it sits in can say.
        _ = try fixture.tmux(["new-session", "-d", "-s", "held-tile", "STUB_STAY=1 \(fixture.stub.path)"])
        let deadline = Date().addingTimeInterval(await LaunchBudget.deadline(launches: 2, floor: 10, ceiling: 60))
        while try await ProcessTable.read()?.rows.contains(where: { $0.arguments.contains(fixture.stub.path) }) != true,
            Date() < deadline
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let identity = try fixture.tmux([
            "display-message", "-p", "-t", "=held-tile:", "#{pid}\t#{session_id}\t#{session_created}",
        ]).trimmingCharacters(in: .newlines).split(separator: "\t").map(String.init)
        try #require(identity.count == 3)
        let tile = UUID().uuidString
        let conversationID = try recordConversation(
            in: fixture,
            lastSeenIn: .init(
                hostSessionID: tile,
                tmux: .init(
                    serverPID: try #require(Int(identity[0])),
                    sessionID: identity[1],
                    createdAt: Date(timeIntervalSince1970: try #require(TimeInterval(identity[2]))),
                    name: "held-tile"
                )
            )
        )

        let resume = try fixture.run(["conversation", "resume", conversationID, "--here"])
        #expect(resume.status == 3)
        #expect(resume.stdout.contains("tmux session 'held-tile' (\(identity[1]))"))
        #expect(resume.stdout.contains("tile \(tile)"))
        #expect(resume.stdout.contains("runs claude without naming this conversation"))
        #expect(resume.stdout.contains("resumes once that process exits"))
        #expect(!resume.stdout.contains("stub argv"))

        let json = try fixture.run(["conversation", "resume", conversationID, "--here", "--json"])
        #expect(json.status == 3)
        let result = try JSONDecoder().decode(ConversationResumeResult.self, from: Data(json.stdout.utf8))
        #expect(!result.resumed)
        #expect(result.holders.first?.hostSessionID == tile)
        #expect(result.holders.first?.namesConversation == false)
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
