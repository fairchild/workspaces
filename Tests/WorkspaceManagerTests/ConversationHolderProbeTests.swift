//
//  ConversationHolderProbeTests.swift
//  WorkspaceManagerTests
//
//  Which processes hold a conversation, by each of Claude's three rules, and when the probe
//  has to say it cannot tell. Every process and every tmux answer is injected; the end-to-end
//  versions with a real binary and a real tmux server are in CLIConversationResumeTests.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("Conversation holder probe")
struct ConversationHolderProbeTests {
    private static let id = "fa08c461-2979-41db-85fb-b5c90c0d2d8b"
    private static let other = "0b5e2a71-9c4d-4f1e-8a3b-2d6c7e8f9a0b"

    private static func record(
        _ id: String = id,
        lastSeenIn: ConversationRecord.LastSeenIn? = nil,
        socketLabel: String? = nil
    ) -> ConversationRecord {
        ConversationRecord(
            schema: 1, harness: "claude", conversationID: id, host: "h", cwd: "/", configHome: nil,
            transcriptPath: nil, workspacePath: nil, workspaceCreatedAt: nil, socketLabel: socketLabel,
            createdAt: Date(), observedAt: Date(), observedBy: .hook, launch: nil, lastSeenIn: lastSeenIn,
            endedByUserAt: nil)
    }

    /// Processes that exist with the given start times and arguments, and nothing else.
    private static func inspector(_ processes: [Int32: (Int64, [String])]) -> ProcessInspector {
        ProcessInspector(
            identity: { pid in processes[pid].map { ProcessIdentity(pid: pid, startedAtMicroseconds: $0.0) } },
            parent: { _ in nil },
            arguments: { pid in processes[pid]?.1 }
        )
    }

    private static func context(
        _ table: ProcessTable,
        inspector: ProcessInspector = .none,
        recordedSession: RecordedTmuxSession? = .notRecorded,
        current: [ProcessIdentity: String] = [:]
    ) -> HolderProbeContext {
        HolderProbeContext(
            processTable: table,
            inspector: inspector,
            recordedSession: { _ in recordedSession },
            currentConversation: { current[$0] }
        )
    }

    private static func table(_ listing: String) throws -> ProcessTable {
        try #require(ProcessTable(listing: listing))
    }

    private static func argumentHolders(_ listing: String) async throws -> [Int32] {
        let probe = await ClaudeHarnessAdapter().holders(of: record(), in: context(try table(listing)))
        guard case .held(let holders, _) = probe else { return [] }
        #expect(holders.allSatisfy { $0.foundBy == .arguments })
        return holders.map(\.pid)
    }

    // MARK: - The argument rule

    @Test("Only the agent that holds the conversation counts as a process")
    func holders() async throws {
        let id = Self.id
        let listing = """
              300   1 /Users/me/.local/bin/claude --model claude-opus-5-5 --session-id \(id) hello
              301   1 /bin/zsh -lc claude --model claude-opus-5-5 --session-id \(id) hello
              302   1 tmux -L workspaces new-session -d -s x -- /bin/zsh -lc claude --session-id \(id)
              303   1 /bin/bash /hooks/forwarder.sh --session-id \(id)
              304   1 claude --model claude-opus-5-5 mentions \(id) in its prompt
             3630   1 /bin/sh /tmp/fixture/bin/claude --resume \(id) --effort low
              305   1 claude --session-id 00000000-0000-0000-0000-000000000000
            """
        #expect(try await Self.argumentHolders(listing) == [300, 3630])
    }

    @Test("A flag joined to its value holds the conversation like one apart from it")
    func joinedFlags() async throws {
        let listing = """
                5   1 claude --session-id=\(Self.id)
                6   1 claude --resume=\(Self.id)
            """
        #expect(try await Self.argumentHolders(listing) == [5, 6])
    }

    @Test("Claude run by an interpreter is a holder, under either name it installs as")
    func interpreterLayouts() async throws {
        let listing = """
                5   1 node /opt/homebrew/bin/claude --resume \(Self.id)
                6   1 node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume \(Self.id)
            """
        #expect(try await Self.argumentHolders(listing) == [5, 6])
    }

