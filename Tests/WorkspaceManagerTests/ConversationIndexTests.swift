//
//  ConversationIndexTests.swift
//  WorkspaceManagerTests
//
//  The conversation index is a lookup over the record files and nothing else, so these pin
//  that every way of building it lands on the same rows, that a tile's current conversation
//  follows the newest sighting, and that the one-time migration carries old ids over once.
//

import Foundation
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

    @Test("The one-time migration writes records from Launch Records and previous-run ids, once")
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
        #expect(try await thisRun.metadataValue(forKey: indexer.migrationMetadataKey) == nil)

        try FileManager.default.removeItem(at: fixture.records.directory)
        #expect(try await indexer.migrateOnce() == .init(written: 1))
        #expect(fixture.records.load(conversationID: typed) != nil)
        #expect(try await indexer.migrateOnce() == .init(alreadyDone: true))
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
