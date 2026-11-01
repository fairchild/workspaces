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
            workspacePath: "/tmp/a",
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
