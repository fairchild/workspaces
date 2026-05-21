//
//  WorkspaceJournalTests.swift
//  WorkspaceManagerTests
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@MainActor
@Suite("WorkspaceJournal")
struct WorkspaceJournalTests {
    @Test("Empty store yields no events for any workspace")
    func emptyStore() async throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let workspaceID = UUID()
        let journal = WorkspaceJournal(store: fixture.store)

        await journal.refresh(workspaceID: workspaceID, hostSessionID: UUID())

        #expect(journal.events(for: workspaceID).isEmpty)
        #expect(journal.events(for: UUID()).isEmpty)
    }

    @Test("Nil store is a safe no-op")
    func nilStoreNoOp() async {
        let journal = WorkspaceJournal(store: nil)
        await journal.refresh(workspaceID: UUID(), hostSessionID: UUID())
        #expect(journal.events.isEmpty)
    }

    @Test("Refresh publishes events newest first for the requested workspace")
    func refreshOrdersNewestFirst() async throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let workspaceID = UUID()
        let hostSessionID = UUID()

        try await fixture.recordSequence(
            hostSessionID: hostSessionID,
            entries: [
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    event: .sessionStart(agentSessionID: "a", cwd: "/tmp/w", kind: .claudeCode),
                    run: .idle
                ),
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_001),
                    event: .toolStart(name: "Bash", detail: nil),
                    run: .runningTool(name: "Bash", detail: nil)
                ),
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_002),
                    event: .stopped(error: nil),
                    run: .complete
                ),
            ]
        )

        let journal = WorkspaceJournal(store: fixture.store)
        await journal.refresh(workspaceID: workspaceID, hostSessionID: hostSessionID)

        let events = journal.events(for: workspaceID)
        #expect(events.count == 3)
        #expect(events.map(\.kind) == [
            .completed,
            .toolRun(name: "Bash"),
            .started,
        ])
        #expect(events.allSatisfy { $0.workspaceID == workspaceID })
        #expect(events.allSatisfy { $0.hostSessionID == hostSessionID })
    }

    @Test("Different workspaces stay isolated in the published map")
    func multiWorkspaceIsolation() async throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let workspaceA = UUID()
        let workspaceB = UUID()
        let hostA = UUID()
        let hostB = UUID()

        try await fixture.recordSequence(
            hostSessionID: hostA,
            entries: [
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    event: .sessionStart(agentSessionID: "a", cwd: "/tmp/a", kind: .claudeCode),
                    run: .idle
                )
            ]
        )
        try await fixture.recordSequence(
            hostSessionID: hostB,
            entries: [
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_010),
                    event: .sessionStart(agentSessionID: "b", cwd: "/tmp/b", kind: .claudeCode),
                    run: .idle
                ),
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_011),
                    event: .errored(category: .server, message: "boom"),
                    run: .errored(category: .server, message: "boom")
                ),
            ]
        )

        let journal = WorkspaceJournal(store: fixture.store)
        await journal.refresh(workspaceID: workspaceA, hostSessionID: hostA)
        await journal.refresh(workspaceID: workspaceB, hostSessionID: hostB)

        #expect(journal.events(for: workspaceA).count == 1)
        #expect(journal.events(for: workspaceB).count == 2)
        #expect(journal.events(for: workspaceA).first?.hostSessionID == hostA)
        #expect(journal.events(for: workspaceB).first?.hostSessionID == hostB)
    }

    @Test("Limit caps the number of returned events")
    func respectsLimit() async throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let workspaceID = UUID()
        let hostSessionID = UUID()

        var entries: [JournalFixture.Entry] = []
        for index in 0..<10 {
            entries.append(
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index)),
                    event: .userPrompt(prompt: nil),
                    run: .thinking
                )
            )
        }
        try await fixture.recordSequence(hostSessionID: hostSessionID, entries: entries)

        let journal = WorkspaceJournal(store: fixture.store)
        await journal.refresh(
            workspaceID: workspaceID,
            hostSessionID: hostSessionID,
            limit: 3
        )

        #expect(journal.events(for: workspaceID).count == 3)
    }

    @Test("Refresh against an unknown host session publishes an empty array")
    func unknownHostSession() async throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let workspaceID = UUID()
        let knownHost = UUID()

        try await fixture.recordSequence(
            hostSessionID: knownHost,
            entries: [
                .init(
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    event: .sessionStart(agentSessionID: "x", cwd: "/tmp/x", kind: .claudeCode),
                    run: .idle
                )
            ]
        )

        let journal = WorkspaceJournal(store: fixture.store)
        await journal.refresh(workspaceID: workspaceID, hostSessionID: UUID())

        #expect(journal.events(for: workspaceID).isEmpty)
    }
}

private struct JournalFixture {
    struct Entry {
        let occurredAt: Date
        let event: AgentEvent
        let run: AgentRunState
    }

    let directory: URL
    let store: LocalStateStore

    init() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("state.sqlite")
        self.store = try LocalStateStore(databaseURL: databaseURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func recordSequence(hostSessionID: UUID, entries: [Entry]) async throws {
        for entry in entries {
            let status = AgentSessionStatus(
                hostSessionID: hostSessionID,
                agentSessionID: "agent-\(hostSessionID.uuidString.prefix(8))",
                kind: .claudeCode,
                cwd: "/tmp/w",
                run: entry.run,
                lastEventAt: entry.occurredAt,
                createdAt: entry.occurredAt
            )
            try await store.recordAgentEvents(
                [entry.event],
                hostSessionID: hostSessionID,
                origin: .hook,
                status: status,
                occurredAt: entry.occurredAt
            )
        }
    }
}
