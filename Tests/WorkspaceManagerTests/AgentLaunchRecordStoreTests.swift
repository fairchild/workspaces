//
//  AgentLaunchRecordStoreTests.swift
//  WorkspaceManagerTests
//
//  Launch records outlive every process that wrote them, and other processes read them
//  back, so these pin the round trip and what a bad file or a bad name does.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Agent launch record store")
struct AgentLaunchRecordStoreTests {
    private func withStore(_ body: (AgentLaunchRecordStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-records-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(AgentLaunchRecordStore(directory: directory))
    }

    private func withStore(_ body: (AgentLaunchRecordStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-records-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(AgentLaunchRecordStore(directory: directory))
    }

    private func record(handle: String = "wm-a-1", socketLabel: String = "workspaces") -> AgentLaunchRecord {
        AgentLaunchRecord(
            handle: handle,
            workspacePath: FileManager.default.temporaryDirectory.path,
            socketLabel: socketLabel,
            launchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: AgentLaunchIdentity(
                conversationID: "fa08c461-2979-41db-85fb-b5c90c0d2d8b",
                requestedModel: "claude-opus-5-5",
                requestedEffort: "xhigh"
            )
        )
    }

    @Test("A record round-trips, and a later launch on the handle replaces it")
    func roundTrip() throws {
        try withStore { store in
            let first = record()
            try store.save(first)
            #expect(store.load(socketLabel: "workspaces", handle: "wm-a-1") == first)

            let second = AgentLaunchRecord(
                handle: "wm-a-1",
                workspacePath: "/tmp/a",
                socketLabel: "workspaces",
                launchedAt: first.launchedAt.addingTimeInterval(60),
                identity: nil
            )
            try store.save(second)
            #expect(store.load(socketLabel: "workspaces", handle: "wm-a-1") == second)
        }
    }

    @Test("Records on one socket do not answer for another")
    func socketIsolation() throws {
        try withStore { store in
            try store.save(record(socketLabel: "isolated"))
            #expect(store.load(socketLabel: "workspaces", handle: "wm-a-1") == nil)
            #expect(store.all(socketLabel: "workspaces").isEmpty)
            #expect(store.all(socketLabel: "isolated").count == 1)
        }
    }

    @Test("Listing skips a file nothing can act on")
    func corruptFile() throws {
        try withStore { store in
            try store.save(record())
            try "not json".write(
                to: store.directory(socketLabel: "workspaces").appendingPathComponent("broken.json"),
                atomically: true,
                encoding: .utf8
            )
            #expect(store.all(socketLabel: "workspaces").map(\.handle) == ["wm-a-1"])
        }
    }

    // MARK: - Resume lookup

    private func resumeCommand(
        store: AgentLaunchRecordStore,
        processListing: String? = "1 0 /sbin/launchd",
        transcriptExists: Bool = true
    ) async -> String? {
        let table = processListing.flatMap(ProcessTable.init(listing:))
        return await store.resumeCommand(
            socketLabel: "workspaces",
            tmuxSessionName: "wm-a-1",
            holders: ConversationHolderProbe(
                records: nil, readProcessTable: { table }, inspector: .none, recordedSession: { _ in .notRecorded }),
            resumability: ClaudeTranscriptResumability(
                environment: [:],
                homeDirectory: URL(fileURLWithPath: "/tmp/no-such-home"),
                fileExists: { _ in transcriptExists }
            )
        )
    }

    @Test("A recorded conversation with a transcript and no holder can be continued")
    func resumeCommandForARecordedConversation() async throws {
        try await withStore { store in
            try store.save(record())
            #expect(
                await resumeCommand(store: store)
                    == "claude --resume fa08c461-2979-41db-85fb-b5c90c0d2d8b --effort xhigh"
            )
        }
    }

    @Test("Nothing is offered for a conversation something still holds")
    func resumeCommandSkipsAHeldConversation() async throws {
        try await withStore { store in
            try store.save(record())
            let listing = "10 1 claude --resume fa08c461-2979-41db-85fb-b5c90c0d2d8b"
            #expect(await resumeCommand(store: store, processListing: listing) == nil)
            // No process table means a second writer cannot be ruled out.
            #expect(await resumeCommand(store: store, processListing: nil) == nil)
        }
    }

    @Test("Nothing is offered for a conversation from an earlier workspace at the same path")
    func resumeCommandSkipsAnEarlierWorkspace() async throws {
        try await withStore { store in
            let earlier = record()
            try store.save(
                AgentLaunchRecord(
                    handle: earlier.handle,
                    workspacePath: earlier.workspacePath,
                    socketLabel: earlier.socketLabel,
                    launchedAt: Date(timeIntervalSince1970: 0),
                    identity: earlier.identity
                )
            )
            #expect(await resumeCommand(store: store) == nil)
        }
    }

    @Test("Nothing is offered without a transcript, a record, or a named conversation")
    func resumeCommandNeedsAConversation() async throws {
        try await withStore { store in
            #expect(await resumeCommand(store: store) == nil)

            try store.save(record())
            #expect(await resumeCommand(store: store, transcriptExists: false) == nil)

            try store.save(
                AgentLaunchRecord(
                    handle: "wm-a-1",
                    workspacePath: "/tmp/a",
                    socketLabel: "workspaces",
                    launchedAt: Date(),
                    identity: nil
                )
            )
            #expect(await resumeCommand(store: store) == nil)
        }
    }

    @Test("A record speaks only for the workspace it launched into")
    func recordsAreBoundToTheirWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launched-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.creationDate] as? Date
        )
        func launched(at date: Date, path: String = directory.path) -> AgentLaunchRecord {
            AgentLaunchRecord(
                handle: "wm-a-1",
                workspacePath: path,
                socketLabel: "workspaces",
                launchedAt: date,
                identity: nil
            )
        }

        #expect(launched(at: created.addingTimeInterval(60)).isForWorkspaceOnDisk)
        // A stored time has lost its fraction, so the launch's own second has to pass.
        #expect(launched(at: created.addingTimeInterval(-0.5)).isForWorkspaceOnDisk)
        #expect(!launched(at: created.addingTimeInterval(-60)).isForWorkspaceOnDisk)
        #expect(!launched(at: created, path: directory.path + "-gone").isForWorkspaceOnDisk)
    }

    @Test("A name that is not a filename is refused rather than written somewhere else")
    func unsafeNames() throws {
        try withStore { store in
            #expect(throws: (any Error).self) {
                try store.save(self.record(handle: "../escape"))
            }
            #expect(throws: (any Error).self) {
                try store.save(self.record(handle: ".hidden"))
            }
            #expect(store.load(socketLabel: "workspaces", handle: "../escape") == nil)
        }
    }
}
