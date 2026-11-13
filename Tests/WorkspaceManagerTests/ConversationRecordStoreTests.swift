//
//  ConversationRecordStoreTests.swift
//  WorkspaceManagerTests
//
//  Conversation records are written by several processes and builds that never coordinate
//  except through the file and its lock, so these pin what each write keeps, what it drops,
//  and what a reader skips.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Conversation record store")
struct ConversationRecordStoreTests {
    private static let conversationID = "fa08c461-2979-41db-85fb-b5c90c0d2d8b"
    private static let tile = UUID(uuidString: "2D4D6044-1E11-49C9-9CB0-A1D7B9F44E31")!

    private func withStore(_ body: (ConversationRecordStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-records-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ConversationRecordStore(directory: directory))
    }

    private func observation(
        at seconds: TimeInterval,
        by observer: ConversationObserver = .hook,
        cwd: String? = "/tmp/repo",
        transcriptPath: String? = nil,
        lastSeenIn: ConversationRecord.LastSeenIn? = nil
    ) -> ConversationObservation {
        ConversationObservation(
            conversationID: Self.conversationID,
            host: "test-host",
            cwd: cwd,
            transcriptPath: transcriptPath,
            observedAt: Date(timeIntervalSince1970: seconds),
            observedBy: observer,
            lastSeenIn: lastSeenIn
        )
    }

    private func object(at url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test("A record with unknown fields keeps them through a rewrite")
    func unknownFieldsSurviveARewrite() throws {
        try withStore { store in
            try store.record(observation(at: 1_800_000_000, lastSeenIn: .init(hostSessionID: Self.tile.uuidString)))
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            var written = try object(at: url)
            written["fromANewerBuild"] = ["kept": true]
            var place = try #require(written["lastSeenIn"] as? [String: Any])
            place["paneIndex"] = 2
            written["lastSeenIn"] = place
            try JSONSerialization.data(withJSONObject: written).write(to: url)

            try store.record(
                observation(
                    at: 1_800_000_060,
                    transcriptPath: "/tmp/t.jsonl",
                    lastSeenIn: .init(hostSessionID: Self.tile.uuidString)
                )
            )

            let rewritten = try object(at: url)
            #expect((rewritten["fromANewerBuild"] as? [String: Any])?["kept"] as? Bool == true)
            #expect((rewritten["lastSeenIn"] as? [String: Any])?["paneIndex"] as? Int == 2)
            #expect(store.load(conversationID: Self.conversationID)?.transcriptPath == "/tmp/t.jsonl")
        }
    }

    @Test("An unreadable record is skipped")
    func unreadableRecordIsSkipped() throws {
        try withStore { store in
            try store.record(observation(at: 1_800_000_000))
            let broken = "0b7c51b7-6a40-4c48-9d27-4c3f0e2f4b11"
            try Data("{ not json".utf8).write(to: store.directory.appendingPathComponent("\(broken).json"))
            try Data(#"{"harness":"claude"}"#.utf8).write(
                to: store.directory.appendingPathComponent("9a1c4c1e-3b0b-4d55-9e7e-7f2f8e1c0a22.json")
            )
            try Data("{}".utf8).write(to: store.directory.appendingPathComponent("not-a-conversation.json"))

            #expect(store.files().map(\.record.conversationID) == [Self.conversationID])
            #expect(store.load(conversationID: broken) == nil)
        }
    }

    @Test("A record that exists but cannot be read is left as it was, and the write throws")
    func unreadableRecordIsNotOverwritten() throws {
        try withStore { store in
            try store.record(observation(at: 1_800_000_000, transcriptPath: "/tmp/t.jsonl"))
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            let before = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

            #expect(throws: ConversationRecordStore.WriteError.unreadableRecord) {
                try store.record(self.observation(at: 1_800_000_060))
            }

            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test("A record that is not a JSON object is moved aside and the write starts a fresh one")
    func malformedRecordIsKeptAside() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            let garbage = Data("{ half a record".utf8)
            try garbage.write(to: url)

            try store.record(observation(at: 1_800_000_000))

            let fresh = store.load(conversationID: Self.conversationID)
            #expect(fresh?.observedAt == Date(timeIntervalSince1970: 1_800_000_000))
            let aside = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
                .filter { $0.hasPrefix("\(Self.conversationID).json.corrupt-") }
            #expect(aside.count == 1)
            #expect(try Data(contentsOf: store.directory.appendingPathComponent(aside[0])) == garbage)
            #expect(store.files().count == 1)
        }
    }

