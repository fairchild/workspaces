//
//  ConversationIndexTests.swift
//  WorkspaceManagerTests
//
//  The conversation index is a lookup over the record files and nothing else, so these pin
//  that every way of building it lands on the same rows, that a tile's current conversation
//  follows the newest sighting, and that the one-time migration carries old ids over once.
//

import Foundation
import GRDB
import Testing

@testable import WorkspaceManagerCore

@Suite("Conversation index")
struct ConversationIndexTests {
    private struct Fixture {
        let root: URL
        let records: ConversationRecordStore
        let launchRecords: AgentLaunchRecordStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "conversation-index-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            records = ConversationRecordStore(directory: root.appendingPathComponent("conversations"))
            launchRecords = AgentLaunchRecordStore(directory: root.appendingPathComponent("launches"))
        }

        func localState(_ name: String = "state", runStartedAt: Date = Date()) throws -> LocalStateStore {
            try LocalStateStore(databaseURL: root.appendingPathComponent("\(name).sqlite"), runStartedAt: runStartedAt)
        }

        func indexer(_ localState: LocalStateStore) -> ConversationIndexer {
            ConversationIndexer(records: records, localState: localState, launchRecords: launchRecords)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func sighting(
        _ id: String,
        tile: UUID,
        at seconds: TimeInterval,
        by observer: ConversationObserver = .hook
    ) -> ConversationObservation {
        ConversationObservation(
            conversationID: id,
            host: "test-host",
            cwd: "/tmp/repo",
            observedAt: Date(timeIntervalSince1970: seconds),
            observedBy: observer,
            lastSeenIn: .init(
                hostSessionID: tile.uuidString,
                tmux: .init(serverPID: 4242, sessionID: "$1")
            )
        )
    }

    @Test("The index rebuilt from files matches the index built incrementally")
    func rebuildMatchesIncremental() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let incremental = try fixture.localState("incremental")
        let rebuilt = try fixture.localState("rebuilt")
        let tileA = UUID()
        let tileB = UUID()
        let first = UUID().uuidString.lowercased()
        let second = UUID().uuidString.lowercased()
        let third = UUID().uuidString.lowercased()

        let steps: [() throws -> Void] = [
            { try fixture.records.record(self.sighting(first, tile: tileA, at: 1_800_000_000)) },
            { try fixture.records.record(self.sighting(second, tile: tileB, at: 1_800_000_010)) },
            { try fixture.records.record(self.sighting(first, tile: tileB, at: 1_800_000_020, by: .app)) },
            { try fixture.records.record(self.sighting(third, tile: tileA, at: 1_800_000_030)) },
            {
                try FileManager.default.removeItem(at: try #require(fixture.records.fileURL(conversationID: second)))
            },
        ]
        for step in steps {
            try step()
            try await fixture.indexer(incremental).sync()
        }
        try await fixture.indexer(rebuilt).rebuild()

        let incrementalRows = try await incremental.fetchConversationIndex()
        let rebuiltRows = try await rebuilt.fetchConversationIndex()
        #expect(incrementalRows.count == 2)
        #expect(incrementalRows == rebuiltRows)
        #expect(try await incremental.fetchCurrentConversation(hostSessionID: tileA)?.conversationID == third)
        #expect(try await incremental.fetchCurrentConversation(hostSessionID: tileB)?.conversationID == first)
    }

    @Test("A sync picks up a rewrite whose modification time matches the indexed one")
    func syncDoesNotTrustModificationTimes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let localState = try fixture.localState()
        let id = UUID().uuidString.lowercased()
        var before = sighting(id, tile: UUID(), at: 1_800_000_000)
        before.cwd = "/before"
        try fixture.records.record(before)
        try await fixture.indexer(localState).sync()
        let url = try #require(fixture.records.fileURL(conversationID: id))
        let modifiedAt = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)

        var after = sighting(id, tile: UUID(), at: 1_800_000_010)
        after.cwd = "/after"
        try fixture.records.record(after)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        try await fixture.indexer(localState).sync()

