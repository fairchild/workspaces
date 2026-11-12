//
//  LocalStateStoreRestoreSetTests.swift
//  WorkspaceManagerTests
//
//  The previous run's restore set at the store seam: every tile still open at the
//  end of that run comes back, whatever tab was selected, and only a deliberate end
//  takes a row out of it.
//

import Foundation
@preconcurrency import GRDB
import Testing

@testable import WorkspaceManagerCore

@Suite("LocalStateStore restore set")
struct LocalStateStoreRestoreSetTests {
    private static let previousRunStart = Date(timeIntervalSince1970: 1_700_000_000)
    private static let currentRunStart = Date(timeIntervalSince1970: 1_700_100_000)

    private func session(
        _ id: UUID = UUID(), path: String = "/code/repo", tmuxName: String? = nil
    )
        -> HostTerminalSession
    {
        HostTerminalSession(
            id: id,
            key: .repoPath("/code/repo"),
            directory: URL(fileURLWithPath: path),
            terminalMode: .tmuxPerSession,
            tmuxSessionNameOverride: tmuxName
        )
    }

    private func stores(in directory: URL) throws -> (previous: LocalStateStore, open: () throws -> LocalStateStore) {
        let db = directory.appendingPathComponent("state.sqlite")
        let previous = try LocalStateStore(databaseURL: db, runID: UUID(), runStartedAt: Self.previousRunStart)
        return (previous, { try LocalStateStore(databaseURL: db, runID: UUID(), runStartedAt: Self.currentRunStart) })
    }

    @Test("The previous run's restore set holds every open tile, selected or not")
    func backgroundTabAndSplitPaneAreInTheRestoreSet() async throws {
        let directory = try TemporaryStoreDirectory()
        defer { directory.cleanup() }
        let (previous, openCurrent) = try stores(in: directory.url)
        let selected = session()
        let backgroundTab = session(tmuxName: "wm-repo-tab")
        let splitPane = session(tmuxName: "wm-repo-split")
        try await previous.recordTerminalSession(selected, isActive: true, hooksSocketPath: nil)
        try await previous.recordTerminalSession(backgroundTab, isActive: false, hooksSocketPath: nil)
        try await previous.recordTerminalSession(splitPane, isActive: false, hooksSocketPath: nil)

        let rows = try await openCurrent().fetchPreviousRunSessions()

        let selection = Dictionary(uniqueKeysWithValues: rows.map { ($0.hostSessionID, $0.isActive) })
        #expect(selection == [selected.id: true, backgroundTab.id: false, splitPane.id: false])
    }

    @Test("A tile whose tmux server died stays restorable")
    func holderLostRowStaysInTheRestoreSet() async throws {
        let directory = try TemporaryStoreDirectory()
        defer { directory.cleanup() }
        let (previous, openCurrent) = try stores(in: directory.url)
        let lost = session()
        let lostAt = Date(timeIntervalSince1970: 1_700_000_500)
        try await previous.recordTerminalSession(lost, isActive: false, hooksSocketPath: nil)
        try await previous.markTerminalSessionHolderLost(hostSessionID: lost.id, lostAt: lostAt)

        let rows = try await openCurrent().fetchPreviousRunSessions()

        #expect(rows.map(\.hostSessionID) == [lost.id])
        #expect(rows.first?.holderLostAt == lostAt)
        #expect(rows.first?.endedAt == nil)
    }

    @Test("A tile the user closed is not restorable")
    func userClosedRowLeavesTheRestoreSet() async throws {
        let directory = try TemporaryStoreDirectory()
        defer { directory.cleanup() }
        let (previous, openCurrent) = try stores(in: directory.url)
        let closed = session()
        let kept = session()
        try await previous.recordTerminalSession(closed, isActive: true, hooksSocketPath: nil)
        try await previous.recordTerminalSession(kept, isActive: false, hooksSocketPath: nil)
        try await previous.markTerminalSessionEnded(hostSessionID: closed.id, endedAt: Date())

        let rows = try await openCurrent().fetchPreviousRunSessions()

        #expect(rows.map(\.hostSessionID) == [kept.id])
    }

    @Test("Holder loss never reopens an ended row, and a surface upsert clears it")
    func holderLossRespectsEndedAndClearsOnUpsert() async throws {
        let directory = try TemporaryStoreDirectory()
        defer { directory.cleanup() }
        let (store, _) = try stores(in: directory.url)
        let ended = session()
        let rejoined = session()
        try await store.recordTerminalSession(ended, isActive: true, hooksSocketPath: nil)
        try await store.recordTerminalSession(rejoined, isActive: true, hooksSocketPath: nil)
        try await store.markTerminalSessionEnded(hostSessionID: ended.id, endedAt: Date())

        try await store.markTerminalSessionHolderLost(hostSessionID: ended.id, lostAt: Date())
        try await store.markTerminalSessionHolderLost(hostSessionID: rejoined.id, lostAt: Date())
        try await store.recordTerminalSession(rejoined, isActive: false, hooksSocketPath: nil)

        let rows = Dictionary(
            uniqueKeysWithValues: try await store.fetchContinuitySessions().map { ($0.hostSessionID, $0) })
        #expect(rows[ended.id]?.holderLostAt == nil)
        #expect(rows[ended.id]?.endedAt != nil)
        #expect(rows[rejoined.id]?.holderLostAt == nil)
        #expect(rows[rejoined.id]?.endedAt == nil)
    }

