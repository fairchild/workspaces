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

    /// A record last seen at `lastSeenIn`, whose hook named `harness` there, then, when
    /// `unnamed`, ran again and could not name its claude.
    private static func record(
        lastSeenIn: ConversationRecord.LastSeenIn? = nil,
        harness: ProcessIdentity? = nil,
        unnamed: Bool = false,
        socketLabel: String? = nil
    ) -> ConversationRecord {
        let named = Date(timeIntervalSince1970: 100)
        return ConversationRecord(
            schema: 1, harness: "claude", conversationID: id, host: "h", cwd: "/", configHome: nil,
            transcriptPath: nil, workspacePath: nil, workspaceCreatedAt: nil, socketLabel: socketLabel,
            createdAt: Date(), observedAt: Date(), observedBy: .hook, launch: nil, lastSeenIn: lastSeenIn,
            endedByUserAt: nil,
            harnessProcesses: .init(
                entries: harness.map { [.init(process: $0, observedAt: named, seenIn: lastSeenIn)] } ?? [],
                namedAt: harness.map { _ in named }, unnamedAt: unnamed ? Date(timeIntervalSince1970: 200) : nil))
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
        recordedSession: RecordedTmuxSession? = nil
    ) -> HolderProbeContext {
        HolderProbeContext(
            processTable: table,
            inspector: inspector,
            recordedSession: { _ in recordedSession }
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
                7   1 node --no-warnings /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js --resume \(Self.id)
                8   1 /usr/bin/env node --no-warnings /opt/lib/claude-code/cli.js --resume \(Self.id)
                9   1 env -u CLAUDECODE NODE_OPTIONS=x node --require /opt/hook.js /opt/claude-code/cli.js -r \(Self.id)
               10   1 bun /opt/bin/claude --resume \(Self.id)
            """
        #expect(try await Self.argumentHolders(listing) == [5, 6, 7, 8, 9, 10])
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

    // MARK: - The recorded harness

    @Test("The process the hook recorded holds the conversation while it lives as the same claude")
    func recordedHarnessHolds() async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let tile = UUID().uuidString
        let record = Self.record(
            lastSeenIn: .init(hostSessionID: tile, outsideTmux: true), harness: harness)
        let table = try Self.table("60 1 /usr/local/bin/claude")
        let alive = Self.inspector([60: (1_000, ["/usr/local/bin/claude"])])

        let probe = await ClaudeHarnessAdapter().holders(
            of: record, in: Self.context(table, inspector: alive))
        #expect(
            probe
                == .held(
                    [.init(pid: 60, foundBy: .recordedHarness, startedAt: harness.startedAt, hostSessionID: tile)],
                    recordedSessionGone: false))
        guard case .held(let holders, _) = probe else { return }
        #expect(holders[0].placeDescription.contains("may have moved to another one"))
    }

    @Test(
        "A recorded harness that ended or gave its pid away holds nothing",
        arguments: ["ended", "reused"]
    )
    func recordedHarnessReleases(change: String) async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let record = Self.record(
            lastSeenIn: .init(hostSessionID: nil, outsideTmux: true), harness: harness)
        let processes: [Int32: (Int64, [String])] =
            switch change {
            case "ended": [:]
            default: [60: (2_000, ["/usr/local/bin/claude"])]
            }
        let listing = processes[60].map { "60 1 \($0.1.joined(separator: " "))" } ?? "1 0 /sbin/launchd"

        let probe = await ClaudeHarnessAdapter().holders(
            of: record,
            in: Self.context(try Self.table(listing), inspector: Self.inspector(processes)))
        #expect(probe == .free)
    }

    /// A harness started through a wrapper or a runtime execs in place: the recorded process
    /// is the harness for the rest of its life, whatever its arguments come to say.
    @Test("A recorded process holds the conversation whatever its arguments say")
    func recordedHarnessIgnoresArguments() async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let record = Self.record(
            lastSeenIn: .init(hostSessionID: nil, outsideTmux: true), harness: harness)
        let arguments = ["/bin/sh", "/opt/bin/node", "--no-warnings", "/opt/lib/wrapper.js"]
        let probe = await ClaudeHarnessAdapter().holders(
            of: record,
            in: Self.context(
                try Self.table("60 1 \(arguments.joined(separator: " "))"),
                inspector: Self.inspector([60: (1_000, arguments)])))
        #expect(
            probe
                == .held(
                    [.init(pid: 60, foundBy: .recordedHarness, startedAt: harness.startedAt)],
                    recordedSessionGone: false))
    }

    /// A delayed hook from another tile, or a writer that knows nothing of harness processes,
    /// moves where the conversation was last seen; it takes no process away.
    @Test("Every running process the record names holds it, wherever the conversation was seen since")
    func everyNamedProcessHolds() async throws {
        let older = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let ended = ProcessIdentity(pid: 61, startedAtMicroseconds: 1_000)
        var record = Self.record(lastSeenIn: .init(hostSessionID: "tile-b", outsideTmux: true))
        record.harnessProcesses = .init(
            entries: [
                .init(
                    process: older, observedAt: Date(timeIntervalSince1970: 100),
                    seenIn: .init(hostSessionID: "tile-a", outsideTmux: true)),
                .init(
                    process: ended, observedAt: Date(timeIntervalSince1970: 200),
                    seenIn: .init(hostSessionID: "tile-b", outsideTmux: true)),
            ],
            namedAt: Date(timeIntervalSince1970: 200), unnamedAt: Date(timeIntervalSince1970: 300))

        let probe = await ClaudeHarnessAdapter().holders(
            of: record,
            in: Self.context(
                try Self.table("60 1 /usr/local/bin/claude"),
                inspector: Self.inspector([60: (1_000, ["/usr/local/bin/claude"])])))
        #expect(
            probe
                == .held(
                    [.init(pid: 60, foundBy: .recordedHarness, startedAt: older.startedAt, hostSessionID: "tile-a")],
                    recordedSessionGone: false))
    }

    private static let paneTree = """
          100   1 -zsh
          101 100 /usr/local/bin/claude
        """

    private static func sessionRecord(harness: ProcessIdentity?) -> ConversationRecord {
        record(
            lastSeenIn: .init(
                hostSessionID: "tile", tmux: .init(serverPID: 4242, sessionID: "$7", name: "recorded-name")),
            harness: harness)
    }

    @Test(
        "While the recorded harness holds, the session's other panes are not asked about, and a silent server does not refuse or place it"
    )
    func liveRecordedHarnessSkipsThePaneTree() async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let table = try Self.table(Self.paneTree + "\n   60   1 /usr/local/bin/claude")

        let probe = await ClaudeHarnessAdapter().holders(
            of: Self.sessionRecord(harness: harness),
            in: Self.context(
                table, inspector: Self.inspector([60: (1_000, ["/usr/local/bin/claude"])]), recordedSession: nil))
        guard case .held(let holders, _) = probe else {
            Issue.record("expected held, got \(probe)")
            return
        }
        #expect(holders == [.init(pid: 60, foundBy: .recordedHarness, startedAt: Date(timeIntervalSince1970: 0.001))])
    }

    @Test(
        "Once the recorded harness has ended, any claude in its session holds it"
    )
    func endedHarnessFallsBackToThePaneTree() async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let processes: [Int32: (Int64, [String])] = [101: (2_000, ["/usr/local/bin/claude"])]
        let session = RecordedTmuxSession.live(sessionID: "$7", name: "now-named", panePIDs: [100])

        let probe = await ClaudeHarnessAdapter().holders(
            of: Self.sessionRecord(harness: harness),
            in: Self.context(
                try Self.table(Self.paneTree), inspector: Self.inspector(processes), recordedSession: session))
        #expect(
            probe
                == .held(
                    [
                        .init(
                            pid: 101, foundBy: .sessionPaneTree, startedAt: Date(timeIntervalSince1970: 0.002),
                            tmuxSessionID: "$7", tmuxSessionName: "now-named", hostSessionID: "tile")
                    ], recordedSessionGone: false))

        let silent = await ClaudeHarnessAdapter().holders(
            of: Self.sessionRecord(harness: harness),
            in: Self.context(
                try Self.table(Self.paneTree), inspector: Self.inspector(processes), recordedSession: nil))
        guard case .unknown = silent else {
            Issue.record("expected unknown, got \(silent)")
            return
        }
    }

    @Test(
        "A recorded harness is placed in its session only while that session's server says it runs there",
        arguments: ["in-session", "elsewhere", "gone"]
    )
    func recordedPlaceIsChecked(answer: String) async throws {
        let harness = ProcessIdentity(pid: 101, startedAtMicroseconds: 1_000)
        let session: RecordedTmuxSession =
            switch answer {
            case "in-session": .live(sessionID: "$7", name: "renamed", panePIDs: [100])
            case "elsewhere": .live(sessionID: "$7", name: "renamed", panePIDs: [999])
            default: .gone
            }
        let probe = await ClaudeHarnessAdapter().holders(
            of: Self.sessionRecord(harness: harness),
            in: Self.context(
                try Self.table(Self.paneTree), inspector: Self.inspector([101: (1_000, ["/usr/local/bin/claude"])]),
                recordedSession: session))
        let placed = ConversationHolder(
            pid: 101, foundBy: .recordedHarness, startedAt: harness.startedAt, tmuxSessionID: "$7",
            tmuxSessionName: "renamed", hostSessionID: "tile")
        let unplaced = ConversationHolder(pid: 101, foundBy: .recordedHarness, startedAt: harness.startedAt)
        #expect(
            probe
                == .held([answer == "in-session" ? placed : unplaced], recordedSessionGone: answer == "gone"))
    }

    // MARK: - The pane tree

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

    /// A kernel that cannot be asked about `unreadable`, and knows every other pid in `processes`.
    private static func failingInspector(
        _ unreadable: Int32, _ processes: [Int32: (Int64, [String])] = [:]
    ) -> ProcessInspector {
        ProcessInspector(
            read: { pid in
                guard pid != unreadable else { return .unreadable }
                return processes[pid].map { .found(ProcessIdentity(pid: pid, startedAtMicroseconds: $0.0)) } ?? .absent
            },
            parent: { _ in nil },
            arguments: { processes[$0]?.1 }
        )
    }

    @Test(
        "A conversation whose hook could not name its claude is unknown until something holds it",
        arguments: ["unnamed", "unnamed-held", "never-asked"]
    )
    func unnamedHarnessIsUnknown(sighting: String) async throws {
        let record = Self.record(
            lastSeenIn: .init(hostSessionID: nil, outsideTmux: true), unnamed: sighting != "never-asked")
        let listing = sighting == "unnamed-held" ? "70 1 claude --resume \(Self.id)" : "1 0 /sbin/launchd"
        let probe = await ClaudeHarnessAdapter().holders(of: record, in: Self.context(try Self.table(listing)))
        switch sighting {
        case "unnamed":
            guard case .unknown(let detail) = probe else {
                Issue.record("expected unknown, got \(probe)")
                return
            }
            #expect(detail.contains("found no claude above it"))
        case "unnamed-held":
            #expect(probe == .held([.init(pid: 70, foundBy: .arguments, startedAt: nil)], recordedSessionGone: false))
        default:
            #expect(probe == .free)
        }
    }

    @Test("A recorded harness the kernel cannot be asked about is unknown, never free")
    func unreadableHarnessIsUnknown() async throws {
        let harness = ProcessIdentity(pid: 60, startedAtMicroseconds: 1_000)
        let record = Self.record(
            lastSeenIn: .init(hostSessionID: nil, outsideTmux: true), harness: harness)
        let probe = await ClaudeHarnessAdapter().holders(
            of: record,
            in: Self.context(
                try Self.table("60 1 /usr/local/bin/claude"), inspector: Self.failingInspector(60)))
        guard case .unknown = probe else {
            Issue.record("expected unknown, got \(probe)")
            return
        }
    }

    @Test("A recorded tmux server the kernel cannot be asked about is unknown, never gone")
    func unreadableServerIsUnknown() async {
        let lookup = ConversationHolderProbe.tmuxRecordedSession(
            fallbackSocketLabel: "fallback",
            run: { _, _, _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
            environment: [:],
            inspector: Self.failingInspector(4242)
        )
        #expect(await lookup(Self.tmuxRecord()) == nil)
    }

    // MARK: - The probe entrypoint

    @Test("A conversation named by id whose record cannot be read is unknown, not one with no record")
    func damagedRecordByIDIsUnknown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConversationRecordStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: try #require(store.fileURL(conversationID: Self.id)))
        let probe = ConversationHolderProbe(
            records: store, readProcessTable: { try? Self.table("1 0 /sbin/launchd") }, inspector: .none,
            recordedSession: { _ in nil })
        guard case .unknown(let detail) = await probe.probe(conversationID: Self.id) else {
            Issue.record("expected unknown")
            return
        }
        #expect(detail.contains("cannot be read"))
    }

    @Test("An unreadable process table is unknown, whatever the record says")
    func unreadableTableIsUnknown() async {
        let probe = ConversationHolderProbe(
            records: nil, readProcessTable: { nil }, inspector: .none, recordedSession: { _ in nil })
        #expect(await probe.probe(Self.record()) == .unknown("Could not read the process table"))
    }

    // MARK: - The harness a hook names

    /// A process tree, each pid with its parent and arguments.
    private static func tree(_ processes: [Int32: (Int32, [String])]) -> ProcessInspector {
        ProcessInspector(
            identity: { pid in processes[pid].map { _ in ProcessIdentity(pid: pid, startedAtMicroseconds: Int64(pid)) }
            },
            parent: { processes[$0]?.0 },
            arguments: { processes[$0]?.1 }
        )
    }

    @Test(
        "The hook names the nearest claude above it, through its shell, a wrapper, a link or a shim",
        arguments: [
            [["claude", "--resume", "x"]],
            [["/bin/bash", "/hooks/conversation-observer.sh"]],
            [["/bin/sh", "-c", "'/hooks/conversation-observer.sh'"], ["/bin/bash", "/hooks/observer.sh"]],
            [["/usr/bin/time", "-p", "workspaces"]],
            [["/bin/zsh", "-c", "sh /tmp/hook.sh"], ["/bin/sh", "/tmp/hook.sh"], ["/opt/shims/workspaces"]],
            [["node", "/opt/other-agent/cli.js"]],
        ]
    )
    func hookNamesTheNearestClaude(between: [[String]]) {
        var processes: [Int32: (Int32, [String])] = [10: (1, ["node", "/opt/claude-code/cli.js"])]
        var pid: Int32 = 10
        for words in between where words.first != "claude" {
            processes[pid + 10] = (pid, words)
            pid += 10
        }
        if between.first?.first == "claude" { processes[10] = (1, between[0]) }
        #expect(ConversationHookObserver.harnessRunningThisHook(from: pid, inspector: Self.tree(processes))?.pid == 10)
    }

    @Test("The hook looks only so far up, and never past launchd")
    func hookLooksOnlySoFarUp() {
        var processes: [Int32: (Int32, [String])] = [10: (1, ["claude"])]
        for pid in stride(from: Int32(20), through: 100, by: 10) { processes[pid] = (pid - 10, ["/bin/sh", "x"]) }
        let limit = Int32(ConversationHookObserver.ancestorLimit)
        #expect(
            ConversationHookObserver.harnessRunningThisHook(
                from: 10 + 10 * (limit - 1), inspector: Self.tree(processes))?.pid == 10)
        #expect(
            ConversationHookObserver.harnessRunningThisHook(from: 10 + 10 * limit, inspector: Self.tree(processes))
                == nil)
        let underLaunchd: [Int32: (Int32, [String])] = [1: (0, ["claude"]), 20: (1, ["/bin/sh", "x"])]
        #expect(ConversationHookObserver.harnessRunningThisHook(from: 20, inspector: Self.tree(underLaunchd)) == nil)
    }

    // MARK: - The adapter's other answers

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
