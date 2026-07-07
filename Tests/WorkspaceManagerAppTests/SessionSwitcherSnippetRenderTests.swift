import AppKit
import SwiftUI
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("SessionSwitcher snippet render")
struct SessionSwitcherSnippetRenderTests {
    /// Renders the switcher rows (via the extracted `SessionSwitcherRowView`, not the List, which
    /// SwiftUI does not draw under `ImageRenderer`) over a snapshot whose live rows carry
    /// status-derived activity snippets — a running tool with its detail and an awaiting-input row
    /// with primary emphasis (#680). Asserts a non-empty image and, when `WORKSPACES_EVIDENCE_DIR`
    /// is set, writes a PNG for PR evidence without launching the app.
    @Test("Switcher rows render status-derived activity snippets")
    func rendersActivitySnippets() throws {
        let repo = Repo(name: "workspaces", localPath: URL(fileURLWithPath: "/tmp/workspaces"))
        let running = Workspace(
            name: "feature-mux",
            path: URL(fileURLWithPath: "/tmp/ws-running"),
            sourceRepo: repo,
            gitBranch: "claude/680-snippets"
        )
        let awaiting = Workspace(
            name: "review-pane",
            path: URL(fileURLWithPath: "/tmp/ws-awaiting"),
            sourceRepo: repo,
            gitBranch: "claude/review"
        )
        repo.workspaces = [running, awaiting]

        let runningSession = hostSession(at: "/tmp/ws-running")
        let awaitingSession = hostSession(at: "/tmp/ws-awaiting")

        let snapshot = SessionSwitcherSnapshot.make(
            repos: [repo],
            webSources: [],
            sessions: [runningSession, awaitingSession],
            activeSessionID: runningSession.id,
            agentStatuses: [
                runningSession.id: status(
                    for: runningSession, cwd: "/tmp/ws-running",
                    run: .runningTool(name: "Bash", detail: "swift test")),
                awaitingSession.id: status(
                    for: awaitingSession, cwd: "/tmp/ws-awaiting",
                    run: .awaitingInput(reason: .permissionPrompt)),
            ],
            paneCountBySessionKey: [:],
            workspaceSessionKeys: [
                running.id: runningSession.key,
                awaiting.id: awaitingSession.key,
            ],
            workspaceActivities: [:],
            repoActivities: [:]
        )

        // The two live workspace rows, in the snapshot's attention-first order.
        let rows = snapshot.rows.filter {
            if case .hostSession = $0.target { return true }
            return false
        }

        let view = VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                SessionSwitcherRowView(row: row, isHighlighted: row.id == rows.first?.id)
            }
        }
        .frame(width: 720, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)

        guard let dir = ProcessInfo.processInfo.environment["WORKSPACES_EVIDENCE_DIR"],
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return
        }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("session-switcher-snippets.png")
        try png.write(to: url)
    }

    private func hostSession(at path: String) -> HostTerminalSession {
        HostTerminalSession(
            id: UUID(),
            key: .hostPath(path),
            directory: URL(fileURLWithPath: path)
        )
    }

    private func status(
        for session: HostTerminalSession, cwd: String, run: AgentRunState
    )
        -> AgentSessionStatus
    {
        AgentSessionStatus(
            hostSessionID: session.id,
            kind: .claudeCode,
            cwd: cwd,
            run: run,
            contextUsedPercent: 48,
            costUSD: 0.42,
            modelDisplayName: "Claude Opus"
        )
    }
}