    /// A tile that left the window with its work still alive keeps its row open, but the row
    /// is no longer its scope's selected tab: the scope selects a neighbour, and two rows of
    /// one scope both claiming selection would land the next launch on the older one.
    @Test("A row left open when its tile goes is no longer its scope's selected tab")
    func rowsLeftOpenAreDeselected() async throws {
        let directory = try TemporaryStoreDirectory()
        defer { directory.cleanup() }
        let (previous, openCurrent) = try stores(in: directory.url)
        let lost = session()
        let detached = session()
        try await previous.recordTerminalSession(lost, isActive: true, hooksSocketPath: nil)
        try await previous.recordTerminalSession(detached, isActive: true, hooksSocketPath: nil)

        try await previous.markTerminalSessionHolderLost(hostSessionID: lost.id, lostAt: Date())
        try await previous.markTerminalSessionDeselected(hostSessionID: detached.id)

        let rows = try await openCurrent().fetchPreviousRunSessions()
        #expect(Set(rows.map(\.hostSessionID)) == [lost.id, detached.id])
        #expect(rows.allSatisfy { !$0.isActive && $0.endedAt == nil })
    }

    /// `ensureTerminalSessionRow` gives an early agent event a row to point at. No tile
    /// recorded it, so restore must not invent one; once a surface records the same id,
    /// it is an ordinary tile.
    @Test("Placeholder rows from early agent events stay out of the restore set")
    func placeholderRowsAreNotTiles() async throws {
        let directory = try TemporaryStoreDirectory()
        defer { directory.cleanup() }
        let (previous, openCurrent) = try stores(in: directory.url)
        let placeholderOnly = UUID()
        let upgraded = UUID()
        for hostSessionID in [placeholderOnly, upgraded] {
            try await previous.recordAgentEvents(
                [
                    .sessionStart(
                        agentSessionID: "55555555-5555-4555-8555-555555555555", cwd: "/code/repo", kind: .claudeCode)
                ],
                hostSessionID: hostSessionID,
                origin: .hook,
                status: AgentSessionStatus(
                    hostSessionID: hostSessionID,
                    agentSessionID: nil,
                    kind: .claudeCode,
                    cwd: "/code/repo",
                    run: .idle,
                    modelDisplayName: nil,
                    lastEventAt: Self.previousRunStart,
                    hookActive: true,
                    createdAt: Self.previousRunStart
                )
            )
        }
        try await previous.recordTerminalSession(session(upgraded), isActive: false, hooksSocketPath: nil)

        let rows = try await openCurrent().fetchPreviousRunSessions()

        #expect(rows.map(\.hostSessionID) == [upgraded])
    }

    @Test("Retention keeps a background tab's latest agent event")
    func retentionKeepsBackgroundTabIdentity() async throws {
        let directory = try TemporaryStoreDirectory()
        defer { directory.cleanup() }
        let (store, _) = try stores(in: directory.url)
        let backgroundTab = session()
        try await store.recordTerminalSession(backgroundTab, isActive: false, hooksSocketPath: nil)
        try await store.recordAgentEvents(
            [
                .sessionStart(
                    agentSessionID: "55555555-5555-4555-8555-555555555555", cwd: "/code/repo", kind: .claudeCode)
            ],
            hostSessionID: backgroundTab.id,
            origin: .hook,
            status: AgentSessionStatus(
                hostSessionID: backgroundTab.id,
                agentSessionID: "55555555-5555-4555-8555-555555555555",
                kind: .claudeCode,
                cwd: "/code/repo",
                run: .idle,
                modelDisplayName: nil,
                lastEventAt: Self.previousRunStart,
                hookActive: true,
                createdAt: Self.previousRunStart
            ),
            occurredAt: Self.previousRunStart
        )

        let outcome = try await store.runRetention(now: Date(timeIntervalSince1970: 2_000_000_000))

        #expect(outcome.deletedAgentEvents == 0)
        let events = try await store.fetchAgentStatusEvents(hostSessionID: backgroundTab.id)
        #expect(events.count == 1)
    }
}

private struct TemporaryStoreDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalStateStoreRestoreSetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}
