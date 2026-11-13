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
                inspector: .onlySelf,
                describeTmux: { _ in nil },
                exec: { invocation, handOff in
                    try handOff()
                    execs.append(invocation)
                }
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
        try world.recordConversation(
            lastSeenIn: .init(hostSessionID: nil, tmux: .init(serverPID: 4242, sessionID: "$7")))

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

    @Test("The conversation is still claimed at the moment the harness takes over the terminal")
    func lockHeldThroughTheHandOff() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        let lockPath = world.root.appendingPathComponent("conversations/.locks/\(world.conversationID).claim").path
        let claimable = Claimable()

        let resumer = ConversationResumer(
            records: world.records,
            launches: world.launches,
            control: TmuxSessionControl(socketLabel: "resumer-tests-unused", run: { _, _, _ in nil }),
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: world.root.appendingPathComponent("home"),
            readProcessTable: { Self.quietTable },
            recordedSession: { _ in .notRecorded },
            inspector: .onlySelf,
            describeTmux: { _ in nil },
            exec: { _, handOff in
                try handOff()
                let descriptor = open(lockPath, O_RDWR | O_CLOEXEC)
                defer { close(descriptor) }
                claimable.set(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            }
        )
        _ = try await resumer.resume(conversationID: world.conversationID, target: .here)

        #expect(claimable.value == false)
    }

    private final class Claimable: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? { lock.withLock { stored } }
        func set(_ value: Bool) { lock.withLock { stored = value } }
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
                        pid: 101, foundBy: .sessionPaneTree, tmuxSessionID: "$7", tmuxSessionName: "tile-session",
                        hostSessionID: tile)
                ])
        )
    }

    /// The grace a holder gets to finish exiting follows what is known about it: one in a
    /// session that is still there is not exiting, wherever the resume was headed.
    @Test("A holder in the live session the conversation was last seen in refuses at once, whatever the target")
    func liveRecordedHolderRefusesAtOnce() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation(
            lastSeenIn: .init(hostSessionID: nil, tmux: .init(serverPID: 4242, sessionID: "$7", name: "tile-session"))
        )
        let table = ProcessTable(rows: [
            .init(pid: 100, parentPID: 1, arguments: ["-zsh"]),
            .init(pid: 101, parentPID: 100, arguments: ["/opt/bin/claude"]),
        ])
        let resumer = world.resumer(
            processTable: table, recordedSession: .live(sessionID: "$7", name: "tile-session", panePIDs: [100]))

        let started = Date()
        let outcome = try await resumer.resume(conversationID: world.conversationID, target: .into(handle: "wm-absent"))

        #expect(Date().timeIntervalSince(started) < 5)
        guard case .held(let holders, let targetLive) = outcome else {
            Issue.record("expected held, got \(outcome)")
            return
        }
        #expect(holders.map(\.pid) == [101])
        #expect(targetLive == false)
    }

    @Test("The record read under the lock keeps the launch the caller filled in")
    func reloadKeepsTheCallersLaunch() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        var subject = try #require(world.records.load(conversationID: world.conversationID))
        subject.launch = .init(handle: "wm-launched", model: nil, effort: "high")

        _ = try await world.resumer(processTable: Self.quietTable).resume(subject, target: .here)

        let invocation = try #require(world.execs.invocations.first)
        #expect(invocation.arguments == ["claude", "--resume", world.conversationID, "--effort", "high"])
    }

    @Test("A record that changed before the lock was taken is checked again, and refuses on what it now says")
    func reloadedRecordIsCheckedAgain() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        let subject = try #require(world.records.load(conversationID: world.conversationID))
        let created = try #require(
            try FileManager.default.attributesOfItem(atPath: world.cwd)[.creationDate] as? Date)
        try world.records.record(
            ConversationObservation(
                conversationID: world.conversationID,
                workspacePath: world.cwd,
                workspaceCreatedAt: created.addingTimeInterval(-60),
                observedBy: .wsLaunch
            )
        )

        await #expect(
            throws: ConversationResumer.Refusal.earlierWorkspace(conversationID: world.conversationID, path: world.cwd)
        ) {
            try await world.resumer(processTable: Self.quietTable).resume(subject, target: .here)
        }
        #expect(world.execs.invocations.isEmpty)
    }

    @Test("A harness that cannot be started refuses, and the record does not say it was resumed")
    func unstartableHarnessRefuses() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        let resumer = ConversationResumer(
            records: world.records,
            launches: world.launches,
            control: TmuxSessionControl(socketLabel: "resumer-tests-unused", run: { _, _, _ in nil }),
            environment: ["PATH": world.root.appendingPathComponent("empty").path],
            homeDirectory: world.root.appendingPathComponent("home"),
            readProcessTable: { Self.quietTable },
            recordedSession: { _ in .notRecorded },
            inspector: .none,
            describeTmux: { _ in nil }
        )

        await #expect(throws: ConversationResumer.Refusal.cannotStart("'claude' is not on PATH.")) {
            try await resumer.resume(conversationID: world.conversationID, target: .here)
        }
        #expect(world.records.load(conversationID: world.conversationID)?.observedBy == .hook)
    }

    /// A sighting stamped later than now, as a skewed clock writes, in a place this resume
    /// contradicts outranks the one it writes, and the record would go on naming no harness.
    @Test("A resume whose sighting the record does not show as the holder refuses, and nothing starts")
    func outrankedSightingRefuses() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        try world.records.record(
            ConversationObservation(
                conversationID: world.conversationID,
                observedAt: Date().addingTimeInterval(3_600),
                observedBy: .hook,
                lastSeenIn: .init(hostSessionID: nil, tmux: .init(serverPID: 1, sessionID: "$1"))))

        do {
            _ = try await world.resumer(processTable: Self.quietTable).resume(
                conversationID: world.conversationID, target: .here)
            Issue.record("the resume went ahead")
        } catch ConversationResumer.Refusal.unrecorded(_, let reason) {
            #expect(reason.contains("names another process"))
        }
        #expect(world.execs.invocations.isEmpty)
    }

    @Test("A sighting counts as in the handle by the handle's name, or with no name, by its server and session")
    func sightingIsInTheHandle() {
        let named = ConversationRecord.TmuxSession(serverPID: 7, sessionID: "$1", name: "wm-a")
        let unnamed = ConversationRecord.TmuxSession(serverPID: 7, sessionID: "$1")
        let handleSession = ConversationRecord.TmuxSession(serverPID: 7, sessionID: "$1", name: "wm-a")
        let otherSession = ConversationRecord.TmuxSession(serverPID: 7, sessionID: "$2", name: "wm-a")
        let otherServer = ConversationRecord.TmuxSession(serverPID: 8, sessionID: "$1", name: "wm-a")
        #expect(ConversationResumer.sighting(named, isIn: "wm-a", handleSession: nil))
        #expect(!ConversationResumer.sighting(named, isIn: "wm-b", handleSession: handleSession))
        #expect(ConversationResumer.sighting(unnamed, isIn: "wm-a", handleSession: handleSession))
        #expect(!ConversationResumer.sighting(unnamed, isIn: "wm-a", handleSession: nil))
        #expect(!ConversationResumer.sighting(unnamed, isIn: "wm-a", handleSession: otherSession))
        #expect(!ConversationResumer.sighting(unnamed, isIn: "wm-a", handleSession: otherServer))
    }
}

extension ProcessInspector {
    /// Sees no process at all.
    static let none = ProcessInspector(identity: { _ in nil }, parent: { _ in nil }, arguments: { _ in nil })
    /// Sees only the test process itself, which a `--here` resume records as the harness.
    static let onlySelf = ProcessInspector(
        identity: { $0 == getpid() ? ProcessIdentity(pid: $0, startedAtMicroseconds: 1) : nil },
        parent: { _ in nil }, arguments: { _ in nil })
}
