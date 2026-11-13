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
