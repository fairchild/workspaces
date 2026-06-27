import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("SessionSwitcherSnapshot")
struct SessionSwitcherSnapshotTests {
    @Test("Live workspace session row keeps exact host session target and metadata")
    func liveWorkspaceSessionRowKeepsExactHostSessionTargetAndMetadata() throws {
        let repo = Repo(name: "workspaces", localPath: URL(fileURLWithPath: "/tmp/workspaces"))
        let workspace = Workspace(
            name: "feature-mux",
            path: URL(fileURLWithPath: "/tmp/workspaces-feature-mux"),
            sourceRepo: repo,
            gitBranch: "codex/session-switcher"
        )
        repo.workspaces = [workspace]

        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let key = HostTerminalSessionKey.hostPath("/tmp/workspaces-feature-mux")
        let session = HostTerminalSession(
            id: sessionID,
            key: key,
            directory: URL(fileURLWithPath: "/tmp/workspaces-feature-mux")
        )
        let lastEventAt = Date(timeIntervalSince1970: 100)
        let status = AgentSessionStatus(
            hostSessionID: sessionID,
            kind: .claudeCode,
            cwd: "/tmp/workspaces-feature-mux",
            run: .awaitingInput(reason: .permissionPrompt),
            contextUsedPercent: 64.4,
            costUSD: 1.25,
            modelDisplayName: "Claude Opus",
            lastEventAt: lastEventAt
        )

        let snapshot = SessionSwitcherSnapshot.make(
            repos: [repo],
            webSources: [],
            sessions: [session],
            activeSessionID: sessionID,
            agentStatuses: [sessionID: status],
            paneCountBySessionKey: [key.normalized(): 2],
            workspaceSessionKeys: [workspace.id: key],
            workspaceActivities: [workspace.id: .awaitingInput],
            repoActivities: [:],
            now: Date(timeIntervalSince1970: 160)
        )

        let row = try #require(snapshot.rows.first { $0.id == "session-\(sessionID.uuidString)" })
        #expect(row.target == .hostSession(sessionID))
        #expect(row.kind == .workspace)
        #expect(row.title == "feature-mux")
        #expect(row.preview == "Awaiting input: permission")
        #expect(row.isActive)
        #expect(row.activity == .awaitingInput)
        #expect(row.chips.map(\.title).contains("codex/session-switcher"))
        #expect(row.chips.map(\.title).contains("2 panes"))
        #expect(row.chips.map(\.title).contains("Claude Code"))
        #expect(row.chips.map(\.title).contains("Claude Opus"))
        #expect(row.chips.map(\.title).contains("64% ctx"))
        #expect(row.chips.map(\.title).contains("$1.25"))
        #expect(row.chips.map(\.title).contains("1m ago"))
    }

    @Test("Attention rows rank above newer idle rows")
    func attentionRowsRankAboveNewerIdleRows() {
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let attentionSessionID = UUID()
        let idleSessionID = UUID()
        let attentionKey = HostTerminalSessionKey.repoPath("/tmp/repo")
        let idleKey = HostTerminalSessionKey.defaultHome
        let attentionSession = HostTerminalSession(
            id: attentionSessionID,
            key: attentionKey,
            directory: URL(fileURLWithPath: "/tmp/repo")
        )
        let idleSession = HostTerminalSession(
            id: idleSessionID,
            key: idleKey,
            directory: URL(fileURLWithPath: "/tmp")
        )

        let rows = SessionSwitcherSnapshot.make(
            repos: [repo],
            webSources: [],
            sessions: [idleSession, attentionSession],
            activeSessionID: idleSessionID,
            agentStatuses: [
                attentionSessionID: AgentSessionStatus(
                    hostSessionID: attentionSessionID,
                    cwd: "/tmp/repo",
                    run: .errored(category: .toolFailure, message: "Tests failed"),
                    lastEventAt: Date(timeIntervalSince1970: 10)
                ),
                idleSessionID: AgentSessionStatus(
                    hostSessionID: idleSessionID,
                    cwd: "/tmp",
                    run: .idle,
                    lastEventAt: Date(timeIntervalSince1970: 100)
                ),
            ],
            paneCountBySessionKey: [:],
            workspaceSessionKeys: [:],
            workspaceActivities: [:],
            repoActivities: [repo.id: .errored(category: .toolFailure)]
        ).rows

        #expect(rows.first?.target == .hostSession(attentionSessionID))
        #expect(rows.first?.preview == "Tests failed")
    }

