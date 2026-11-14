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
            recordedSession: RecordedTmuxSession? = nil,
            inspector: ProcessInspector = .onlySelf,
            readProcessTable: (@Sendable () async -> ProcessTable?)? = nil
        ) -> ConversationResumer {
            let execs = execs
            return ConversationResumer(
                records: records,
                launches: launches,
                control: TmuxSessionControl(socketLabel: "resumer-tests-unused", run: { _, _, _ in nil }),
                environment: ["PATH": "/usr/bin:/bin"],
                homeDirectory: root.appendingPathComponent("home"),
                readProcessTable: readProcessTable ?? { processTable },
                recordedSession: { _ in recordedSession },
                inspector: inspector,
                describeTmux: { _ in nil },
                exec: { invocation, handOff in
                    try await handOff()
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

    @Test("A hook's note published while the decision after the sighting probes refuses, and nothing starts")
    func noteDuringTheFinalProbeRefuses() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        let records = world.records
        let id = world.conversationID
        let note = world.root.appendingPathComponent("conversations/\(id).json.unresolved-1-aaaaaaaa")

        let resumer = world.resumer(processTable: nil) {
            if records.load(conversationID: id)?.harnessProcesses.entries.isEmpty == false,
                !FileManager.default.fileExists(atPath: note.path)
            {
                FileManager.default.createFile(atPath: note.path, contents: Data("{}".utf8))
            }
            return Self.quietTable
        }
        await #expect(throws: ConversationResumer.Refusal.unresolvedOwner(conversationID: id, path: note.path)) {
            try await resumer.resume(conversationID: id, target: .here)
        }
        #expect(world.execs.invocations.isEmpty)
    }

    /// A hook that names its claude while the decision after the sighting probes: the final
    /// read sees a process the probe did not, and asks the kernel about it before the exec.
    @Test(
        "A process a hook names while the decision after the sighting probes holds it, or leaves it unknown",
        arguments: [true, false])
    func namedDuringTheFinalProbe(kernelAnswers: Bool) async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        let records = world.records
        let id = world.conversationID
        let late = ProcessIdentity(pid: 4242, startedAtMicroseconds: 7)
        let inspector = ProcessInspector(
            read: { pid in
                if pid == getpid() { return .found(ProcessIdentity(pid: pid, startedAtMicroseconds: 1)) }
                if pid == late.pid { return kernelAnswers ? .found(late) : .unreadable }
                return .absent
            },
            parent: { _ in nil }, arguments: { _ in nil })

        let resumer = world.resumer(processTable: nil, inspector: inspector) {
            let entries = records.load(conversationID: id)?.harnessProcesses.entries ?? []
            if !entries.isEmpty, !entries.contains(where: { $0.process == late }) {
                _ = try? records.record(
                    ConversationObservation(
                        conversationID: id, cwd: "/", observedBy: .hook, harnessProcess: .named(late)),
                    ended: { _ in false })
            }
            return Self.quietTable
        }
        if kernelAnswers {
            let outcome = try await resumer.resume(conversationID: id, target: .here)
            guard case .held(let holders, _) = outcome else {
                Issue.record("resumed past a process named while it decided: \(outcome)")
                return
            }
            #expect(holders.map(\.pid) == [late.pid])
        } else {
            let silent = ConversationResumer.Refusal.probeFailed("Could not ask the kernel about process 4242")
            await #expect(throws: silent) {
                try await resumer.resume(conversationID: id, target: .here)
            }
        }
        #expect(world.execs.invocations.isEmpty)
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
            recordedSession: { _ in nil },
            inspector: .onlySelf,
            describeTmux: { _ in nil },
            exec: { _, handOff in
                try await handOff()
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

        let resumer = world.resumer(
            processTable: table,
            recordedSession: .live(sessionID: "$7", name: "tile-session", panePIDs: [100])
        )
        let subject = try #require(try resumer.subject(conversationID: world.conversationID))
        let status = await resumer.status(of: subject, exitWindow: { _ in 0 })

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
            recordedSession: { _ in nil },
            inspector: .none,
            describeTmux: { _ in nil }
        )

        await #expect(throws: ConversationResumer.Refusal.cannotStart("'claude' is not on PATH.")) {
            try await resumer.resume(conversationID: world.conversationID, target: .here)
        }
        #expect(world.records.load(conversationID: world.conversationID)?.observedBy == .hook)
    }

    /// A sighting stamped later than now, as a skewed clock writes, in a place this resume
    /// contradicts outranks the place it writes. The process it records stays named.
    @Test("A sighting elsewhere stamped later than the resume does not hide the process the resume records")
    func outrankedSightingKeepsTheProcess() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        try world.records.record(
            ConversationObservation(
                conversationID: world.conversationID,
                observedAt: Date().addingTimeInterval(3_600),
                observedBy: .hook,
                lastSeenIn: .init(hostSessionID: nil, tmux: .init(serverPID: 1, sessionID: "$1"))))

        _ = try await world.resumer(processTable: Self.quietTable, recordedSession: .gone).resume(
            conversationID: world.conversationID, target: .here)
        #expect(world.execs.invocations.count == 1)
        let record = try #require(world.records.load(conversationID: world.conversationID))
        #expect(record.lastSeenIn?.tmux?.serverPID == 1)
        #expect(record.harnessProcesses.entries.map(\.process.pid) == [getpid()])
    }

    /// The kernel's answer about this process changes between reading its identity and the
    /// write, as a pid given away in between would: the write drops it as exited, and the
    /// read-back is what notices.
    @Test("A resume whose record, read back, does not name its process refuses, and nothing starts")
    func readBackWithoutTheProcessRefuses() async throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        let reads = Claimable()
        let shifting = ProcessInspector(
            identity: { pid in
                guard pid == getpid() else { return nil }
                let first = reads.value == nil
                reads.set(true)
                return ProcessIdentity(pid: pid, startedAtMicroseconds: first ? 1 : 2)
            },
            parent: { _ in nil }, arguments: { _ in nil })

        await #expect(
            throws: ConversationResumer.Refusal.unrecorded(
                conversationID: world.conversationID, reason: "its record, read back, does not name this process")
        ) {
            try await world.resumer(processTable: Self.quietTable, recordedSession: .gone, inspector: shifting)
                .resume(conversationID: world.conversationID, target: .here)
        }
        #expect(world.execs.invocations.isEmpty)
    }

    @Test("A records directory that cannot be listed refuses, naming the directory, and nothing starts")
    func unlistableRecordsRefuse() async throws {
        let world = try World()
        defer {
            chmod(world.records.directory.path, 0o700)
            world.teardown()
        }
        try world.recordConversation()
        #expect(chmod(world.records.directory.path, 0o300) == 0)

        await #expect(
            throws: ConversationResumer.Refusal.unlistableRecords(
                conversationID: world.conversationID, path: world.records.directory.path)
        ) {
            try await world.resumer(processTable: Self.quietTable).resume(
                conversationID: world.conversationID, target: .here)
        }
        #expect(world.execs.invocations.isEmpty)
        #expect(
            ConversationResumer.Refusal.unlistableRecords(conversationID: "x", path: "/r").localizedDescription
                .contains("Give your user read permission on that directory"))
    }

    @Test("A record that cannot be read refuses before a launch record naming the conversation is used")
    func damagedRecordIsNotReplacedByTheLaunch() throws {
        let world = try World()
        defer { world.teardown() }
        try world.recordConversation()
        try world.launches.save(
            AgentLaunchRecord(
                handle: "wm-resumer-damaged", workspacePath: world.cwd, socketLabel: "resumer-tests-unused",
                launchedAt: Date(),
                identity: .init(conversationID: world.conversationID, requestedModel: nil, requestedEffort: nil)))
        let url = try #require(world.records.fileURL(conversationID: world.conversationID))
        try Data("{ not json".utf8).write(to: url)

        #expect(
            throws: ConversationResumer.Refusal.damagedRecord(conversationID: world.conversationID, path: url.path)
        ) {
            try world.resumer(processTable: Self.quietTable).subject(conversationID: world.conversationID)
        }
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
