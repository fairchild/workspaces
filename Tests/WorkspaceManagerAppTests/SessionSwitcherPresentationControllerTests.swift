//
//  SessionSwitcherPresentationControllerTests.swift
//  WorkspaceManagerAppTests
//
//  Coverage for the projections the main window feeds the session switcher: per-workspace session
//  keys and activity, and the per-repo merge of a repo's own session activity with the status
//  bubbled up from its workspaces. Snapshot ranking itself is covered in SessionSwitcherSnapshotTests.
//

import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("SessionSwitcherPresentation")
struct SessionSwitcherPresentationControllerTests {
    private let controller = SessionSwitcherPresentationController()

    // MARK: - Fixtures

    private func makeRepo(
        name: String = "alpha",
        workspaceNames: [String] = []
    ) -> Repo {
        let repo = Repo(name: name, localPath: URL(fileURLWithPath: "/Users/dev/code/\(name)"))
        repo.workspaces = workspaceNames.map { workspaceName in
            Workspace(
                name: workspaceName,
                path: URL(fileURLWithPath: "/Users/dev/code/\(name)/.workspaces/\(workspaceName)"),
                sourceRepo: repo
            )
        }
        return repo
    }

    private func context(
        repos: [Repo],
        sessions: [HostTerminalSession] = [],
        agentStatusBySessionID: [UUID: AgentSessionStatus] = [:],
        paneCountBySessionKey: [HostTerminalSessionKey: Int] = [:],
        activeSessionKey: HostTerminalSessionKey? = nil,
        bubbledRepoStatuses: [UUID: AgentSessionStatus] = [:]
    ) -> SessionSwitcherProjectionContext {
        SessionSwitcherProjectionContext(
            repos: repos,
            webSources: [],
            sessions: sessions,
            activeSessionID: nil,
            agentStatusBySessionID: agentStatusBySessionID,
            paneCountBySessionKey: paneCountBySessionKey,
            activeSessionKey: activeSessionKey,
            bubbledRepoStatuses: bubbledRepoStatuses,
            registry: WorkspaceProviderRegistry(providers: []),
            normalizePath: { $0.path }
        )
    }

    private func status(
        hostSessionID: UUID,
        run: AgentRunState,
        cwd: String = "/Users/dev/code/alpha"
    ) -> AgentSessionStatus {
        AgentSessionStatus(
            hostSessionID: hostSessionID,
            cwd: cwd,
            run: run,
            lastEventAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Workspace session keys

    @Test("Every workspace across every repo gets a routing key")
    func workspaceKeysCoverAllWorkspaces() {
        let first = makeRepo(name: "alpha", workspaceNames: ["a1", "a2"])
        let second = makeRepo(name: "beta", workspaceNames: ["b1"])
        let allWorkspaces = [first, second].flatMap(\.workspaces)

        let keys = controller.workspaceSessionKeys(context(repos: [first, second]))

        #expect(keys.count == 3)
        #expect(Set(keys.keys) == Set(allWorkspaces.map(\.id)))
    }

    /// With no provider registered, a workspace routes to its own directory on the host.
    @Test("A local workspace routes to its host path")
    func localWorkspaceRoutesToHostPath() throws {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let workspace = try #require(repo.workspaces.first)

        let keys = controller.workspaceSessionKeys(context(repos: [repo]))

        #expect(keys[workspace.id] == .hostPath(workspace.workspaceURL.path))
    }

    @Test("No repos means no keys rather than a crash")
    func noReposProducesNoKeys() {
        #expect(controller.workspaceSessionKeys(context(repos: [])).isEmpty)
    }

    // MARK: - Workspace activity

    @Test("A workspace with no session reports inactive")
    func workspaceWithoutSessionIsInactive() throws {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let workspace = try #require(repo.workspaces.first)

        let activities = controller.workspaceActivities(context(repos: [repo]))

        #expect(activities[workspace.id] == .inactive)
    }

    @Test("A workspace whose session is thinking reports thinking")
    func workspaceActivityFollowsAgentStatus() throws {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let workspace = try #require(repo.workspaces.first)
        let session = HostTerminalSession(
            key: .hostPath(workspace.workspaceURL.path),
            directory: workspace.workspaceURL
        )

        let activities = controller.workspaceActivities(
            context(
                repos: [repo],
                sessions: [session],
                agentStatusBySessionID: [session.id: status(hostSessionID: session.id, run: .thinking)],
                paneCountBySessionKey: [session.key: 1]
            )
        )

        #expect(activities[workspace.id] == .thinking)
    }

    // MARK: - Repo activity and the bubbling merge

    /// The rule this extraction locks in. A repo row speaks for its workspaces as well as its own
    /// terminal, so it merges the two — and a repo the aggregator has nothing for must fall back to
    /// `.inactive` rather than dropping the baseline.
    @Test("A repo with no bubbled status keeps its own baseline")
    func repoWithoutBubbledStatusKeepsBaseline() {
        let repo = makeRepo(name: "alpha")
        let session = HostTerminalSession(key: .repoPath(repo.localURL.path), directory: repo.localURL)

        let activities = controller.repoActivities(
            context(
                repos: [repo],
                sessions: [session],
                agentStatusBySessionID: [session.id: status(hostSessionID: session.id, run: .thinking)],
                paneCountBySessionKey: [session.key: 1]
            )
        )

        #expect(activities[repo.id] == .thinking)
    }

    @Test("A quiet repo surfaces the status bubbled up from its workspaces")
    func quietRepoSurfacesBubbledStatus() {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let bubbled = status(hostSessionID: UUID(), run: .awaitingInput(reason: .permissionPrompt))

        let activities = controller.repoActivities(
            context(repos: [repo], bubbledRepoStatuses: [repo.id: bubbled])
        )

        #expect(activities[repo.id] == .awaitingInput)
        #expect(activities[repo.id] != .inactive)
    }

    @Test("A repo with neither its own session nor anything bubbled is inactive")
    func idleRepoIsInactive() {
        let repo = makeRepo(name: "alpha")

        #expect(controller.repoActivities(context(repos: [repo]))[repo.id] == .inactive)
    }

    @Test("Bubbled status is matched to its own repo, not shared across repos")
    func bubbledStatusIsPerRepo() {
        let first = makeRepo(name: "alpha")
        let second = makeRepo(name: "beta")
        let bubbled = status(hostSessionID: UUID(), run: .thinking)

        let activities = controller.repoActivities(
            context(repos: [first, second], bubbledRepoStatuses: [first.id: bubbled])
        )

        #expect(activities[first.id] != .inactive)
        #expect(activities[second.id] == .inactive)
    }

    @Test("Every repo appears in the projection, quiet or not")
    func everyRepoIsProjected() {
        let repos = [makeRepo(name: "alpha"), makeRepo(name: "beta"), makeRepo(name: "gamma")]

        let activities = controller.repoActivities(context(repos: repos))

        #expect(Set(activities.keys) == Set(repos.map(\.id)))
    }

    // MARK: - Snapshot assembly

    @Test("The snapshot carries a row for every repo and workspace")
    func snapshotCoversReposAndWorkspaces() {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1", "a2"])

        let snapshot = controller.snapshot(context(repos: [repo]))

        // One row per repo and workspace, plus the standing theme command.
        #expect(snapshot.rows.count >= 3)
    }

    @Test("An empty model still produces a usable snapshot")
    func snapshotWithNoModelIsStillUsable() {
        let snapshot = controller.snapshot(context(repos: []))

        #expect(snapshot.rows.isEmpty == false)
    }
}
