// swift-format-ignore-file: NeverForceUnwrap
// Test fixtures/helpers force-unwrap known-good literals or generator output; a failure here is a loud test crash, not a user-facing risk.
import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SessionHistory")
struct SessionHistoryViewModelTests {
    // MARK: Pure mapping

    @Test("Maps a continuity row to a display item, title from the target path")
    func mapsRowToItem() {
        let row = makeRow(
            targetPath: "/Users/me/code/app/",
            agentSessionID: "sess-1",
            agentCwd: "/Users/me/code/app",
            model: "Claude"
        )
        // Transcript "exists" → item carries the URL and reads as resumable.
        let resumability = ClaudeTranscriptResumability(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/home"),
            fileExists: { _ in true }
        )
        let item = SessionHistoryItem.make(from: row, resumability: resumability)
        #expect(item.title == "app")  // basename, trailing slash trimmed
        #expect(item.path == "/Users/me/code/app/")
        #expect(item.modelDisplayName == "Claude")
        #expect(item.isResumable)
        #expect(item.transcriptURL?.lastPathComponent == "sess-1.jsonl")
    }

    @Test("A missing transcript yields a non-resumable item with no URL")
    func mapsNonResumableItem() {
        let row = makeRow(targetPath: "/x/repo", agentSessionID: "sess-2", agentCwd: "/x/repo")
        let resumability = ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false })
        let item = SessionHistoryItem.make(from: row, resumability: resumability)
        #expect(!item.isResumable)
        #expect(item.transcriptURL == nil)
    }

    @Test("Rows without an agent session are never resumable")
    func mapsRowWithoutAgent() {
        let row = makeRow(targetPath: "/x/repo", agentSessionID: nil, agentCwd: nil)
        let resumability = ClaudeTranscriptResumability(environment: [:], fileExists: { _ in true })
        let item = SessionHistoryItem.make(from: row, resumability: resumability)
        #expect(!item.isResumable)
    }

    // MARK: Day grouping

    @Test("Items fold into day sections, newest day first, order preserved within a day")
    func groupsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day2 = Date(timeIntervalSince1970: 1_700_000_000)  // later day
        let day1 = day2.addingTimeInterval(-48 * 3600)  // two days earlier
        let items = [
            item(id: 1, at: day2.addingTimeInterval(100)),
            item(id: 2, at: day2),
            item(id: 3, at: day1),
        ]
        let sections = SessionHistoryGrouping.byDay(items, calendar: calendar)
        #expect(sections.count == 2)
        #expect(sections[0].items.map(\.id) == items[0...1].map(\.id))  // newest day, input order kept
        #expect(sections[1].items.map(\.id) == [items[2].id])
    }

    // MARK: View model over a temp store

    @Test("Loads history newest-first and paginates")
    func loadsAndPaginates() async throws {
        let store = try makeStore()
        // Record three sessions sequentially; last_seen_at is monotonic → newest first.
        for path in ["/a", "/b", "/c"] {
            try await store.recordTerminalSession(
                HostTerminalSession(id: UUID(), key: .repoPath(path), directory: URL(fileURLWithPath: path)),
                terminalMode: "ghostty_managed_splits",
                isActive: true,
                hooksSocketPath: nil
            )
        }
        let vm = await SessionHistoryViewModel(
            store: store,
            resumability: ClaudeTranscriptResumability(environment: [:], fileExists: { _ in false }),
            pageSize: 2
        )
        await vm.loadFirstPage()
        var items = await vm.items
        #expect(items.count == 2)  // first page fills to pageSize
        #expect(await vm.canLoadMore)

        await vm.loadMore()
        items = await vm.items
        #expect(items.count == 3)
        #expect(Set(items.map(\.title)) == ["a", "b", "c"])  // every session surfaced across pages
        #expect(await vm.canLoadMore == false)  // last page was short → end reached
    }

    @Test("Event timeline is returned in chronological order")
    func eventsAreChronological() async throws {
        let store = try makeStore()
        let sessionID = UUID()
        try await store.recordTerminalSession(
            HostTerminalSession(id: sessionID, key: .repoPath("/a"), directory: URL(fileURLWithPath: "/a")),
            terminalMode: "ghostty_managed_splits",
            isActive: true,
            hooksSocketPath: nil
        )
        for (index, tool) in ["Read", "Bash"].enumerated() {
            try await store.recordAgentEvents(
                [.toolStart(name: tool, detail: nil)],
                hostSessionID: sessionID,
                origin: .hook,
                status: AgentSessionStatus(
                    hostSessionID: sessionID,
                    agentSessionID: "s",
                    kind: .claudeCode,
                    cwd: "/a",
                    run: .runningTool(name: tool, detail: nil),
                    modelDisplayName: "Claude",
                    lastEventAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    hookActive: true,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            )
        }
        let vm = await SessionHistoryViewModel(store: store)
        let item = SessionHistoryItem(
            id: sessionID, title: "a", path: "/a", timestamp: Date(), endedAt: nil,
            modelDisplayName: nil, agentKind: nil, agentSessionID: nil, agentCwd: nil, transcriptURL: nil
        )
        let events = await vm.events(for: item)
        #expect(events.map(\.toolName) == ["Read", "Bash"])  // chronological, not newest-first
    }

    // MARK: Helpers

    private func item(id: Int, at date: Date) -> SessionHistoryItem {
        SessionHistoryItem(
            id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", id))")!,
            title: "\(id)", path: "/\(id)", timestamp: date, endedAt: nil,
            modelDisplayName: nil, agentKind: nil, agentSessionID: nil, agentCwd: nil, transcriptURL: nil
        )
    }

    private func makeRow(
        targetPath: String?,
        agentSessionID: String?,
        agentCwd: String?,
        model: String? = nil
    ) -> TerminalSessionContinuityRow {
        TerminalSessionContinuityRow(
            hostSessionID: UUID(),
            sessionKey: "k",
            targetKind: "repo",
            targetID: nil,
            targetPath: targetPath,
            backendIdentifier: nil,
            backendInstanceID: nil,
            directoryPath: targetPath ?? "/",
            terminalMode: "ghostty_managed_splits",
            tmuxSessionName: nil,
            customCommandPresent: false,
            isActive: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            agentSessionID: agentSessionID,
            agentKind: agentSessionID == nil ? nil : "claudeCode",
            agentRunState: nil,
            agentCwd: agentCwd,
            agentModelDisplayName: model,
            agentEventAt: nil
        )
    }

    private func makeStore() throws -> LocalStateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try LocalStateStore(databaseURL: directory.appendingPathComponent("state.sqlite"))
    }
}
