//
//  UIFixtureSeederTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import SwiftData
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@MainActor
@Suite("UIFixtureSeeder", .serialized)
struct UIFixtureSeederTests {
    private struct Fixtures {
        let container: ModelContainer
        let context: ModelContext
        let registry: AgentSessionRegistry
        let commandRegistry: LastCommandStatusRegistry
        let store: TileTreeStore
    }

    // Latch is module-static; reset before each scenario so tests run independently.
    private func freshFixtures() throws -> Fixtures {
        UIFixtureSeeder.resetForTesting()
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        UIFixtureSeeder.seedDataIfNeeded(in: context)
        let registry = AgentSessionRegistry()
        let commandRegistry = LastCommandStatusRegistry()
        let tileTreeStore = TileTreeStore()
        tileTreeStore.attach(
            agentSessionRegistry: registry,
            localStateStore: nil,
            hooksSocketPath: nil,
            lastCommandStatusRegistry: commandRegistry
        )
        return Fixtures(
            container: container,
            context: context,
            registry: registry,
            commandRegistry: commandRegistry,
            store: tileTreeStore
        )
    }

    private func workspace(named name: String, in context: ModelContext) throws -> Workspace {
        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        return try #require(workspaces.first { $0.name == name })
    }

    private func status(
        for workspace: Workspace, in store: TileTreeStore, registry: AgentSessionRegistry
    )
        -> AgentSessionStatus?
    {
        hostSession(for: workspace, in: store).flatMap { registry.statuses[$0.id] }
    }

    private func commandStatus(
        for workspace: Workspace,
        in store: TileTreeStore,
        registry: LastCommandStatusRegistry
    ) -> LastCommandStatus? {
        hostSession(for: workspace, in: store).flatMap { registry.statusByTerminalSession[$0.id] }
    }

    private func hostSession(for workspace: Workspace, in store: TileTreeStore) -> HostTerminalSession? {
        let normalized = workspace.workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let key: HostTerminalSessionKey = .hostPath(normalized)
        return store.sessions.first(where: { $0.key == key })
    }

