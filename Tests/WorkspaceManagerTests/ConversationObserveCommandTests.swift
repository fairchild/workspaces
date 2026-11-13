//
//  ConversationObserveCommandTests.swift
//  WorkspaceManagerTests
//
//  Drives `workspaces conversation observe` and the hook script that runs it through the
//  real binary, because what matters is the hook boundary: Claude's payload on stdin, the
//  tile's environment, and an exit status of 0 whatever happens. Every run points the
//  records, the CLI config, and Claude's config at a scratch directory.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Conversation observe command", .serialized)
struct ConversationObserveCommandTests {
    private struct Fixture {
        let binary: URL
        let root: URL

        init() throws {
            binary = try #require(CLIBinary.url, CLIBinary.missingBinaryMessage)
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "conversation-observe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var recordsDirectory: URL { root.appendingPathComponent("conversations") }
        var records: ConversationRecordStore { ConversationRecordStore(directory: recordsDirectory) }

        /// Outside WorkSpaces: no tile key, and the config homes still point here so a bug
        /// that writes anyway lands in scratch.
        var outsideEnvironment: [String: String] {
            [
                "XDG_CONFIG_HOME": root.appendingPathComponent("xdg").path,
                "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
            ]
        }

        func tileEnvironment(hostSessionID: UUID) -> [String: String] {
            outsideEnvironment.merging([
                "WORKSPACES_CONVERSATIONS_DIR": recordsDirectory.path,
                "WORKSPACES_HOST_SESSION_ID": hostSessionID.uuidString,
            ]) { _, new in new }
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func payload(sessionID: String, source: String = "startup") -> Data {
        Data(
            """
            {"session_id":"\(sessionID)","transcript_path":"/tmp/claude/projects/-tmp-repo/\(sessionID).jsonl",\
            "cwd":"/tmp/repo","hook_event_name":"SessionStart","source":"\(source)"}
            """.utf8
        )
    }

    /// Runs `executable` with `arguments`, removing every WorkSpaces and tmux key the test
    /// runner inherited before applying `environment`. With `closeInput` false, stdin stays
    /// open for the whole run: a process that read it would never finish.
    private static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        input: Data,
        closeInput: Bool = true
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("WORKSPACES_") && $0.key != "TMUX" && $0.key != "TMUX_PANE"
        }
        merged.merge(environment) { _, new in new }
        process.environment = merged
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // Written before the launch, while this process still holds the read end, so a
        // child that exits without reading cannot turn the write into a SIGPIPE here.
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try process.run()
        if closeInput { try stdin.fileHandleForWriting.close() }
        defer { try? stdin.fileHandleForWriting.close() }

        let budget = await LaunchBudget.deadline(launches: 2, floor: 5, ceiling: 60)
        guard exited.wait(timeout: .now() + budget) == .success else {
            process.terminate()
            Issue.record("\(executable.lastPathComponent) did not exit within \(budget)s")
            return -1
        }
        return process.terminationStatus
    }

    @Test("The observer exits 0 without reading its input when no WorkSpaces environment is present")
    func exitsAtOnceOutsideWorkSpaces() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let status = try await Self.run(
            fixture.binary,
            ["conversation", "observe"],
            environment: fixture.outsideEnvironment,
            input: Self.payload(sessionID: UUID().uuidString.lowercased()),
            closeInput: false
        )

        #expect(status == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("xdg").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.recordsDirectory.path))
    }

    @Test("The observer exits 0 and drops the write when it cannot take the record's lock")
    func exitsWhenTheLockIsHeld() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID().uuidString.lowercased()
        let locks = fixture.recordsDirectory.appendingPathComponent(".locks")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let holder = open(locks.appendingPathComponent("\(id).write").path, O_CREAT | O_RDWR, 0o600)
        #expect(holder >= 0)
        defer { close(holder) }
        #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)

        let status = try await Self.run(
            fixture.binary,
            ["conversation", "observe"],
            environment: fixture.tileEnvironment(hostSessionID: UUID()),
            input: Self.payload(sessionID: id)
        )