    @Test("A conversation id past `--` is a prompt, and a program merely naming claude holds nothing")
    func notHolders() async throws {
        let id = Self.id
        let listing = """
                5   1 claude -- --resume \(id)
                6   1 claude --session-id 00000000-0000-0000-0000-000000000000 -- see --resume=\(id)
                7   1 tmux -L workspaces new-session -d -s wm-a-1 claude --session-id \(id)
                8   1 tail -f /tmp/\(id).jsonl
                9   1 /usr/local/bin/claude
            """
        #expect(try await Self.argumentHolders(listing).isEmpty)
    }

    @Test("A short flag names a conversation too")
    func shortFlag() async throws {
        #expect(try await Self.argumentHolders("9 1 claude -r \(Self.id)") == [9])
    }

    @Test("A process whose arguments name the conversation but whose newest sighting is another one holds the other")
    func argumentsAfterAClear() async throws {
        let harness = ProcessIdentity(pid: 50, startedAtMicroseconds: 7)
        let table = try Self.table("50 1 claude --resume \(Self.id)")
        let inspector = Self.inspector([50: (7, ["claude", "--resume", Self.id])])

        let moved = await ClaudeHarnessAdapter().holders(
            of: Self.record(), in: Self.context(table, inspector: inspector, current: [harness: Self.other]))
        #expect(moved == .free)

        let stayed = await ClaudeHarnessAdapter().holders(
            of: Self.record(), in: Self.context(table, inspector: inspector, current: [harness: Self.id]))
        #expect(
            stayed
                == .held(
                    [.init(pid: 50, foundBy: .arguments, startedAt: harness.startedAt)], recordedSessionGone: false))
    }

    // MARK: - The recorded harness

    @Test("The process the hook recorded holds the conversation while it lives as the same claude")
    func recordedHarnessHolds() async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let tile = UUID().uuidString
        let record = Self.record(
            lastSeenIn: .init(hostSessionID: tile, outsideTmux: true, harness: harness, harnessObservedAt: Date()))
        let table = try Self.table("60 1 /usr/local/bin/claude")
        let alive = Self.inspector([60: (1_000, ["/usr/local/bin/claude"])])

        let probe = await ClaudeHarnessAdapter().holders(
            of: record, in: Self.context(table, inspector: alive, current: [harness: Self.id]))
        #expect(
            probe
                == .held(
                    [.init(pid: 60, foundBy: .recordedHarness, startedAt: harness.startedAt, hostSessionID: tile)],
                    recordedSessionGone: false))
        guard case .held(let holders, _) = probe else { return }
        #expect(!holders[0].placeDescription.contains("may have switched"))
    }

    @Test(
        "A recorded harness that ended, gave its pid away, or moved to another conversation holds nothing",
        arguments: ["ended", "reused", "not-claude", "moved"]
    )
    func recordedHarnessReleases(change: String) async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let record = Self.record(
            lastSeenIn: .init(hostSessionID: nil, outsideTmux: true, harness: harness, harnessObservedAt: Date()))
        let processes: [Int32: (Int64, [String])] =
            switch change {
            case "ended": [:]
            case "reused": [60: (2_000, ["/usr/local/bin/claude"])]
            case "not-claude": [60: (1_000, ["/bin/zsh"])]
            default: [60: (1_000, ["/usr/local/bin/claude"])]
            }
        let listing = processes[60].map { "60 1 \($0.1.joined(separator: " "))" } ?? "1 0 /sbin/launchd"
        let current: [ProcessIdentity: String] = change == "moved" ? [harness: Self.other] : [harness: Self.id]

        let probe = await ClaudeHarnessAdapter().holders(
            of: record,
            in: Self.context(try Self.table(listing), inspector: Self.inspector(processes), current: current))
        #expect(probe == .free)
    }

    @Test("With a recorded harness, the session's other panes are not asked about, and a silent server does not refuse")
    func recordedHarnessSkipsThePaneTree() async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let record = Self.record(
            lastSeenIn: .init(
                hostSessionID: nil, tmux: .init(serverPID: 4242, sessionID: "$7"), harness: harness,
                harnessObservedAt: Date()))
        let table = try Self.table(
            """
              100   1 -zsh
              101 100 /usr/local/bin/claude
            """)

        let probe = await ClaudeHarnessAdapter().holders(
            of: record, in: Self.context(table, inspector: Self.inspector([:]), recordedSession: nil))
        #expect(probe == .free)
    }

    // MARK: - The pane tree, for records from before hooks named their process

    @Test("A record from before hooks named their process refuses when its tmux server cannot be asked")
    func paneTreeUnknownRefuses() async throws {
        let record = Self.record(lastSeenIn: .init(hostSessionID: nil, tmux: .init(serverPID: 4242, sessionID: "$7")))
        let probe = await ClaudeHarnessAdapter().holders(
            of: record, in: Self.context(try Self.table("1 0 /sbin/launchd"), recordedSession: nil))
        guard case .unknown = probe else {
            Issue.record("expected unknown, got \(probe)")
            return
        }
    }

    // MARK: - The recorded tmux session

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String]] = []
        var all: [[String]] { lock.withLock { stored } }
        func append(_ arguments: [String]) { lock.withLock { stored.append(arguments) } }
    }

    /// A tmux that answers `list-sessions` and `list-panes` with the given output, or not at all.
    private static func lookup(
        sessions: String?,
        panes: String? = nil,
        server: (Int32, Int64)? = (4242, 9_000),
        calls: Calls = Calls()
    ) -> @Sendable (ConversationRecord) async -> RecordedTmuxSession? {
        let processes: [Int32: (Int64, [String])] = server.map { [$0.0: ($0.1, ["tmux"])] } ?? [:]
        return ConversationHolderProbe.tmuxRecordedSession(
            fallbackSocketLabel: "fallback",
            run: { _, arguments, _ in
                calls.append(arguments)
                let output = arguments.contains("list-sessions") ? sessions : panes
                return output.map { ProcessResult(exitCode: 0, stdout: $0, stderr: "") }
            },
            environment: [:],
            inspector: inspector(processes)
        )
    }

    private static let created = Date(timeIntervalSince1970: 1_700_000_000)
    private static let tmux = ConversationRecord.TmuxSession(
        serverPID: 4242, sessionID: "$3", createdAt: created, name: "wm-a", socketPath: "/tmp/other-tmpdir/tmux-501/x",
        serverStartedAtMicroseconds: 9_000)

    private static func tmuxRecord(_ tmux: ConversationRecord.TmuxSession = tmux) -> ConversationRecord {
        record(lastSeenIn: .init(hostSessionID: nil, tmux: tmux), socketLabel: "label")
    }

    @Test("The recorded server is asked at its socket path, with tabs kept whatever the locale")
    func asksTheRecordedSocket() async {
        let calls = Calls()
        let found = await Self.lookup(
            sessions: "4242\t$3\t1700000000\n4242\t$4\t1700000100\n",
            panes: "$3\t555\twm-a\n$3\t556\twm-a\n",
            calls: calls
        )(Self.tmuxRecord())
        #expect(found == .live(sessionID: "$3", name: "wm-a", panePIDs: [555, 556]))
        #expect(calls.all.allSatisfy { Array($0.prefix(4)) == ["tmux", "-u", "-S", "/tmp/other-tmpdir/tmux-501/x"] })
    }

    @Test("A record with no socket path asks by its label")
    func asksByLabel() async {
        var tmux = Self.tmux
        tmux.socketPath = nil
        let calls = Calls()
        _ = await Self.lookup(sessions: "4242\t$3\t1700000000\n", panes: "$3\t555\twm-a\n", calls: calls)(
            Self.tmuxRecord(tmux))
        #expect(calls.all.first.map { Array($0.prefix(4)) } == ["tmux", "-u", "-L", "label"])
    }

    @Test(
        "Gone is only ever a positive answer: a dead server, a later process on its pid, or a session it says is not there"
    )
    func goneIsPositive() async {
        #expect(await Self.lookup(sessions: nil, server: nil)(Self.tmuxRecord()) == .gone)
        #expect(await Self.lookup(sessions: nil, server: (4242, 9_999))(Self.tmuxRecord()) == .gone)
        #expect(await Self.lookup(sessions: "4242\t$4\t1700000100\n")(Self.tmuxRecord()) == .gone)
        #expect(await Self.lookup(sessions: "4242\t$3\t1700000999\n")(Self.tmuxRecord()) == .gone)
    }

    @Test("A live server that does not answer, or answers in a shape that does not parse, is unknown")
    func unreachableIsUnknown() async {
        #expect(await Self.lookup(sessions: nil)(Self.tmuxRecord()) == nil)
        // Without a UTF-8 locale and without -u, tmux prints each tab as `_`.
        #expect(await Self.lookup(sessions: "4242_$3_1700000000\n")(Self.tmuxRecord()) == nil)
        #expect(await Self.lookup(sessions: "9999\t$3\t1700000000\n")(Self.tmuxRecord()) == nil)
        #expect(await Self.lookup(sessions: "4242\t$3\t1700000000\n", panes: nil)(Self.tmuxRecord()) == nil)
        #expect(await Self.lookup(sessions: "4242\t$3\t1700000000\n", panes: "$3_555_wm-a\n")(Self.tmuxRecord()) == nil)
    }

    @Test("A record from before server start times were kept trusts a server only if it started before the session")
    func olderRecordsJudgeTheServerBySessionTime() async {
        var tmux = Self.tmux
        tmux.serverStartedAtMicroseconds = nil
        let before = Int64(Self.created.timeIntervalSince1970 - 5) * 1_000_000
        let after = Int64(Self.created.timeIntervalSince1970 + 5) * 1_000_000
        let answer = "4242\t$3\t1700000000\n"
        #expect(
            await Self.lookup(sessions: answer, panes: "$3\t555\twm-a\n", server: (4242, before))(Self.tmuxRecord(tmux))
                == .live(sessionID: "$3", name: "wm-a", panePIDs: [555]))
        #expect(await Self.lookup(sessions: answer, server: (4242, after))(Self.tmuxRecord(tmux)) == .gone)
    }

    // MARK: - The probe entrypoint

    @Test("An unreadable process table is unknown, whatever the record says")
    func unreadableTableIsUnknown() async {
        let probe = ConversationHolderProbe(
            records: nil, readProcessTable: { nil }, inspector: .none, recordedSession: { _ in .notRecorded })
        #expect(await probe.probe(Self.record()) == .unknown("Could not read the process table"))
    }

    @Test("A process's current conversation is the one whose record saw it last")
    func currentConversationIsTheNewestSighting() {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let earlier = Self.record(
            Self.id,
            lastSeenIn: .init(
                hostSessionID: nil, outsideTmux: true, harness: harness,
                harnessObservedAt: Date(timeIntervalSince1970: 100)))
        let later = Self.record(
            Self.other,
            lastSeenIn: .init(
                hostSessionID: nil, outsideTmux: true, harness: harness,
                harnessObservedAt: Date(timeIntervalSince1970: 200)))
        #expect(ConversationHolderProbe.currentConversation(of: harness, in: [earlier, later]) == Self.other)
        #expect(ConversationHolderProbe.currentConversation(of: harness, in: [later, earlier]) == Self.other)
        #expect(
            ConversationHolderProbe.currentConversation(
                of: ProcessIdentity(pid: 60, startedAtMicroseconds: 2_000), in: [earlier, later]) == nil)
    }

    // MARK: - The adapter's other answers

    @Test("Claude's conversations get records from its hook, and a launch can name the id up front")
    func identityAndLaunch() throws {
        let adapter = ClaudeHarnessAdapter()
        #expect(adapter.identitySource == .hook)
        let command = try #require(adapter.launchCommand(conversationID: Self.id.uppercased()))
        #expect(AgentLaunchCommand.plan(command: command).identity?.conversationID == Self.id)
        #expect(adapter.launchCommand(conversationID: "not-an-id") == nil)
    }

    @Test("The process table reads ps output and walks a pane's descendants")
    func processTableWalksDescendants() throws {
        let table = try Self.table(
            """
                  1     0 /sbin/launchd
                100     1 -zsh
                101   100 /bin/sh /opt/bin/claude --resume x
                102   101 sleep 1
                200     1 other
            """)
        #expect(table.rows.count == 5)
        #expect(Set(table.descendants(of: [100]).map(\.pid)) == [100, 101, 102])
    }
}