        #expect(try await localState.fetchConversationIndex().map(\.cwd) == ["/after"])
    }

    @Test("An unreadable record is skipped by the index")
    func unreadableRecordIsNotIndexed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let localState = try fixture.localState()
        let id = UUID().uuidString.lowercased()
        try fixture.records.record(sighting(id, tile: UUID(), at: 1_800_000_000))
        try Data("garbage".utf8).write(
            to: fixture.records.directory.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        )

        try await fixture.indexer(localState).rebuild()

        #expect(try await localState.fetchConversationIndex().map(\.conversationID) == [id])
    }

    @Test("The migration leaves ownership it cannot read, an empty chain, as it is")
    func migrationKeepsAnEmptyChain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID().uuidString.lowercased()
        try fixture.records.record(
            ConversationObservation(
                conversationID: id, cwd: "/tmp/repo", observedAt: Date(timeIntervalSince1970: 1_800_000_000),
                observedBy: .hook))
        let url = try #require(fixture.records.fileURL(conversationID: id))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let damaged: [String: Any] = [
            "unattributed": [["chain": [String](), "observedAt": "2027-01-15T08:00:00.000Z"]]
        ]
        object["harnessProcesses"] = damaged
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try fixture.launchRecords.save(
            AgentLaunchRecord(
                handle: "wm-repo-1", workspacePath: "/tmp/repo", socketLabel: "workspaces",
                launchedAt: Date(timeIntervalSince1970: 1_800_000_100),
                identity: AgentLaunchIdentity(conversationID: id, requestedModel: nil, requestedEffort: nil)))

        #expect(try await fixture.indexer(try fixture.localState()).migrateOnce() == .init(written: 1))

        #expect(fixture.records.read(conversationID: id) == .damaged(url))
        let kept = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((kept["harnessProcesses"] as AnyObject?)?.isEqual(damaged) == true)
    }

    @Test("The one-time migration writes records from Launch Records and tiles' ids, once")
    func migrationRunsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launched = UUID().uuidString.lowercased()
        try fixture.launchRecords.save(
            AgentLaunchRecord(
                handle: "wm-repo-1",
                workspacePath: "/tmp/repo",
                socketLabel: "workspaces",
                launchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                identity: AgentLaunchIdentity(
                    conversationID: launched, requestedModel: "claude-opus-5-5", requestedEffort: "xhigh")
            )
        )

        let tile = UUID()
        let typed = UUID().uuidString.lowercased()
        let previousRun = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await previousRun.recordTerminalSession(
            HostTerminalSession(
                id: tile,
                key: .repoPath("/tmp/repo"),
                directory: URL(fileURLWithPath: "/tmp/repo"),
                terminalMode: .tmuxPerSession
            ),
            isActive: true,
            hooksSocketPath: nil
        )
        try await previousRun.recordAgentEvents(
            [.sessionStart(agentSessionID: typed, cwd: "/tmp/repo", kind: .claudeCode)],
            hostSessionID: tile,
            origin: .hook,
            status: AgentSessionStatus(
                hostSessionID: tile,
                agentSessionID: typed,
                kind: .claudeCode,
                cwd: "/tmp/repo",
                run: .idle,
                lastEventAt: Date(timeIntervalSince1970: 1_800_000_050),
                hookActive: true,
                createdAt: Date(timeIntervalSince1970: 1_800_000_050)
            ),
            occurredAt: Date(timeIntervalSince1970: 1_800_000_050)
        )

        let thisRun = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000))
        let indexer = fixture.indexer(thisRun)
        #expect(try await indexer.migrateOnce() == .init(written: 2))

        let fromLaunch = try #require(fixture.records.load(conversationID: launched))
        #expect(fromLaunch.observedBy == .migration)
        #expect(fromLaunch.launch == .init(handle: "wm-repo-1", model: "claude-opus-5-5", effort: "xhigh"))
        let fromTile = try #require(fixture.records.load(conversationID: typed))
        #expect(fromTile.lastSeenIn?.hostSessionID == tile.uuidString)
        #expect(fromTile.observedAt == Date(timeIntervalSince1970: 1_800_000_050))

        try FileManager.default.removeItem(at: try #require(fixture.records.fileURL(conversationID: typed)))
        #expect(try await indexer.migrateOnce() == .init(alreadyDone: true))
        #expect(fixture.records.load(conversationID: typed) == nil)

        try await indexer.rebuild()
        #expect(try await thisRun.fetchCurrentConversation(hostSessionID: tile) == nil)
    }

    /// A tile's sighting from the previous run, written to `localState` the way the listener
    /// records a SessionStart.
    private func recordPreviousRunSighting(
        _ id: String,
        tile: UUID,
        in localState: LocalStateStore
    ) async throws {
        try await localState.recordTerminalSession(
            HostTerminalSession(
                id: tile,
                key: .repoPath("/tmp/repo"),
                directory: URL(fileURLWithPath: "/tmp/repo"),
                terminalMode: .tmuxPerSession
            ),
            isActive: true,
            hooksSocketPath: nil
        )
        try await localState.recordAgentEvents(
            [.sessionStart(agentSessionID: id, cwd: "/tmp/repo", kind: .claudeCode)],
            hostSessionID: tile,
            origin: .hook,
            status: AgentSessionStatus(
                hostSessionID: tile,
                agentSessionID: id,
                kind: .claudeCode,
                cwd: "/tmp/repo",
                run: .idle,
                lastEventAt: Date(timeIntervalSince1970: 1_800_000_050),
                hookActive: true,
                createdAt: Date(timeIntervalSince1970: 1_800_000_050)
            ),
            occurredAt: Date(timeIntervalSince1970: 1_800_000_050)
        )
    }

    @Test("A migration whose writes failed stays open and carries the ids over once the destination works")
    func failedMigrationRunsAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let typed = UUID().uuidString.lowercased()
        try await recordPreviousRunSighting(
            typed, tile: UUID(),
            in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let thisRun = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000))
        let indexer = fixture.indexer(thisRun)
        try Data().write(to: fixture.records.directory)

        #expect(try await indexer.migrateOnce() == .init(failed: 1))
        #expect(try await thisRun.metadataValue(forKey: indexer.migrationMetadataKey) != "{}")

        try FileManager.default.removeItem(at: fixture.records.directory)
        #expect(try await indexer.migrateOnce() == .init(written: 1))
        #expect(fixture.records.load(conversationID: typed) != nil)
        #expect(try await thisRun.metadataValue(forKey: indexer.migrationMetadataKey) == "{}")
        #expect(try await indexer.migrateOnce() == .init(alreadyDone: true))
    }

    /// Codex's empty-first case: the store that migrates first started after a run whose
    /// only tile reported nothing, so the run before it, which holds the conversation, is
    /// not among its own recent runs. What it gathers is the database's, not its runs'.
    @Test("The first store to migrate carries every tile the database knows, not just its own runs'")
    func firstStoreGathersTheWholeDatabase() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let typed = UUID().uuidString.lowercased()
        try await recordPreviousRunSighting(
            typed, tile: UUID(),
            in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let holder = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000))
        try await recordTile(
            UUID(), in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_002_000)))
        let later = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_003_000))

        #expect(try await fixture.indexer(later).migrateOnce() == .init(written: 1))
        #expect(try await fixture.indexer(holder).migrateOnce() == .init(alreadyDone: true))
        #expect(fixture.records.load(conversationID: typed) != nil)
    }

    /// The same two stores, started together while another connection holds the write lock,
    /// so either can be the one that gathers. Ten rounds, because a wrong winner shows up in
    /// some rounds and not others.
    @Test("Two stores migrating at once carry the conversation whichever gathers")
    func concurrentStoresBothCarryTheConversation() async throws {
        var missing = 0
        for _ in 0..<10 {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let typed = UUID().uuidString.lowercased()
            try await recordPreviousRunSighting(
                typed, tile: UUID(),
                in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000)))
            let holder = fixture.indexer(
                try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000)))
            try await recordTile(
                UUID(), in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_002_000)))
            let later = fixture.indexer(
                try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_003_000)))

            var configuration = Configuration()
            configuration.allowsUnsafeTransactions = true
            let gate = try DatabaseQueue(
                path: fixture.root.appendingPathComponent("state.sqlite").path, configuration: configuration)
            try await gate.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
            let first = Task.detached { try await later.migrateOnce() }
            let second = Task.detached { try await holder.migrateOnce() }
            try await Task.sleep(for: .milliseconds(200))
            try await gate.writeWithoutTransaction { try $0.execute(sql: "COMMIT") }
            _ = try await (first.value, second.value)
            try gate.close()
            if fixture.records.load(conversationID: typed) == nil { missing += 1 }
        }
        #expect(missing == 0)
    }

    /// Codex's overlap: one store's whole attempt runs between another's staging and its
    /// writes. Both work the one stored set, so the failure stays owed after both, and the
    /// retry writes only that.
    @Test("An attempt nested inside another's leaves the failure owed and the rest settled")
    func overlappingAttemptsKeepAFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let failing = UUID().uuidString.lowercased()
        let landing = UUID().uuidString.lowercased()
        try await recordPreviousRunSighting(
            failing, tile: UUID(),
            in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let inner = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000))
        try await recordPreviousRunSighting(
            landing, tile: UUID(),
            in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_002_000)))
        let outer = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_003_000))

        try FileManager.default.createDirectory(at: fixture.records.directory, withIntermediateDirectories: true)
        let unreadable = try #require(fixture.records.fileURL(conversationID: failing))
        try Data("{}".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

        let innerIndexer = fixture.indexer(inner)
        var outerIndexer = fixture.indexer(outer)
        outerIndexer.afterStaging = {
            let inner = try await innerIndexer.migrateOnce()
            #expect(inner == .init(written: 1, failed: 1))
        }
        #expect(try await outerIndexer.migrateOnce() == .init(written: 1, failed: 1))
        #expect(try await outer.metadataValue(forKey: outerIndexer.migrationMetadataKey) != "{}")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        #expect(try await fixture.indexer(outer).migrateOnce() == .init(written: 1))
        #expect(fixture.records.load(conversationID: failing) != nil)
        #expect(fixture.records.load(conversationID: landing) != nil)
        #expect(try await fixture.indexer(inner).migrateOnce() == .init(alreadyDone: true))
    }

    /// Codex's moving key: an attempt stages, a writer creates the directory, the launch
    /// record that named the conversation goes away, and the attempt ends before writing.
    /// Only what was staged can carry the conversation now, and only under the same key.
    @Test(
        "What was staged before the destination existed is found after it does",
        arguments: ["link", "tmp", "private-tmp"])
    func stagedBeforeTheDirectoryExisted(_ spelling: String) async throws {
        let scratch = "ws-migration-\(UUID().uuidString.prefix(8))"
        let real = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(scratch)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("target"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("link"), withDestinationURL: real.appendingPathComponent("target"))
        let destination: URL
        switch spelling {
        case "link": destination = real.appendingPathComponent("link/records")
        case "tmp": destination = URL(fileURLWithPath: "/tmp/\(scratch)/records")
        default: destination = real.appendingPathComponent("records")
        }
        let records = ConversationRecordStore(directory: destination)
        let launchRecords = AgentLaunchRecordStore(directory: real.appendingPathComponent("launches"))
        let state = real.appendingPathComponent("state.sqlite")
        func indexer() throws -> ConversationIndexer {
            ConversationIndexer(
                records: records, localState: try LocalStateStore(databaseURL: state), launchRecords: launchRecords)
        }
        struct Interrupted: Error {}

        let launched = UUID().uuidString.lowercased()
        try launchRecords.save(
            AgentLaunchRecord(
                handle: "wm-repo-1",
                workspacePath: "/tmp/repo",
                socketLabel: "workspaces",
                launchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                identity: AgentLaunchIdentity(conversationID: launched, requestedModel: nil, requestedEffort: nil)
            )
        )
        var first = try indexer()
        first.afterStaging = {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: launchRecords.directory)
            throw Interrupted()
        }
        await #expect(throws: Interrupted.self) { try await first.migrateOnce() }

        #expect(try await indexer().migrateOnce() == .init(written: 1))
        #expect(records.load(conversationID: launched) != nil)
    }

    /// Codex's LEXICAL case: `local/link/../records` is `outside/records` on disk, a
    /// different directory from `local/records`, so each is migrated into.
    @Test("A `..` after a link names its own destination")
    func parentAfterALinkIsItsOwnDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let local = fixture.root.appendingPathComponent("local")
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("child"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: local.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("child"))
        let throughLink = ConversationRecordStore(directory: local.appendingPathComponent("link/../records"))
        let beside = ConversationRecordStore(directory: local.appendingPathComponent("records"))
        let typed = UUID().uuidString.lowercased()
        try await recordPreviousRunSighting(
            typed, tile: UUID(),
            in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let state = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000))

        for store in [throughLink, beside] {
            let indexer = ConversationIndexer(records: store, localState: state, launchRecords: fixture.launchRecords)
            #expect(try await indexer.migrateOnce() == .init(written: 1))
        }
        #expect(throughLink.load(conversationID: typed) != nil)
        #expect(beside.load(conversationID: typed) != nil)
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("records").path))
    }

    /// The gather takes each tile's newest sighting of a conversation, its time and its
    /// directory both, whatever order the events were recorded in.
    @Test("A tile's newest sighting of a conversation is the one migrated")
    func newestSightingIsMigrated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let typed = UUID().uuidString.lowercased()
        let tile = UUID()
        let state = try fixture.localState()
        try await recordTile(tile, in: state)
        let events = [(1_800_000_090.0, "/newest"), (1_800_000_010.0, "/oldest"), (1_800_000_050.0, "/middle")]
        for (seconds, cwd) in events {
            let at = Date(timeIntervalSince1970: seconds)
            try await state.recordAgentEvents(
                [.sessionStart(agentSessionID: typed, cwd: cwd, kind: .claudeCode)],
                hostSessionID: tile,
                origin: .hook,
                status: AgentSessionStatus(
                    hostSessionID: tile, agentSessionID: typed, kind: .claudeCode, cwd: cwd, run: .idle,
                    lastEventAt: at, hookActive: true, createdAt: at),
                occurredAt: at
            )
        }

        #expect(try await fixture.indexer(state).migrateOnce() == .init(written: 1))
        let record = try #require(fixture.records.load(conversationID: typed))
        #expect(record.cwd == "/newest")
        #expect(record.observedAt == Date(timeIntervalSince1970: 1_800_000_090))
    }

    /// Codex's linked-socket case: the socket directory is a link into a directory whose
    /// parent cannot be searched. The link is there, so it is not absent; once its target can
    /// be reached, its records are read through it.
    @Test("A linked socket directory that cannot be reached stops the migration without completing it")
    func unreachableLinkedSocketStoresNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launched = UUID().uuidString.lowercased()
        let socket = try saveLaunch(launched, in: fixture.launchRecords).deletingLastPathComponent()
        let parent = fixture.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("workspaces")
        try FileManager.default.moveItem(at: socket, to: target)
        try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let state = try fixture.localState()
        let indexer = fixture.indexer(state)

        await #expect(throws: (any Error).self) { try await indexer.migrateOnce() }
        #expect(try await state.metadataValue(forKey: indexer.migrationMetadataKey) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        #expect(try await indexer.migrateOnce() == .init(written: 1))
        #expect(fixture.records.load(conversationID: launched) != nil)
    }

    private func saveLaunch(_ conversationID: String, in launchRecords: AgentLaunchRecordStore) throws -> URL {
        try launchRecords.save(
            AgentLaunchRecord(
                handle: "wm-repo-1",
                workspacePath: "/tmp/repo",
                socketLabel: "workspaces",
                launchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                identity: AgentLaunchIdentity(conversationID: conversationID, requestedModel: nil, requestedEffort: nil)
            )
        )
        return launchRecords.directory(socketLabel: "workspaces").appendingPathComponent("wm-repo-1.json")
    }

    /// Codex's READ cases: a launch record the gather cannot list, open or decode is not an
    /// absent one. The attempt fails, stores nothing, and a later one carries the record.
    @Test(
        "A launch record that cannot be read stops the migration without completing it",
        arguments: ["file", "socket", "root", "truncated"])
    func unreadableLaunchRecordStoresNothing(_ failure: String) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launched = UUID().uuidString.lowercased()
        let file = try saveLaunch(launched, in: fixture.launchRecords)
        let blocked: URL? =
            switch failure {
            case "file": file
            case "socket": file.deletingLastPathComponent()
            case "root": fixture.launchRecords.directory
            default: nil
            }
        let whole = try Data(contentsOf: file)
        if let blocked {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        } else {
            try whole.prefix(whole.count / 2).write(to: file)
        }
        defer {
            if let blocked {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            }
        }
        let state = try fixture.localState()
        let indexer = fixture.indexer(state)

        await #expect(throws: (any Error).self) { try await indexer.migrateOnce() }
        #expect(try await state.metadataValue(forKey: indexer.migrationMetadataKey) == nil)

        if let blocked {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        } else {
            try whole.write(to: file)
        }
        #expect(try await indexer.migrateOnce() == .init(written: 1))
        #expect(fixture.records.load(conversationID: launched) != nil)
    }

    /// Codex's CONFIG case: two runs share the database and the records directory but read
    /// launch records from different roots. The one whose root is empty finishes first, and
    /// the other's root is still carried.
    @Test("Each launch-record root is migrated, whichever finishes first")
    func eachLaunchRootIsMigrated() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let launched = UUID().uuidString.lowercased()
        let other = AgentLaunchRecordStore(directory: fixture.root.appendingPathComponent("other-launches"))
        _ = try saveLaunch(launched, in: other)
        let state = try fixture.localState()
        let empty = fixture.indexer(state)
        let holding = ConversationIndexer(records: fixture.records, localState: state, launchRecords: other)

        #expect(try await empty.migrateOnce() == .init())
        #expect(try await holding.migrateOnce() == .init(written: 1))
        #expect(fixture.records.load(conversationID: launched) != nil)
    }

    /// Codex's cost finding: a gather can take seconds on a large database, so it reads
    /// through a snapshot. Another connection holds the write lock from before the gather
    /// until `afterGathering`, and nothing else releases it. A gather that asked for the
    /// write lock would wait out the store's busy timeout and throw `SQLITE_BUSY` before
    /// reaching that release, so a migration that completes, having released the gate,
    /// gathered without the lock however slowly the machine runs.
    @Test("Gathering holds no write lock")
    func gatherHoldsNoWriteLock() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let typed = UUID().uuidString.lowercased()
        try await recordPreviousRunSighting(
            typed, tile: UUID(),
            in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        var indexer = fixture.indexer(
            try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000)))

        var configuration = Configuration()
        configuration.allowsUnsafeTransactions = true
        let gate = try DatabaseQueue(
            path: fixture.root.appendingPathComponent("state.sqlite").path, configuration: configuration)
        defer { try? gate.close() }
        try await gate.writeWithoutTransaction { try $0.execute(sql: "BEGIN IMMEDIATE") }
        indexer.afterGathering = { try await gate.writeWithoutTransaction { try $0.execute(sql: "COMMIT") } }

        let outcome = try await indexer.migrateOnce()

        #expect(try await gate.writeWithoutTransaction { $0.isInsideTransaction } == false)
        #expect(outcome == .init(written: 1))
    }

    private func recordTile(_ tile: UUID, in localState: LocalStateStore) async throws {
        try await localState.recordTerminalSession(
            HostTerminalSession(
                id: tile,
                key: .repoPath("/tmp/repo"),
                directory: URL(fileURLWithPath: "/tmp/repo"),
                terminalMode: .tmuxPerSession
            ),
            isActive: true,
            hooksSocketPath: nil
        )
    }

    @Test("An id no record can hold is rejected without holding the migration open")
    func invalidIDIsRejectedNotRetried() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let typed = UUID().uuidString.lowercased()
        let previousRun = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try await recordPreviousRunSighting(typed, tile: UUID(), in: previousRun)
        try await recordPreviousRunSighting("not-a-conversation-id", tile: UUID(), in: previousRun)
        let indexer = fixture.indexer(try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000)))

        #expect(try await indexer.migrateOnce() == .init(written: 1, rejected: 1))
        #expect(try await indexer.migrateOnce() == .init(alreadyDone: true))
    }

    @Test("Pointing the same database at a new records directory migrates into it")
    func newDestinationIsBootstrapped() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let typed = UUID().uuidString.lowercased()
        try await recordPreviousRunSighting(
            typed, tile: UUID(),
            in: try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let thisRun = try fixture.localState(runStartedAt: Date(timeIntervalSince1970: 1_800_001_000))
        #expect(try await fixture.indexer(thisRun).migrateOnce() == .init(written: 1))

        let moved = ConversationRecordStore(directory: fixture.root.appendingPathComponent("elsewhere"))
        let movedIndexer = ConversationIndexer(
            records: moved, localState: thisRun, launchRecords: fixture.launchRecords)
        #expect(try await movedIndexer.migrateOnce() == .init(written: 1))
        #expect(moved.load(conversationID: typed) != nil)
    }

    /// A database from before the restore columns and the conversation index: `v3` and
    /// `conversation_index` both run on it, its rows survive untouched, and the ids its
    /// tiles reported are carried into records and indexed.
    @Test("A v2 database migrates through the restore columns and the conversation index")
    func oldDatabaseMigratesThroughBoth() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("old.sqlite")
        let tile = UUID()
        let typed = UUID().uuidString.lowercased()
        let then = ConversationRecordJSON.string(Date(timeIntervalSince1970: 1_800_000_000))
        let old = try DatabaseQueue(path: url.path)
        try LocalStateStore.migrator.migrate(old, upTo: "v2")
        try await old.write { db in
            try db.execute(
                sql: """
                    INSERT INTO terminal_sessions (
                        host_session_id, session_key, target_kind, target_path, directory_path,
                        terminal_mode, is_active, created_at, last_seen_at, run_id, run_started_at
                    ) VALUES (?, 'repo:/tmp/repo', 'repo', '/tmp/repo', '/tmp/repo',
                        'tmux_per_session', 1, ?, ?, 'old-run', ?)
                    """,
                arguments: [tile.uuidString, then, then, then]
            )
            try db.execute(
                sql: """
                    INSERT INTO agent_status_events (
                        id, host_session_id, agent_session_id, agent_kind, origin, event_name,
                        run_state, cwd, event_at
                    ) VALUES (?, ?, ?, ?, 'hook', 'session_start', 'idle', '/tmp/repo', ?)
                    """,
                arguments: [UUID().uuidString, tile.uuidString, typed, AgentKind.claudeCode.rawValue, then]
            )
        }
        try old.close()

        let store = try LocalStateStore(databaseURL: url, runStartedAt: Date(timeIntervalSince1970: 1_800_001_000))
        let migrated = try DatabaseQueue(path: url.path)
        let (applied, row, tables) = try await migrated.read { db in
            (
                try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"),
                try Row.fetchOne(db, sql: "SELECT * FROM terminal_sessions"),
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE name = 'conversation_index'")
            )
        }
        try migrated.close()
        #expect(applied == ["conversation_index", "v1", "v2", "v3"])
        #expect(tables == ["conversation_index"])
        #expect(row?["host_session_id"] == tile.uuidString)
        #expect(row?["is_active"] == 1)
        #expect(row?["stale_since"] == nil as String?)
        #expect(row?["holder_lost_at"] == nil as String?)

        let indexer = fixture.indexer(store)
        try await indexer.launch()
        #expect(fixture.records.load(conversationID: typed)?.lastSeenIn?.hostSessionID == tile.uuidString)
        #expect(try await store.fetchCurrentConversation(hostSessionID: tile)?.conversationID == typed)
    }

    @Test("/resume inside a tile makes the tile's current conversation the new id, through the app's writer")
    func appWriterFollowsAResume() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let localState = try fixture.localState()
        let clock = SteppingClock(start: 1_800_000_000)
        let recorder = ConversationIdentityRecorder(
            store: fixture.records, socketLabel: "workspaces", clock: clock.next)
        let tile = UUID()
        let before = UUID().uuidString.lowercased()
        let after = UUID().uuidString.lowercased()

        await recorder.observe(.init(sessionID: before, cwd: "/tmp/repo", transcriptPath: nil), hostSessionID: tile)
        await recorder.observe(.init(sessionID: before, cwd: "/tmp/repo", transcriptPath: nil), hostSessionID: tile)
        await recorder.observe(
            .init(sessionID: after, cwd: "/tmp/repo", transcriptPath: "/tmp/a.jsonl"), hostSessionID: tile)
        try await fixture.indexer(localState).rebuild()

        #expect(try await localState.fetchCurrentConversation(hostSessionID: tile)?.conversationID == after)
        #expect(fixture.records.load(conversationID: before)?.observedAt == Date(timeIntervalSince1970: 1_800_000_001))
        #expect(fixture.records.load(conversationID: after)?.observedBy == .app)
        #expect(fixture.records.load(conversationID: after)?.transcriptPath == "/tmp/a.jsonl")
    }
}