        #expect(status == 0)
        #expect(fixture.records.load(conversationID: id) == nil)
    }

    @Test("A hand-started Claude in a tile gets a record from its first hook event, with the app not running")
    func handStartedClaudeGetsARecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID().uuidString.lowercased()
        let tile = UUID()

        let status = try await Self.run(
            fixture.binary,
            ["conversation", "observe"],
            environment: fixture.tileEnvironment(hostSessionID: tile),
            input: Self.payload(sessionID: id)
        )

        #expect(status == 0)
        let record = try #require(fixture.records.load(conversationID: id))
        #expect(record.harness == "claude")
        #expect(record.observedBy == .hook)
        #expect(record.cwd == "/tmp/repo")
        #expect(record.transcriptPath == "/tmp/claude/projects/-tmp-repo/\(id).jsonl")
        #expect(record.configHome == fixture.root.appendingPathComponent("claude").path)
        #expect(record.host == ConversationHost.current)
        #expect(record.lastSeenIn?.hostSessionID == tile.uuidString)
    }

    @Test("A record the hook wrote while the app was not running is indexed at the next launch")
    func hookRecordIsIndexedAtLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID().uuidString.lowercased()
        let tile = UUID()
        _ = try await Self.run(
            fixture.binary,
            ["conversation", "observe"],
            environment: fixture.tileEnvironment(hostSessionID: tile),
            input: Self.payload(sessionID: id)
        )

        let localState = try LocalStateStore(databaseURL: fixture.root.appendingPathComponent("state.sqlite"))
        try await ConversationIndexer(
            records: fixture.records,
            localState: localState,
            launchRecords: AgentLaunchRecordStore(directory: fixture.root.appendingPathComponent("launches"))
        ).launch()

        #expect(try await localState.fetchCurrentConversation(hostSessionID: tile)?.conversationID == id)
    }

    @Test("/resume inside a tile makes the tile's current conversation the new id")
    func resumeMovesTheTilesCurrentConversation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let tile = UUID()
        let started = UUID().uuidString.lowercased()
        let resumed = UUID().uuidString.lowercased()

        for (id, source) in [(started, "startup"), (resumed, "resume")] {
            #expect(
                try await Self.run(
                    fixture.binary,
                    ["conversation", "observe"],
                    environment: fixture.tileEnvironment(hostSessionID: tile),
                    input: Self.payload(sessionID: id, source: source)
                ) == 0
            )
        }
        let localState = try LocalStateStore(databaseURL: fixture.root.appendingPathComponent("state.sqlite"))
        try await ConversationIndexer(records: fixture.records, localState: localState).rebuild()

        #expect(try await localState.fetchCurrentConversation(hostSessionID: tile)?.conversationID == resumed)
        #expect(fixture.records.load(conversationID: started)?.lastSeenIn?.hostSessionID == tile.uuidString)
    }

    @Test("A payload that names no conversation writes nothing and still exits 0")
    func malformedPayloadExitsZero() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        for input in [Data("not json".utf8), Data(#"{"session_id":"not-a-uuid"}"#.utf8), Data()] {
            #expect(
                try await Self.run(
                    fixture.binary,
                    ["conversation", "observe"],
                    environment: fixture.tileEnvironment(hostSessionID: UUID()),
                    input: input
                ) == 0
            )
        }
        #expect(fixture.records.all().isEmpty)
    }

    /// The deadline outlives the client it guards by however long the shell takes to stop
    /// it, and a reaped pid can be reused, so the kill it ends with checks the target is still
    /// the hook's own child.
    @Test("The hook's deadline kills its own child and nothing else")
    func deadlineKillsOnlyItsChild() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WorkspaceManager/Resources/HookForwarders/conversation-observer.sh")
        let stranger = Process()
        stranger.executableURL = URL(fileURLWithPath: "/bin/sleep")
        stranger.arguments = ["30"]
        try stranger.run()
        defer { stranger.terminate() }

        let probe = Process()
        let output = Pipe()
        probe.executableURL = URL(fileURLWithPath: "/bin/bash")
        probe.arguments = [
            "-c",
            #"source "$1"; kill_child "$2"; sleep 30 & own=$!; kill_child "$own"; wait "$own"; echo "own=$?""#,
            "probe", script.path, String(stranger.processIdentifier),
        ]
        probe.standardOutput = output
        try probe.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        probe.waitUntilExit()

        #expect(stranger.isRunning)
        #expect(text.contains("own=137"))
    }

    /// Where Codex's probes put a TERM: a second one while cleanup asks `ps` about the client,
    /// or one while the shell is stopped after starting the client and before recording it.
    enum LookupInterruption: String, CaseIterable, Sendable {
        case duringCleanup = "during-cleanup"
        case beforeTheClientIsRecorded = "before-the-client-is-recorded"
    }

    /// The stand-in `tmux` writes its pid and waits, as a client of a stopped server does,
    /// and the stand-in `ps` marks that it was asked and pauses before answering truly, so a
    /// signal can land inside cleanup.
    @Test(
        "A signal at any point of the hook's lookup leaves no client and no lookup file",
        arguments: LookupInterruption.allCases)
    func interruptedLookupCleansUp(_ interruption: LookupInterruption) throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WorkspaceManager/Resources/HookForwarders/conversation-observer.sh")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hook-interrupt-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ name: String, _ body: String, in directory: URL) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }
        func marker(_ name: String) -> URL { root.appendingPathComponent(name) }
        func waitFor(_ name: String) throws {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: marker(name).path) {
                try #require(Date() < deadline, "\(name) never appeared")
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        _ = try install("tmux", #"echo $$ > "$EDGE_ROOT/client"; exec /bin/sleep 30"#, in: bin)
        _ = try install("ps", #"echo ready > "$EDGE_ROOT/in-ps"; /bin/sleep 0.3; exec /bin/ps "$@""#, in: bin)
        let wrapper = try install(
            "wrapper.sh",
            #"""
            source "$1"
            if [[ "$2" == before-the-client-is-recorded ]]; then
                set -T
                trap 'if [[ "$BASH_COMMAND" == "lookup_client="* && "$BASH_SUBSHELL" == 0 && ! -e "$EDGE_ROOT/spawned" ]]; then echo ready > "$EDGE_ROOT/spawned"; builtin kill -STOP "$$"; fi' DEBUG
            fi
            main
            """#,
            in: root)

        let hook = Process()
        hook.executableURL = URL(fileURLWithPath: "/bin/bash")
        hook.arguments = [wrapper.path, source.path, interruption.rawValue]
        hook.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin", "TMPDIR": temporary.path, "EDGE_ROOT": root.path,
            "TMUX": "\(root.path)/absent.sock,123,0", "HOME": root.path,
        ]
        hook.standardInput = FileHandle.nullDevice
        hook.standardOutput = FileHandle.nullDevice
        hook.standardError = FileHandle.nullDevice
        try hook.run()
        var client: pid_t = 0
        defer {
            if hook.isRunning {
                kill(hook.processIdentifier, SIGCONT)
                kill(hook.processIdentifier, SIGKILL)
            }
            if client > 0 { kill(client, SIGKILL) }
        }

        switch interruption {
        case .duringCleanup:
            try waitFor("client")
            kill(hook.processIdentifier, SIGTERM)
            try waitFor("in-ps")
            kill(hook.processIdentifier, SIGTERM)
        case .beforeTheClientIsRecorded:
            try waitFor("spawned")
            kill(hook.processIdentifier, SIGTERM)
            kill(hook.processIdentifier, SIGCONT)
            try waitFor("client")
        }
        let deadline = Date().addingTimeInterval(5)
        while hook.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        try #require(!hook.isRunning, "the hook outlived its cleanup")
        client = try #require(
            pid_t(
                String(decoding: try Data(contentsOf: marker("client")), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
        Thread.sleep(forTimeInterval: 0.05)

        #expect(hook.terminationReason == .exit && hook.terminationStatus == 0)
        #expect(kill(client, 0) != 0, "the lookup's tmux client outlived the hook")
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == [])
    }

    @Test("The installed hook script starts the CLI only inside WorkSpaces, and exits 0 either way")
    func hookScriptGatesOnTheTileEnvironment() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
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
        let outside = UUID().uuidString.lowercased()
        let inside = UUID().uuidString.lowercased()

        #expect(
            try await Self.run(
                script, [], environment: fixture.outsideEnvironment,
                input: Self.payload(sessionID: outside), closeInput: false
            ) == 0
        )
        #expect(
            try await Self.run(
                script, [], environment: fixture.tileEnvironment(hostSessionID: UUID()),
                input: Self.payload(sessionID: inside)
            ) == 0
        )

        #expect(fixture.records.load(conversationID: outside) == nil)
        #expect(fixture.records.load(conversationID: inside)?.observedBy == .hook)

        let missingCLI = fixture.root.appendingPathComponent("missing-cli.sh")
        try template.replacingOccurrences(of: "@WORKSPACES_CLI@", with: "/nonexistent/workspaces")
            .write(to: missingCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: missingCLI.path)
        #expect(
            try await Self.run(
                missingCLI, [], environment: fixture.tileEnvironment(hostSessionID: UUID()),
                input: Self.payload(sessionID: UUID().uuidString)
            ) == 0
        )
    }
}