    @Test("An older sighting fills only what the record lacks, and observedAt never moves back")
    func olderSightingOnlyFills() throws {
        try withStore { store in
            try store.record(
                observation(
                    at: 1_800_000_100,
                    cwd: "/tmp/now",
                    lastSeenIn: .init(hostSessionID: Self.tile.uuidString)
                )
            )
            try store.record(
                observation(
                    at: 1_800_000_000,
                    by: .migration,
                    cwd: "/tmp/then",
                    transcriptPath: "/tmp/t.jsonl",
                    lastSeenIn: .init(hostSessionID: UUID().uuidString)
                )
            )

            let record = try #require(store.load(conversationID: Self.conversationID))
            #expect(record.cwd == "/tmp/now")
            #expect(record.observedBy == .hook)
            #expect(record.observedAt == Date(timeIntervalSince1970: 1_800_000_100))
            #expect(record.createdAt == Date(timeIntervalSince1970: 1_800_000_000))
            #expect(record.transcriptPath == "/tmp/t.jsonl")
            #expect(record.lastSeenIn?.hostSessionID == Self.tile.uuidString)
        }
    }

    @Test("A sighting in another tile replaces the old place, and the same tile keeps its tmux session")
    func lastSeenInFollowsTheTile() throws {
        try withStore { store in
            let tmux = ConversationRecord.TmuxSession(serverPID: 4242, sessionID: "$3", name: "wm-repo-1")
            try store.record(
                observation(at: 1_800_000_000, lastSeenIn: .init(hostSessionID: Self.tile.uuidString, tmux: tmux)))
            try store.record(
                observation(at: 1_800_000_010, by: .app, lastSeenIn: .init(hostSessionID: Self.tile.uuidString)))
            #expect(store.load(conversationID: Self.conversationID)?.lastSeenIn?.tmux == tmux)

            let elsewhere = UUID().uuidString
            try store.record(observation(at: 1_800_000_020, by: .app, lastSeenIn: .init(hostSessionID: elsewhere)))
            #expect(
                store.load(conversationID: Self.conversationID)?.lastSeenIn
                    == ConversationRecord.LastSeenIn(hostSessionID: elsewhere)
            )
        }
    }

    /// The SessionStart observer dates its sighting before it asks tmux where it is, so the
    /// app's tmux-less sighting of the same tile can land first with a later date.
    @Test("An older sighting from the same tile fills a missing tmux session, and never replaces a known one")
    func olderSameTileSightingFillsTmux() throws {
        try withStore { store in
            let tile = Self.tile.uuidString
            let hooked = ConversationRecord.TmuxSession(
                serverPID: 4242, sessionID: "$3", createdAt: Date(timeIntervalSince1970: 1_799_999_000),
                name: "wm-repo-1")
            try store.record(observation(at: 1_800_000_010, by: .app, lastSeenIn: .init(hostSessionID: tile)))
            try store.record(observation(at: 1_800_000_000, lastSeenIn: .init(hostSessionID: tile, tmux: hooked)))
            #expect(store.load(conversationID: Self.conversationID)?.lastSeenIn?.tmux == hooked)

            let stale = ConversationRecord.TmuxSession(serverPID: 999, sessionID: "$1", name: "wm-old")
            try store.record(observation(at: 1_799_999_500, lastSeenIn: .init(hostSessionID: tile, tmux: stale)))
            #expect(store.load(conversationID: Self.conversationID)?.lastSeenIn?.tmux == hooked)
            #expect(store.load(conversationID: Self.conversationID)?.observedBy == .app)
        }
    }

    @Test("A new holder takes no tmux session or location keys from the old one")
    func newHolderInheritsNoLocation() throws {
        try withStore { store in
            let tmux = ConversationRecord.TmuxSession(serverPID: 4242, sessionID: "$3", name: "wm-repo-1")
            try store.record(
                observation(at: 1_800_000_000, lastSeenIn: .init(hostSessionID: Self.tile.uuidString, tmux: tmux)))
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            var written = try object(at: url)
            var place = try #require(written["lastSeenIn"] as? [String: Any])
            var session = try #require(place["tmux"] as? [String: Any])
            session["windowIndex"] = 1
            place["tmux"] = session
            place["paneIndex"] = 2
            written["lastSeenIn"] = place
            try JSONSerialization.data(withJSONObject: written).write(to: url)

            let moved = ConversationRecord.TmuxSession(serverPID: 4242, sessionID: "$9")
            try store.record(
                observation(at: 1_800_000_010, lastSeenIn: .init(hostSessionID: Self.tile.uuidString, tmux: moved)))
            let sameTile = try #require(try object(at: url)["lastSeenIn"] as? [String: Any])
            #expect(sameTile["paneIndex"] as? Int == 2)
            #expect((sameTile["tmux"] as? [String: Any])?["windowIndex"] == nil)
            #expect((sameTile["tmux"] as? [String: Any])?["name"] == nil)

            let elsewhere = UUID().uuidString
            try store.record(observation(at: 1_800_000_020, by: .app, lastSeenIn: .init(hostSessionID: elsewhere)))
            let otherTile = try #require(try object(at: url)["lastSeenIn"] as? [String: Any])
            #expect(otherTile.keys.sorted() == ["hostSessionID"])
            #expect(otherTile["hostSessionID"] as? String == elsewhere)
        }
    }

    @Test("A write that cannot take the record's lock is dropped within its budget")
    func lostLockDropsTheWrite() throws {
        try withStore { store in
            let locks = store.directory.appendingPathComponent(".locks")
            try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
            let holder = open(
                locks.appendingPathComponent("\(Self.conversationID).write").path, O_CREAT | O_RDWR, 0o600)
            #expect(holder >= 0)
            defer { close(holder) }
            #expect(flock(holder, LOCK_EX | LOCK_NB) == 0)

            #expect(try store.record(observation(at: 1_800_000_000), lockBudget: .milliseconds(20)) == .lockBusy)
            #expect(store.load(conversationID: Self.conversationID) == nil)
        }
    }

    @Test("Records are private to their owner from the moment they exist")
    func recordsArePrivate() throws {
        try withStore { store in
            try store.record(observation(at: 1_800_000_000))
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            func mode(_ path: String) throws -> Int {
                try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
            }
            #expect(try mode(store.directory.path) == 0o700)
            #expect(try mode(store.directory.appendingPathComponent(".locks").path) == 0o700)
            #expect(try mode(url.path) == 0o600)
        }
    }

    @Test("Two spellings of one id are one record")
    func idSpellingIsNormalized() throws {
        try withStore { store in
            var shouting = observation(at: 1_800_000_000)
            shouting.conversationID = Self.conversationID.uppercased()
            try store.record(shouting)
            try store.record(observation(at: 1_800_000_010))
            #expect(store.files().count == 1)
            #expect(store.load(conversationID: Self.conversationID.uppercased())?.conversationID == Self.conversationID)
        }
    }

    @Test("The records directory follows the explicit key, then the CLI config directory")
    func directoryResolution() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(
            ConversationRecordStore.resolvedDirectory(
                environment: ["WORKSPACES_CONVERSATIONS_DIR": "/tmp/lane/conversations", "XDG_CONFIG_HOME": "/tmp/x"],
                homeDirectory: home
            ).path == "/tmp/lane/conversations"
        )
        #expect(
            ConversationRecordStore.resolvedDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/x"], homeDirectory: home)
                .path
                == "/tmp/x/workspaces-cli/conversations"
        )
        #expect(
            ConversationRecordStore.resolvedDirectory(environment: [:], homeDirectory: home).path
                == "/Users/someone/.config/workspaces-cli/conversations"
        )
    }
}