    @Test("Dormant workspaces remain launchable with branch metadata")
    func dormantWorkspacesRemainLaunchableWithBranchMetadata() throws {
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let workspace = Workspace(
            name: "no-session",
            path: URL(fileURLWithPath: "/tmp/no-session"),
            sourceRepo: repo,
            gitBranch: "feature/no-session"
        )
        repo.workspaces = [workspace]

        let snapshot = SessionSwitcherSnapshot.make(
            repos: [repo],
            webSources: [],
            sessions: [],
            activeSessionID: nil,
            agentStatuses: [:],
            paneCountBySessionKey: [:],
            workspaceSessionKeys: [workspace.id: .hostPath("/tmp/no-session")],
            workspaceActivities: [:],
            repoActivities: [:]
        )

        let row = try #require(snapshot.rows.first { $0.target == .workspace(workspace.id) })
        #expect(row.preview == "No live terminal session")
        #expect(row.chips.map(\.title).contains("feature/no-session"))
    }

    @Test("Web sources and command rows remain available")
    func webSourcesAndCommandRowsRemainAvailable() throws {
        let repo = Repo(name: "repo", localPath: URL(fileURLWithPath: "/tmp/repo"))
        let source = WebSource(
            name: "Local app",
            baseURLString: "http://localhost:3000/dashboard",
            allowedHost: "localhost",
            sourceRepo: repo
        )

        let snapshot = SessionSwitcherSnapshot.make(
            repos: [repo],
            webSources: [source],
            sessions: [],
            activeSessionID: nil,
            agentStatuses: [:],
            paneCountBySessionKey: [:],
            workspaceSessionKeys: [:],
            workspaceActivities: [:],
            repoActivities: [:],
            commands: [.changeTerminalTheme]
        )

        let webRow = try #require(snapshot.rows.first { $0.target == .webSource(source.id) })
        #expect(webRow.kind == .web)
        #expect(webRow.title == "Local app")
        #expect(webRow.preview == "http://localhost:3000/dashboard")

        let commandRow = try #require(
            snapshot.rows.first { $0.target == .command(.changeTerminalTheme) }
        )
        #expect(commandRow.title == "Change Terminal Theme...")
        #expect(commandRow.kind == .command)
    }

    @Test("Search matches preserved web source URLs")
    func searchMatchesPreservedWebSourceURLs() {
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.test/workspaces",
            allowedHost: "docs.example.test"
        )
        let snapshot = SessionSwitcherSnapshot.make(
            repos: [],
            webSources: [source],
            sessions: [],
            activeSessionID: nil,
            agentStatuses: [:],
            paneCountBySessionKey: [:],
            workspaceSessionKeys: [:],
            workspaceActivities: [:],
            repoActivities: [:],
            commands: []
        )

        let rows = SessionSwitcherSnapshot.rank(snapshot.rows, query: "example.test")
        #expect(rows.map(\.target) == [.webSource(source.id)])
    }

    @Test("Default ranking caps displayed rows without truncating snapshot rows")
    func defaultRankingCapsDisplayedRowsWithoutTruncatingSnapshotRows() {
        let repos = (0..<60).map { index in
            Repo(
                name: "repo-\(index)",
                localPath: URL(fileURLWithPath: "/tmp/repo-\(index)"),
                lastAccessedAt: Date(timeIntervalSince1970: Double(index))
            )
        }

        let snapshot = SessionSwitcherSnapshot.make(
            repos: repos,
            webSources: [],
            sessions: [],
            activeSessionID: nil,
            agentStatuses: [:],
            paneCountBySessionKey: [:],
            workspaceSessionKeys: [:],
            workspaceActivities: [:],
            repoActivities: [:],
            commands: []
        )

        #expect(snapshot.rows.count == 60)
        #expect(SessionSwitcherSnapshot.rank(snapshot.rows, query: "").count == 50)
        #expect(SessionSwitcherSnapshot.rank(snapshot.rows, query: "", limit: nil).count == 60)
    }
}