extension ConversationIndexTests {
    /// The listener misses B's events, the standalone observer records B, and A's next payload
    /// must still make A the tile's current conversation again.
    @Test("A sighting the app writer saw before still lands after another writer recorded a different id")
    func appWriterDefersToTheFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let localState = try fixture.localState()
        let clock = SteppingClock(start: 1_800_000_000)
        let recorder = ConversationIdentityRecorder(store: fixture.records, clock: clock.next)
        let tile = UUID()
        let a = UUID().uuidString.lowercased()
        let b = UUID().uuidString.lowercased()

        await recorder.observe(.init(sessionID: a, cwd: "/tmp/repo", transcriptPath: nil), hostSessionID: tile)
        try fixture.records.record(sighting(b, tile: tile, at: 1_800_000_000.5))
        #expect(try await currentConversation(of: tile, fixture: fixture, localState: localState) == b)
        await recorder.observe(.init(sessionID: a, cwd: "/tmp/repo", transcriptPath: nil), hostSessionID: tile)
        #expect(try await currentConversation(of: tile, fixture: fixture, localState: localState) == a)
    }

    private func currentConversation(
        of tile: UUID,
        fixture: Fixture,
        localState: LocalStateStore
    ) async throws -> String? {
        try await fixture.indexer(localState).sync()
        return try await localState.fetchCurrentConversation(hostSessionID: tile)?.conversationID
    }
}

/// Hands out one second later on every call, so the order the recorder writes in is the order
/// its sightings are dated in.
final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval

    init(start: TimeInterval) {
        seconds = start
    }

    var next: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            defer { seconds += 1 }
            return Date(timeIntervalSince1970: seconds)
        }
    }
}
