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

    @Test("One claim on a conversation at a time, whatever case the id is spelled in, free again once released")
    func claimExcludes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-claims-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationRecordStore(directory: directory)
        let id = Self.conversationID

        let first = try await store.claim(id)
        await #expect(throws: ConversationRecordStore.ClaimError.held) {
            try await store.claim(id.uppercased(), timeout: .milliseconds(200))
        }
        // Another conversation is another claim.
        try await store.claim("fa08c461-2979-41db-85fb-b5c90c0d2d8c").release()
        first.release()
        try await store.claim(id, timeout: .seconds(5)).release()
    }

    @Test("A claim is only ever taken on something shaped like a conversation id")
    func claimRefusesAnotherName() async {
        let store = ConversationRecordStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("conversation-claims-\(UUID().uuidString)")
        )
        await #expect(throws: ConversationRecordStore.ClaimError.invalidConversationID) {
            try await store.claim("../../escape")
        }
    }

    @Test("A record with unknown fields keeps them through a rewrite, in kept sightings too")
    func unknownFieldsSurviveARewrite() throws {
        try withStore { store in
            try store.record(observation(at: 1_800_000_000, lastSeenIn: .init(hostSessionID: Self.tile.uuidString)))
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            var written = try object(at: url)
            written["fromANewerBuild"] = ["kept": true]
            var sightings = try #require(written["sightings"] as? [[String: Any]])
            sightings[0]["paneIndex"] = 2
            written["sightings"] = sightings
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
            #expect((rewritten["sightings"] as? [[String: Any]])?.first?["paneIndex"] as? Int == 2)
            #expect(store.load(conversationID: Self.conversationID)?.transcriptPath == "/tmp/t.jsonl")
        }
    }

    /// What the previous build (S4, acf18978) writes as `lastSeenIn`: its projection of the
    /// sightings, which knows the holder, the tmux session's id, server, creation time and
    /// name, and `outsideTmux`, and nothing this build adds.
    private static func previousBuildPlace(_ written: [String: Any]) -> [String: Any] {
        let seen = written["lastSeenIn"] as? [String: Any] ?? [:]
        var place: [String: Any] = [:]
        place["hostSessionID"] = seen["hostSessionID"]
        place["outsideTmux"] = seen["outsideTmux"]
        if let tmux = seen["tmux"] as? [String: Any] {
            place["tmux"] = tmux.filter { ["serverPID", "sessionID", "createdAt", "name"].contains($0.key) }
        }
        return place
    }

    private static var thisProcess: ProcessIdentity {
        get throws { try #require(ProcessInspector.live.identity(getpid())) }
    }

    /// The previous build keeps keys it does not know at the top level, rewrites the
    /// sightings by its own rules, and writes `lastSeenIn` without anything this build adds.
    @Test("A sighting elsewhere, written by this build or the previous one, takes no harness process away")
    func laterSightingElsewhereKeepsTheHarness() throws {
        let harness = try Self.thisProcess
        try withStore { store in
            var named = observation(at: 1_800_000_000, lastSeenIn: .init(hostSessionID: "tile-b", outsideTmux: true))
            named.harnessProcess = .named(harness)
            try store.record(named)
            try store.record(
                observation(at: 1_800_000_060, lastSeenIn: .init(hostSessionID: "tile-a", outsideTmux: true)))
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            var written = try object(at: url)
            written["lastSeenIn"] = Self.previousBuildPlace(written)
            written["sightings"] = [["hostSessionID": "tile-c", "observedAt": "2027-01-15T08:00:00.000Z"]]
            try JSONSerialization.data(withJSONObject: written).write(to: url)

            let record = try #require(store.load(conversationID: Self.conversationID))
            #expect(record.harnessProcesses.entries.map(\.process) == [harness])
            #expect(record.harnessProcesses.entries.first?.seenIn?.hostSessionID == "tile-b")
        }
    }

    /// A hook that found no claude above it records the processes it ran under, apart from
    /// the processes named; neither removes the other, and a chain leaves only once every
    /// process in it has exited.
    @Test("An unattributed chain and a named process stay side by side, and a chain leaves only when all of it has")
    func unattributedChainKeepsNamedProcesses() throws {
        let harness = try Self.thisProcess
        let gone = ProcessIdentity(pid: harness.pid, startedAtMicroseconds: harness.startedAtMicroseconds - 1)
        try withStore { store in
            var unnamed = observation(at: 1_800_000_000, lastSeenIn: .init(hostSessionID: nil, outsideTmux: true))
            unnamed.harnessProcess = .unnamed(chain: [gone, harness])
            var named = observation(at: 1_800_000_060, lastSeenIn: .init(hostSessionID: nil, outsideTmux: true))
            named.harnessProcess = .named(harness)
            try store.record(unnamed, ended: { _ in false })
            try store.record(named, ended: { _ in false })
            let both = try #require(store.load(conversationID: Self.conversationID)?.harnessProcesses)
            #expect(both.entries.map(\.process) == [harness])
            #expect(both.unattributed.map(\.chain) == [[gone, harness]])

            try store.record(observation(at: 1_800_000_120), ended: { $0 == gone })
            #expect(
                try #require(store.load(conversationID: Self.conversationID)).harnessProcesses.unattributed.map(\.chain)
                    == [[harness]])
            try store.record(observation(at: 1_800_000_180), ended: { _ in true })
            let after = try #require(store.load(conversationID: Self.conversationID)).harnessProcesses
            #expect(after.unattributed.isEmpty && after.entries.isEmpty)
        }
    }

    @Test("Chains from repeated hooks under one shell come down to one entry once their own shells exit")
    func repeatedChainsCollapse() throws {
        let shell = try Self.thisProcess
        let first = ProcessIdentity(pid: 101, startedAtMicroseconds: 1)
        let second = ProcessIdentity(pid: 102, startedAtMicroseconds: 1)
        try withStore { store in
            for (offset, hook) in [first, second].enumerated() {
                var unnamed = observation(at: 1_800_000_000 + Double(offset))
                unnamed.harnessProcess = .unnamed(chain: [hook, shell])
                try store.record(unnamed, ended: { _ in false })
            }
            #expect(
                try #require(store.load(conversationID: Self.conversationID)).harnessProcesses.unattributed.count == 2)

            try store.record(observation(at: 1_800_000_060), ended: { $0 != shell })
            let collapsed = try #require(store.load(conversationID: Self.conversationID)).harnessProcesses.unattributed
            #expect(collapsed.map(\.chain) == [[shell]])
            #expect(collapsed.first?.observedAt == Date(timeIntervalSince1970: 1_800_000_001))
        }
    }

    @Test("A harness process leaves the record once it has exited, and only then")
    func exitedHarnessProcessesLeave() throws {
        let running = try Self.thisProcess
        let exited = ProcessIdentity(pid: running.pid, startedAtMicroseconds: running.startedAtMicroseconds - 1)
        try withStore { store in
            for (offset, process) in [running, exited].enumerated() {
                var named = observation(at: 1_800_000_000 + Double(offset))
                named.harnessProcess = .named(process)
                try store.record(named, ended: { _ in false })
            }
            #expect(
                Set(
                    try #require(store.load(conversationID: Self.conversationID)).harnessProcesses.entries.map(
                        \.process))
                    == [running, exited])

            try store.record(observation(at: 1_800_000_060))
            let record = try #require(store.load(conversationID: Self.conversationID))
            #expect(record.harnessProcesses.entries.map(\.process) == [running])
        }
    }

    /// Ownership that is present but malformed may name a process that still runs the
    /// conversation, so it is never read as no ownership, and a write leaves it as it is.
    @Test(
        "Ownership present but malformed reads as damaged, and a later write keeps it",
        arguments: [
            "observedAt", "process", "entries", "chain", "harnessProcesses", "emptyChain", "emptyEntries",
            "emptyUnattributed", "emptyContainer",
        ]
    )
    func malformedOwnershipIsDamage(field: String) throws {
        try withStore { store in
            var named = observation(at: 1_800_000_000)
            named.harnessProcess = .named(try Self.thisProcess)
            try store.record(named, ended: { _ in false })
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            var object = try object(at: url)
            var processes = try #require(object["harnessProcesses"] as? [String: Any])
            var entries = try #require(processes["entries"] as? [[String: Any]])
            switch field {
            case "observedAt": entries[0]["observedAt"] = "invalid"
            case "process": entries[0]["process"] = "not-a-process"
            case "entries": processes["entries"] = "invalid"
            case "chain": processes["unattributed"] = [["chain": ["invalid"], "observedAt": entries[0]["observedAt"]!]]
            case "emptyChain": processes["unattributed"] = [["chain": [], "observedAt": entries[0]["observedAt"]!]]
            case "emptyEntries": processes["entries"] = []
            case "emptyUnattributed": processes["unattributed"] = []
            default: break
            }
            if field == "observedAt" || field == "process" { processes["entries"] = entries }
            switch field {
            case "harnessProcesses": object["harnessProcesses"] = "invalid"
            case "emptyContainer": object["harnessProcesses"] = [String: Any]()
            default: object["harnessProcesses"] = processes
            }
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            #expect(store.read(conversationID: Self.conversationID) == .damaged(url))

            try store.record(observation(at: 1_800_000_060), ended: { _ in true })
            #expect(store.read(conversationID: Self.conversationID) == .damaged(url))
            let kept = try self.object(at: url)["harnessProcesses"]
            #expect((kept as AnyObject?)?.isEqual(object["harnessProcesses"]) == true)
        }
    }

    @Test("The app's identity recorder leaves an empty chain, and the rest of the ownership, as it is")
    func identityRecorderKeepsAnEmptyChain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("records-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationRecordStore(directory: directory)
        try store.record(observation(at: 1_800_000_000))
        let url = try #require(store.fileURL(conversationID: Self.conversationID))
        var object = try object(at: url)
        let damaged: [String: Any] = [
            "unattributed": [["chain": [String](), "observedAt": "2027-01-15T08:00:00.000Z"]]
        ]
        object["harnessProcesses"] = damaged
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let identity = try #require(
            ConversationIdentityRecorder.HookIdentity.decode(
                from: Data(#"{"session_id":"\#(Self.conversationID)","cwd":"/tmp"}"#.utf8)))
        await ConversationIdentityRecorder(store: store).observe(identity, hostSessionID: UUID())

        #expect(store.read(conversationID: Self.conversationID) == .damaged(url))
        let kept = try self.object(at: url)["harnessProcesses"]
        #expect((kept as AnyObject?)?.isEqual(damaged) == true)
    }

    @Test("A hook's unresolved note keeps a name of its own beside the record, and a moved-aside copy reads first")
    func unresolvedNotes() throws {
        try withStore { store in
            let first = observation(at: 1_800_000_000)
            let incomplete = HookAncestry(claude: nil, passed: [try Self.thisProcess], complete: false)
            let one = try store.recordUnresolved(first, ancestry: incomplete)
            let two = try store.recordUnresolved(first, ancestry: incomplete)
            #expect(one != two)
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            #expect(one.lastPathComponent.hasPrefix(url.lastPathComponent + ".unresolved-1800000000-"))
            #expect(
                store.read(conversationID: Self.conversationID) == .unresolved(one.path < two.path ? one : two)
            )
            let note = try object(at: one)
            #expect(note["chain"] as? [String] == [try Self.thisProcess.recorded])
            #expect(note["complete"] as? Bool == false)

            try store.record(first)
            let aside = URL(fileURLWithPath: url.path + ".corrupt-1-abcdef12")
            try Data("[]".utf8).write(to: aside)
            #expect(store.read(conversationID: Self.conversationID) == .movedAside(aside))
        }
    }

    @Test("A write from another host removes none of the record's harness processes")
    func otherHostRemovesNoHarnessProcess() throws {
        try withStore { store in
            var named = observation(at: 1_800_000_000)
            named.harnessProcess = .named(try Self.thisProcess)
            try store.record(named, ended: { _ in false })

            var elsewhere = observation(at: 1_800_000_060)
            elsewhere.host = "other-host"
            try store.record(elsewhere, ended: { _ in true })
            #expect(
                try #require(store.load(conversationID: Self.conversationID)).harnessProcesses.entries.map(\.process)
                    == [try Self.thisProcess])
        }
    }

    @Test("A record that does not parse reads as damaged, not absent, and a writer that must not lose it leaves it")
    func damagedRecordIsNotAbsent() throws {
        try withStore { store in
            #expect(store.read(conversationID: Self.conversationID) == .absent)
            try store.record(observation(at: 1_800_000_000))
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            guard case .found = store.read(conversationID: Self.conversationID) else {
                Issue.record("expected the record")
                return
            }
            try Data("{ not json".utf8).write(to: url)
            #expect(store.read(conversationID: Self.conversationID) == .damaged(url))
            try Data(#"{"conversationID":"\#(Self.conversationID)"}"#.utf8).write(to: url)
            #expect(store.read(conversationID: Self.conversationID) == .damaged(url))

            try Data("{ not json".utf8).write(to: url)
            #expect(throws: ConversationRecordStore.WriteError.unreadableRecord) {
                try store.record(self.observation(at: 1_800_000_060), movingDamagedAside: false)
            }
            #expect(try Data(contentsOf: url) == Data("{ not json".utf8))
            #expect(
                try FileManager.default.contentsOfDirectory(atPath: store.directory.path).filter {
                    $0.contains("corrupt")
                }.isEmpty)
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

            #expect(store.all().map(\.conversationID) == [Self.conversationID])
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
            #expect(store.all().count == 1)
        }
    }

    @Test("Two damaged copies of one record in the same second are both kept")
    func twoCorruptionsInOneSecondKeepBoth() throws {
        try withStore { store in
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            let url = try #require(store.fileURL(conversationID: Self.conversationID))
            let damaged = [Data("{ first".utf8), Data("[\"second\"]".utf8)]
            for copy in damaged {
                try copy.write(to: url)
                try store.record(observation(at: 1_800_000_000))
            }

            let asides = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
                .filter { $0.hasPrefix("\(Self.conversationID).json.corrupt-") }
            let kept = try Set(asides.map { try Data(contentsOf: store.directory.appendingPathComponent($0)) })
            #expect(kept == Set(damaged))
            #expect(store.all().count == 1)
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
            var sightings = try #require(written["sightings"] as? [[String: Any]])
            sightings[0]["paneIndex"] = 2
            written["sightings"] = sightings
            try JSONSerialization.data(withJSONObject: written).write(to: url)

            let elsewhere = UUID().uuidString
            try store.record(observation(at: 1_800_000_020, by: .app, lastSeenIn: .init(hostSessionID: elsewhere)))
            let rewritten = try object(at: url)
            let place = try #require(rewritten["lastSeenIn"] as? [String: Any])
            #expect(place.keys.sorted() == ["hostSessionID"])
            #expect(place["hostSessionID"] as? String == elsewhere)
            #expect((rewritten["sightings"] as? [[String: Any]])?.count == 1)
            #expect((rewritten["sightings"] as? [[String: Any]])?.first?["paneIndex"] == nil)
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
            #expect(store.all().count == 1)
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
