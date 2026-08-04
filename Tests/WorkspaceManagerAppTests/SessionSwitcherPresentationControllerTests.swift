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

    /// `mergedWithBubbled` prefers `self` on ties, so the baseline must be the receiver. Swapping
    /// the operands is invisible at different severities and only shows up here: `.thinking` and
    /// `.runningTool` rank equally, and the repo's own session is what should win.
    @Test("On equal severity the repo's own activity wins over the bubbled one")
    func equalSeverityPrefersTheBaseline() {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let session = HostTerminalSession(key: .repoPath(repo.localURL.path), directory: repo.localURL)

        let activities = controller.repoActivities(
            context(
                repos: [repo],
                sessions: [session],
                agentStatusBySessionID: [session.id: status(hostSessionID: session.id, run: .thinking)],
                paneCountBySessionKey: [session.key: 1],
                bubbledRepoStatuses: [
                    repo.id: status(
                        hostSessionID: UUID(),
                        run: .runningTool(name: "bash", detail: nil)
                    )
                ]
            )
        )

        #expect(SessionActivity.thinking.severity == SessionActivity.runningTool.severity)
        #expect(activities[repo.id] == .thinking)
    }

    /// Binds that the repo projection actually routes through `context.normalizePath`: with a
    /// normalizer that rewrites the path, a session on the *raw* path no longer matches.
    @Test("Repo activity resolves its session key through the context normalizer")
    func repoActivityUsesTheContextNormalizer() {
        let repo = makeRepo(name: "alpha")
        let session = HostTerminalSession(key: .repoPath(repo.localURL.path), directory: repo.localURL)
        var rewritten = SessionSwitcherProjectionContext(
            repos: [repo],
            webSources: [],
            sessions: [session],
            activeSessionID: nil,
            agentStatusBySessionID: [session.id: status(hostSessionID: session.id, run: .thinking)],
            paneCountBySessionKey: [session.key: 1],
            activeSessionKey: nil,
            bubbledRepoStatuses: [:],
            registry: WorkspaceProviderRegistry(providers: []),
            normalizePath: { _ in "/somewhere/else" }
        )

        let rerouted = controller.repoActivities(rewritten)
        rewritten = context(
            repos: [repo],
            sessions: [session],
            agentStatusBySessionID: [session.id: status(hostSessionID: session.id, run: .thinking)],
            paneCountBySessionKey: [session.key: 1]
        )
        let direct = controller.repoActivities(rewritten)

        #expect(direct[repo.id] == .thinking)
        #expect(rerouted[repo.id] == .inactive)
    }

    @Test("Every repo appears in the projection, quiet or not")
    func everyRepoIsProjected() {
        let repos = [makeRepo(name: "alpha"), makeRepo(name: "beta"), makeRepo(name: "gamma")]

        let activities = controller.repoActivities(context(repos: repos))

        #expect(Set(activities.keys) == Set(repos.map(\.id)))
    }

    // MARK: - Snapshot assembly

    /// A shape-only assertion here would pass even if `snapshot` handed `make` empty
    /// dictionaries, so this asserts a value that can only arrive through the projections.
    /// Note `make` consults them for *live* rows only — a row backed by a session.
    @Test("A live workspace row carries the activity the projection computed")
    func snapshotLiveWorkspaceRowReflectsProjectedActivity() throws {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let workspace = try #require(repo.workspaces.first)
        let session = HostTerminalSession(
            key: .hostPath(workspace.workspaceURL.path),
            directory: workspace.workspaceURL
        )

        let snapshot = controller.snapshot(
            context(
                repos: [repo],
                sessions: [session],
                agentStatusBySessionID: [session.id: status(hostSessionID: session.id, run: .thinking)],
                paneCountBySessionKey: [session.key: 1]
            )
        )

        let row = try #require(snapshot.rows.first { $0.target == .hostSession(session.id) })
        #expect(row.kind == .workspace)
        #expect(row.activity == .thinking)
    }

    /// The bubbled merge reaching the switcher: a repo whose own session is idle but whose
    /// workspaces are waiting shows the bubbled state on its live row.
    @Test("A live repo row carries the merged bubbled activity")
    func snapshotLiveRepoRowReflectsBubbledActivity() throws {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let session = HostTerminalSession(key: .repoPath(repo.localURL.path), directory: repo.localURL)
        let bubbled = status(hostSessionID: UUID(), run: .awaitingInput(reason: .permissionPrompt))

        let snapshot = controller.snapshot(
            context(
                repos: [repo],
                sessions: [session],
                paneCountBySessionKey: [session.key: 1],
                bubbledRepoStatuses: [repo.id: bubbled]
            )
        )

        let row = try #require(snapshot.rows.first { $0.target == .hostSession(session.id) })
        #expect(row.kind == .repo)
        #expect(row.activity == .awaitingInput)
    }

    /// Documents the boundary the projections stop at: a repo with no live session renders a
    /// dormant row, and `make` hardcodes those to `.inactive` regardless of what bubbled up.
    @Test("A repo with no session renders dormant, ignoring bubbled status")
    func snapshotDormantRepoRowIgnoresBubbledActivity() throws {
        let repo = makeRepo(name: "alpha", workspaceNames: ["a1"])
        let bubbled = status(hostSessionID: UUID(), run: .thinking)

        let snapshot = controller.snapshot(
            context(repos: [repo], bubbledRepoStatuses: [repo.id: bubbled])
        )

        let row = try #require(snapshot.rows.first { $0.target == .repo(repo.id) })
        #expect(row.activity == .inactive)
    }

    @Test("An empty model produces only the standing command row")
    func snapshotWithNoModelIsStillUsable() {
        let snapshot = controller.snapshot(context(repos: []))

        #expect(snapshot.rows.contains { $0.kind == .command })
        #expect(snapshot.rows.contains { $0.kind == .workspace } == false)
        #expect(snapshot.rows.contains { $0.kind == .repo } == false)
    }
}
