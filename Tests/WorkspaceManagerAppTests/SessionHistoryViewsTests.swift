import AppKit
import SwiftUI
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SessionHistoryViews")
@MainActor
struct SessionHistoryViewsTests {
    @Test("List row materializes")
    func listRowBuilds() {
        expectRenders(SessionHistoryListRow(item: makeItem(transcript: URL(fileURLWithPath: "/tmp/x.jsonl"))))
    }

    @Test("Detail renders the transcript branch when a transcript exists")
    func detailTranscriptBranch() {
        let item = makeItem(transcript: URL(fileURLWithPath: "/tmp/x.jsonl"))
        expectRenders(SessionHistoryDetailView(item: item, viewModel: SessionHistoryViewModel(store: nil)))
    }

    @Test("Detail renders the fallback branch when no transcript exists")
    func detailFallbackBranch() {
        let item = makeItem(transcript: nil)
        expectRenders(SessionHistoryDetailView(item: item, viewModel: SessionHistoryViewModel(store: nil)))
    }

    @Test("Event timeline materializes")
    func eventTimelineBuilds() {
        let event = AgentStatusEventRow(
            id: "e1",
            hostSessionID: UUID(),
            agentSessionID: "s",
            agentKind: "claudeCode",
            origin: "hook",
            originDetail: nil,
            eventName: "tool_start",
            runState: "running_tool",
            cwd: "/x",
            toolName: "Bash",
            toolDetail: nil,
            awaitingReason: nil,
            errorCategory: nil,
            errorMessage: nil,
            modelDisplayName: "Claude",
            eventAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        expectRenders(SessionHistoryEventTimelineView(events: [event]))
    }

    @Test("History window builds with an empty store")
    func windowBuilds() {
        expectRenders(SessionHistoryView(store: nil))
    }

    private func expectRenders(_ view: some View) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 460)
        host.layoutSubtreeIfNeeded()
        #expect(host.bounds.width == 700)
    }

    private func makeItem(transcript: URL?) -> SessionHistoryItem {
        SessionHistoryItem(
            id: UUID(),
            title: "repo",
            path: "/code/repo",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: nil,
            modelDisplayName: "Claude",
            agentKind: "claudeCode",
            agentSessionID: "s",
            agentCwd: "/code/repo",
            transcriptURL: transcript
        )
    }
}