    @Test("Seed data inserts the expected fixture repos and workspaces")
    func seedDataInsertsExpectedFixture() throws {
        UIFixtureSeeder.resetForTesting()
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        UIFixtureSeeder.seedDataIfNeeded(in: context)

        let repos = try context.fetch(FetchDescriptor<Repo>())
        let names = Set(repos.map(\.name))
        #expect(names.isSuperset(of: ["skills", "bertram-chat", "bread-builder"]))

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        let wsNames = Set(workspaces.map(\.name))
        #expect(
            wsNames.isSuperset(of: [
                "skills-v13", "feature-auth", "bugfix-422", "refactor-state", "refactor-runtime",
            ])
        )
    }

    @Test("Seeded workspace dates spread across all three Recent buckets")
    func seedDataSpreadsRecentBuckets() throws {
        UIFixtureSeeder.resetForTesting()
        let schema = Schema([Repo.self, Workspace.self, WebSource.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_755_864_000)
        UIFixtureSeeder.seedDataIfNeeded(in: context, now: now)

        let repos = try context.fetch(FetchDescriptor<Repo>())
        let buckets = SidebarRecentArrangement.buckets(
            repos: repos,
            snapshot: SidebarRecentArrangement.snapshot(for: repos),
            repoRootPaneCounts: [:],
            now: now,
            calendar: .current
        )

        #expect(buckets.map(\.title) == ["Today", "This Week", "Earlier"])
        #expect(buckets.first?.rows.map(\.name) == ["feature-auth"])
    }

    @Test("The pinned env var pins the named workspaces in listed order")
    func pinnedEnvSeedsThePinnedSection() throws {
        let f = try freshFixtures()

        let pinned = UIFixtureSeeder.seedPinnedWorkspacesIfNeeded(
            from: [
                "WORKSPACES_UI_FIXTURE": "1",
                UIFixtureSeeder.pinnedEnvKey: "feature-auth,skills-v13",
            ],
            in: f.context
        )

        #expect(pinned == 2)
        #expect(try workspace(named: "feature-auth", in: f.context).pinOrder == 0)
        #expect(try workspace(named: "skills-v13", in: f.context).pinOrder == 1)
        #expect(try workspace(named: "bugfix-422", in: f.context).pinOrder == nil)
    }

    @Test("Pinned seeding needs fixture mode, a value, and a name that resolves")
    func pinnedEnvIsIgnoredOutsideFixtureMode() throws {
        let f = try freshFixtures()
        let key = UIFixtureSeeder.pinnedEnvKey

        #expect(UIFixtureSeeder.seedPinnedWorkspacesIfNeeded(from: [key: "feature-auth"], in: f.context) == 0)
        #expect(
            UIFixtureSeeder.seedPinnedWorkspacesIfNeeded(
                from: ["WORKSPACES_UI_FIXTURE": "1", key: "  "], in: f.context) == 0
        )
        #expect(
            UIFixtureSeeder.seedPinnedWorkspacesIfNeeded(
                from: ["WORKSPACES_UI_FIXTURE": "1", key: "no-such-workspace"], in: f.context) == 0
        )
        #expect(try workspace(named: "feature-auth", in: f.context).pinOrder == nil)
    }

    @Test("Pinned fixture workspaces render above the Recent buckets, not inside them")
    func pinnedFixtureWorkspacesLeaveTheBuckets() throws {
        let f = try freshFixtures()
        UIFixtureSeeder.seedPinnedWorkspacesIfNeeded(
            from: [
                "WORKSPACES_UI_FIXTURE": "1",
                UIFixtureSeeder.pinnedEnvKey: "feature-auth,skills-v13",
            ],
            in: f.context
        )

        let repos = try f.context.fetch(FetchDescriptor<Repo>())
        let bucketed = SidebarRecentArrangement.buckets(
            repos: repos,
            snapshot: SidebarRecentArrangement.snapshot(for: repos),
            repoRootPaneCounts: [:],
            now: Date(),
            calendar: .current
        ).flatMap { $0.rows.map(\.name) }

        #expect(!bucketed.contains("feature-auth"))
        #expect(!bucketed.contains("skills-v13"))
        #expect(bucketed.contains("bugfix-422"))

        let pinned = SidebarPinController().pinnedWorkspaces(in: repos.flatMap(\.workspaces))
        #expect(pinned.map(\.name) == ["feature-auth", "skills-v13"])
    }

    @Test("Missing env var is a no-op")
    func absentEnvIsNoOp() throws {
        let f = try freshFixtures()
        let applied = UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [:],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        #expect(applied == 0)
        #expect(f.registry.statuses.isEmpty)
        #expect(f.store.sessions.isEmpty)
    }

    @Test("Single thinking workspace lands at .thinking via the session pipeline")
    func singleThinkingEntry() throws {
        let f = try freshFixtures()
        let applied = UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [UIFixtureSeeder.agentStatesEnvKey: "feature-auth:thinking"],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        #expect(applied == 1)

        let featureAuth = try workspace(named: "feature-auth", in: f.context)
        let resolved = status(for: featureAuth, in: f.store, registry: f.registry)
        #expect(resolved?.run == .thinking)
    }

    @Test("Multiple entries resolve to distinct workspaces and run states")
    func multipleEntries() throws {
        let f = try freshFixtures()
        let raw =
            "feature-auth:thinking, bugfix-422:awaitingInput , refactor-runtime:errored,refactor-state:idle"
        let applied = UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [UIFixtureSeeder.agentStatesEnvKey: raw],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        #expect(applied == 4)

        let featureAuth = try workspace(named: "feature-auth", in: f.context)
        #expect(status(for: featureAuth, in: f.store, registry: f.registry)?.run == .thinking)

        let bugfix = try workspace(named: "bugfix-422", in: f.context)
        if case .awaitingInput = status(for: bugfix, in: f.store, registry: f.registry)?.run {
            // expected
        } else {
            Issue.record("bugfix-422 expected .awaitingInput")
        }

        let refactorRuntime = try workspace(named: "refactor-runtime", in: f.context)
        if case .errored = status(for: refactorRuntime, in: f.store, registry: f.registry)?.run {
            // expected
        } else {
            Issue.record("refactor-runtime expected .errored")
        }

        let refactorState = try workspace(named: "refactor-state", in: f.context)
        // `idle` produces no events, but the session is still created and registers as idle.
        #expect(status(for: refactorState, in: f.store, registry: f.registry)?.run == .idle)
    }

    @Test("Every AgentRunState case is producible from the env var")
    func everyRunStateProducible() throws {
        let f = try freshFixtures()
        let raw =
            "feature-auth:thinking,bugfix-422:awaitingInput,refactor-state:runningTool,refactor-runtime:errored,skills-v13:complete"
        UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [UIFixtureSeeder.agentStatesEnvKey: raw],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        let featureAuth = try workspace(named: "feature-auth", in: f.context)
        #expect(status(for: featureAuth, in: f.store, registry: f.registry)?.run == .thinking)

        let refactorState = try workspace(named: "refactor-state", in: f.context)
        if case .runningTool = status(for: refactorState, in: f.store, registry: f.registry)?.run {
            // expected
        } else {
            Issue.record("refactor-state expected .runningTool")
        }

        let skills = try workspace(named: "skills-v13", in: f.context)
        #expect(status(for: skills, in: f.store, registry: f.registry)?.run == .complete)
    }

    @Test("Unknown workspace name logs and is skipped; valid entries still apply")
    func unknownWorkspaceSkipped() throws {
        let f = try freshFixtures()
        let applied = UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [
                UIFixtureSeeder.agentStatesEnvKey: "no-such-workspace:thinking,feature-auth:thinking"
            ],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        #expect(applied == 1)

        let featureAuth = try workspace(named: "feature-auth", in: f.context)
        #expect(status(for: featureAuth, in: f.store, registry: f.registry)?.run == .thinking)
    }

    @Test("Unknown state name logs and is skipped; valid entries still apply")
    func unknownStateSkipped() throws {
        let f = try freshFixtures()
        let applied = UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [
                UIFixtureSeeder.agentStatesEnvKey: "feature-auth:nonsense,bugfix-422:errored"
            ],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        #expect(applied == 1)

        let bugfix = try workspace(named: "bugfix-422", in: f.context)
        if case .errored = status(for: bugfix, in: f.store, registry: f.registry)?.run {
            // expected
        } else {
            Issue.record("bugfix-422 expected .errored")
        }
    }

    @Test("First env-var entry becomes the active session — drives front tab in screenshots")
    func firstEntryBecomesActiveSession() throws {
        let f = try freshFixtures()
        UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [
                UIFixtureSeeder.agentStatesEnvKey:
                    "feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        let featureAuth = try workspace(named: "feature-auth", in: f.context)
        let normalized = featureAuth.workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path
        let firstSession = f.store.sessions.first { $0.key == .hostPath(normalized) }
        #expect(firstSession != nil)
        #expect(f.store.activeSessionID == firstSession?.id)
    }

    @Test("Command-status fixture seeds the terminal sliver registry")
    func commandStatusEntry() throws {
        let f = try freshFixtures()
        let now = Date(timeIntervalSince1970: 1_000)
        let applied = UIFixtureSeeder.seedCommandStatusesIfNeeded(
            from: [UIFixtureSeeder.commandStatusesEnvKey: "feature-auth:failed"],
            in: f.context,
            commandStatusRegistry: f.commandRegistry,
            tileTreeStore: f.store,
            now: now
        )
        #expect(applied == 1)

        let featureAuth = try workspace(named: "feature-auth", in: f.context)
        let terminalSession = try #require(hostSession(for: featureAuth, in: f.store))
        let status = try #require(commandStatus(for: featureAuth, in: f.store, registry: f.commandRegistry))
        #expect(f.store.activeSessionID == terminalSession.id)
        #expect(status.commandLine == "swift test")
        #expect(status.exitCode == 1)
        #expect(status.isSuccess == false)
        #expect(abs((status.duration ?? 0) - 2.4) < 0.001)
    }

    @Test("Every command-status fixture token is producible from the env var")
    func everyCommandStatusProducible() throws {
        let f = try freshFixtures()
        let now = Date(timeIntervalSince1970: 1_000)
        let raw =
            "feature-auth:success,bugfix-422:running,refactor-state:finished,refactor-runtime:failed"
        let applied = UIFixtureSeeder.seedCommandStatusesIfNeeded(
            from: [UIFixtureSeeder.commandStatusesEnvKey: raw],
            in: f.context,
            commandStatusRegistry: f.commandRegistry,
            tileTreeStore: f.store,
            now: now
        )
        #expect(applied == 4)

        let featureAuth = try workspace(named: "feature-auth", in: f.context)
        #expect(commandStatus(for: featureAuth, in: f.store, registry: f.commandRegistry)?.exitCode == 0)

        let bugfix = try workspace(named: "bugfix-422", in: f.context)
        #expect(commandStatus(for: bugfix, in: f.store, registry: f.commandRegistry)?.isRunning == true)

        let refactorState = try workspace(named: "refactor-state", in: f.context)
        let finished = try #require(commandStatus(for: refactorState, in: f.store, registry: f.commandRegistry))
        #expect(finished.isRunning == false)
        #expect(finished.exitCode == nil)

        let refactorRuntime = try workspace(named: "refactor-runtime", in: f.context)
        #expect(commandStatus(for: refactorRuntime, in: f.store, registry: f.commandRegistry)?.exitCode == 1)
    }

    @Test("Re-invoking the seeder is idempotent once the latch is set")
    func idempotentAfterFirstCall() throws {
        let f = try freshFixtures()
        let first = UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [UIFixtureSeeder.agentStatesEnvKey: "feature-auth:thinking"],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        #expect(first == 1)
        let second = UIFixtureSeeder.seedAgentStatesIfNeeded(
            from: [UIFixtureSeeder.agentStatesEnvKey: "bugfix-422:errored"],
            in: f.context,
            registry: f.registry,
            tileTreeStore: f.store
        )
        #expect(second == 0)

        let bugfix = try workspace(named: "bugfix-422", in: f.context)
        // The second invocation must not land bugfix-422 in .errored.
        #expect(status(for: bugfix, in: f.store, registry: f.registry) == nil)
    }

    @Test("Command-status seeder is idempotent once the latch is set")
    func commandStatusSeederIdempotentAfterFirstCall() throws {
        let f = try freshFixtures()
        let first = UIFixtureSeeder.seedCommandStatusesIfNeeded(
            from: [UIFixtureSeeder.commandStatusesEnvKey: "feature-auth:failed"],
            in: f.context,
            commandStatusRegistry: f.commandRegistry,
            tileTreeStore: f.store
        )
        #expect(first == 1)
        let second = UIFixtureSeeder.seedCommandStatusesIfNeeded(
            from: [UIFixtureSeeder.commandStatusesEnvKey: "bugfix-422:failed"],
            in: f.context,
            commandStatusRegistry: f.commandRegistry,
            tileTreeStore: f.store
        )
        #expect(second == 0)

        let bugfix = try workspace(named: "bugfix-422", in: f.context)
        #expect(commandStatus(for: bugfix, in: f.store, registry: f.commandRegistry) == nil)
    }
}
