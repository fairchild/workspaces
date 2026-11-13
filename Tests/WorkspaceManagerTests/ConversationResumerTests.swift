//
//  ConversationResumerTests.swift
//  WorkspaceManagerTests
//
//  The guarded resume verb's decisions with every probe injected: what it does when it cannot
//  see, and what counts as holding a conversation. The real binary, a stub harness and an
//  isolated tmux server prove the same guards end to end in CLIConversationResumeTests.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Conversation resumer")
struct ConversationResumerTests {
    private final class Execs: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [HarnessInvocation] = []

        var invocations: [HarnessInvocation] { lock.withLock { calls } }
        func append(_ invocation: HarnessInvocation) { lock.withLock { calls.append(invocation) } }
    }

    private struct World {
        let root: URL
        let records: ConversationRecordStore
        let launches: AgentLaunchRecordStore
        let conversationID = UUID().uuidString.lowercased()
        let execs = Execs()

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("resumer-\(UUID().uuidString)")
            records = ConversationRecordStore(directory: root.appendingPathComponent("conversations"))
            launches = AgentLaunchRecordStore(directory: root.appendingPathComponent("launches"))
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        }

        var cwd: String { root.appendingPathComponent("work").path }

        /// A recorded conversation with a transcript where the hook said it is.
        func recordConversation(lastSeenIn: ConversationRecord.LastSeenIn? = nil) throws {
            let transcript = root.appendingPathComponent("home/.claude/projects/p/\(conversationID).jsonl")
            try FileManager.default.createDirectory(
                at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: transcript.path, contents: Data())
            try records.record(
                ConversationObservation(
                    conversationID: conversationID,
                    cwd: cwd,
                    transcriptPath: transcript.path,
                    observedBy: .hook,
                    lastSeenIn: lastSeenIn
                )
            )
        }

        func resumer(
            processTable: ProcessTable?,
            recordedSession: RecordedTmuxSession? = .notRecorded
        ) -> ConversationResumer {
            let execs = execs
            return ConversationResumer(
                records: records,
                launches: launches,
                control: TmuxSessionControl(socketLabel: "resumer-tests-unused", run: { _, _, _ in nil }),
                environment: ["PATH": "/usr/bin:/bin"],
                homeDirectory: root.appendingPathComponent("home"),
                readProcessTable: { processTable },
                recordedSession: { _ in recordedSession },
                describeTmux: { _ in nil },
                exec: { execs.append($0) }
            )
        }

        func teardown() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static let quietTable = ProcessTable(rows: [
        .init(pid: 1, parentPID: 0, arguments: ["/sbin/launchd"])
    ])

    @Test("An unreadable process table refuses, and nothing starts")
    func unreadableProcessTableRefuses() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()

        await #expect(throws: ConversationResumer.Refusal.probeFailed("Could not read the process table")) {
            try await world.resumer(processTable: nil).resume(conversationID: world.conversationID, target: .here)
        }
        #expect(world.execs.invocations.isEmpty)
    }

    @Test("A tmux server that does not answer for the recorded session refuses, and nothing starts")
    func silentServerRefuses() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()

        let resumer = world.resumer(processTable: Self.quietTable, recordedSession: nil)
        await #expect(throws: ConversationResumer.Refusal.self) {
            try await resumer.resume(conversationID: world.conversationID, target: .here)
        }
        #expect(world.execs.invocations.isEmpty)
    }

    @Test("A free conversation with a transcript is handed to the harness in its own directory")
    func freeConversationExecs() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()

        let outcome = try await world.resumer(processTable: Self.quietTable)
            .resume(conversationID: world.conversationID, target: .here)

        #expect(outcome == .resumed(command: "claude --resume \(world.conversationID)"))
        let invocation = try #require(world.execs.invocations.first)
        #expect(invocation.arguments == ["claude", "--resume", world.conversationID])
        #expect(invocation.directory == world.cwd)
        #expect(invocation.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(world.records.load(conversationID: world.conversationID)?.observedBy == .resume)
    }

    @Test("Status is open, naming the tile, for a bare claude in the session the conversation was last seen in")
    func statusFindsAHarnessInTheRecordedSession() async throws {
        let world = try World()
        defer { world.teardown() }
        let tile = UUID().uuidString
        try world.recordConversation(
            lastSeenIn: .init(hostSessionID: tile, tmux: .init(serverPID: 4242, sessionID: "$7", name: "tile-session"))
        )
        let table = ProcessTable(rows: [
            .init(pid: 100, parentPID: 1, arguments: ["-zsh"]),
            .init(pid: 101, parentPID: 100, arguments: ["node", "/opt/bin/claude"]),
        ])

        let status = await world.resumer(
            processTable: table,
            recordedSession: .live(sessionID: "$7", name: "tile-session", panePIDs: [100])
        ).conversationStatus(conversationID: world.conversationID)

        #expect(
            status
                == .open(holders: [
                    ConversationHolder(
                        pid: 101, tmuxSessionID: "$7", tmuxSessionName: "tile-session", hostSessionID: tile)
                ])
        )
    }

    @Test("A claude elsewhere that names no conversation holds nothing")
    func unrelatedHarnessHoldsNothing() {
        let record = ConversationRecord(
            schema: 1, harness: "claude", conversationID: UUID().uuidString.lowercased(), host: "h", cwd: "/",
            configHome: nil, transcriptPath: nil, workspacePath: nil, workspaceCreatedAt: nil, socketLabel: nil,
            createdAt: Date(), observedAt: Date(), observedBy: .hook, launch: nil, lastSeenIn: nil, endedByUserAt: nil)
        let table = ProcessTable(rows: [
            .init(pid: 100, parentPID: 1, arguments: ["/usr/local/bin/claude"]),
            .init(pid: 101, parentPID: 1, arguments: ["/usr/local/bin/claude", "--resume", record.conversationID]),
        ])
        let holders = ClaudeHarnessAdapter().holders(of: record, processTable: table, recordedSession: .gone)
        #expect(holders.map(\.pid) == [101])
    }

    @Test("A recorded session answered by a different server, or recreated under the same id, is gone")
    func recordedSessionMatchesTheWholeIdentity() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let tmux = ConversationRecord.TmuxSession(serverPID: 4242, sessionID: "$3", createdAt: created)
        #expect(
            ConversationResumer.recordedSession(tmux, listing: "4242\t1700000000\t555\twm-a\n")
                == .live(sessionID: "$3", name: "wm-a", panePIDs: [555]))
        #expect(ConversationResumer.recordedSession(tmux, listing: "9999\t1700000000\t555\twm-a\n") == .gone)
        #expect(ConversationResumer.recordedSession(tmux, listing: "4242\t1700000999\t555\twm-a\n") == .gone)
    }

    @Test("The process table reads ps output and walks a pane's descendants")
    func processTableWalksDescendants() throws {
        let table = try #require(
            ProcessTable(
                listing: """
                      1     0 /sbin/launchd
                    100     1 -zsh
                    101   100 /bin/sh /opt/bin/claude --resume x
                    102   101 sleep 1
                    200     1 other
                    """
            )
        )
        #expect(table.rows.count == 5)
        #expect(Set(table.descendants(of: [100]).map(\.pid)) == [100, 101, 102])
    }
}
