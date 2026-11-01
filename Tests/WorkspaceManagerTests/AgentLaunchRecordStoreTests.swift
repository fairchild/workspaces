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
        processListing: String? = "",
        transcriptExists: Bool = true
    ) -> String? {
        store.resumeCommand(
            socketLabel: "workspaces",
            tmuxSessionName: "wm-a-1",
            processListing: processListing,
            resumability: ClaudeTranscriptResumability(
                environment: [:],
                homeDirectory: URL(fileURLWithPath: "/tmp/no-such-home"),
                fileExists: { _ in transcriptExists }
            )
        )
    }

    @Test("A recorded conversation with a transcript and no holder can be continued")
    func resumeCommandForARecordedConversation() throws {
        try withStore { store in
            try store.save(record())
            #expect(
                resumeCommand(store: store)
                    == "claude --resume fa08c461-2979-41db-85fb-b5c90c0d2d8b --effort xhigh"
            )
        }
    }

    @Test("Nothing is offered for a conversation something still holds")
    func resumeCommandSkipsAHeldConversation() throws {
        try withStore { store in
            try store.save(record())
            let listing = "00:10 claude --resume fa08c461-2979-41db-85fb-b5c90c0d2d8b"
            #expect(resumeCommand(store: store, processListing: listing) == nil)
            // No process table means a second writer cannot be ruled out.
            #expect(resumeCommand(store: store, processListing: nil) == nil)
        }
    }

    @Test("Nothing is offered without a transcript, a record, or a named conversation")
    func resumeCommandNeedsAConversation() throws {
        try withStore { store in
            #expect(resumeCommand(store: store) == nil)

            try store.save(record())
            #expect(resumeCommand(store: store, transcriptExists: false) == nil)

            try store.save(
                AgentLaunchRecord(
                    handle: "wm-a-1",
                    workspacePath: "/tmp/a",
                    socketLabel: "workspaces",
                    launchedAt: Date(),
                    identity: nil
                )
            )
            #expect(resumeCommand(store: store) == nil)
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

    @Test("One claim on a conversation at a time, free again once released")
    func conversationLockExcludes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-locks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentLaunchRecordStore(directory: directory)
        let id = "fa08c461-2979-41db-85fb-b5c90c0d2d8b"

        let first = try await store.lockConversation(id)
        await #expect(throws: AgentLaunchRecordStore.LockError.self) {
            try await store.lockConversation(id, timeout: .milliseconds(200))
        }
        // Another conversation is another lock.
        try await store.lockConversation("fa08c461-2979-41db-85fb-b5c90c0d2d8c").release()
        first.release()
        try await store.lockConversation(id, timeout: .seconds(5)).release()
    }

    @Test("A lock is only ever taken on something shaped like a conversation id")
    func conversationLockRefusesAnotherName() async {
        let store = AgentLaunchRecordStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("launch-locks-\(UUID().uuidString)")
        )
        await #expect(throws: CocoaError.self) {
            try await store.lockConversation("../../escape")
        }
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
