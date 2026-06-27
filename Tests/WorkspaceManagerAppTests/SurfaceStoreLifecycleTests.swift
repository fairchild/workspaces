//
//  SurfaceStoreLifecycleTests.swift
//  WorkspaceManagerAppTests
//
//  Pins the full teardown-parity contract for a closing tile/session: every close path must, in
//  lockstep, free the surface AND fire the agent-domain + automation-handle teardown bundle
//  (`agentSessionRegistry.deregister`, `lastCommandStatusRegistry.clear`,
//  `automationHandleRegistry.remove`, and the `automationTileIDBySessionID` binding). This is the
//  regression net for Phase 5's flip to `SurfaceStore.sync` as the single eviction authority: the
//  surface-eviction side and the registry side cannot diverge (leaked surface ↔ ghost registry).
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("SurfaceStore lifecycle parity")
struct SurfaceStoreLifecycleTests {
    /// A store wired with the same registries the app attaches, so teardown parity is observable.
    private struct Harness {
        let store: HostTerminalStateStore
        let agentRegistry: AgentSessionRegistry
        let commandStatusRegistry: LastCommandStatusRegistry
        let automationRegistry: AutomationHandleRegistry
    }

    private func makeHarness() -> Harness {
        let store = HostTerminalStateStore()
        let agentRegistry = AgentSessionRegistry()
        let commandStatusRegistry = LastCommandStatusRegistry()
        let automationRegistry = AutomationHandleRegistry()
        store.attach(
            agentSessionRegistry: agentRegistry,
            localStateStore: nil,
            hooksSocketPath: nil,
            lastCommandStatusRegistry: commandStatusRegistry
        )
        store.configureAutomation(
            handleRegistry: automationRegistry,
            socketPath: "/tmp/workspaces-automation-parity.sock"
        )
        return Harness(
            store: store,
            agentRegistry: agentRegistry,
            commandStatusRegistry: commandStatusRegistry,
            automationRegistry: automationRegistry
        )
    }

    /// Every observable that must be live for a session while it is alive, and gone after it closes.
    private func assertRegistered(_ harness: Harness, _ sessionID: UUID, _ comment: Comment) {
        #expect(harness.agentRegistry.statuses[sessionID] != nil, comment)
        #expect(harness.automationRegistry.handle(for: sessionID) != nil, comment)
    }

    private func assertTornDown(_ harness: Harness, _ sessionID: UUID, _ comment: Comment) {
        #expect(harness.agentRegistry.statuses[sessionID] == nil, comment)
        #expect(harness.commandStatusRegistry.statusByTerminalSession[sessionID] == nil, comment)
        #expect(harness.automationRegistry.handle(for: sessionID) == nil, comment)
    }

    @Test("Split-pane process exit tears the split session's full bundle down, primary intact")
    func splitPaneExitTearsDownFullBundle() throws {
        let harness = makeHarness()
        let primary = harness.store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        // Seed the automation handle for the primary so its eviction (or non-eviction) is observable.
        _ = harness.store.automationEnvironment(for: primary)

        let split = try #require(
            harness.store.splitFocusedTile(inTabContaining: primary.id, preferredLayout: .defaultTrailing)
        )
        _ = harness.store.automationEnvironment(for: split)
        harness.commandStatusRegistry.ingest(markers: [.commandStart], for: split.id, commandLine: "make")

        assertRegistered(harness, primary.id, "primary registered before split exit")
        assertRegistered(harness, split.id, "split registered before exit")
        #expect(harness.commandStatusRegistry.statusByTerminalSession[split.id] != nil)

        #expect(harness.store.handleProcessExit(for: split.id))

        assertTornDown(harness, split.id, "split session fully torn down on its process exit")
        assertRegistered(harness, primary.id, "primary survives a split-pane exit")
    }

    @Test("Primary process exit tears down the primary and every attached split's full bundle")
    func primaryExitTearsDownTabAndSplits() throws {
        let harness = makeHarness()
        let primary = harness.store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        _ = harness.store.automationEnvironment(for: primary)
        let splitA = try #require(harness.store.splitFocusedTile(inTabContaining: primary.id))
        let splitB = try #require(harness.store.splitFocusedTile(inTabContaining: splitA.id))
        _ = harness.store.automationEnvironment(for: splitA)
        _ = harness.store.automationEnvironment(for: splitB)
        harness.commandStatusRegistry.ingest(markers: [.commandStart], for: primary.id, commandLine: "claude")

        for id in [primary.id, splitA.id, splitB.id] {
            assertRegistered(harness, id, "every pane registered at depth 2")
        }

        #expect(harness.store.handleProcessExit(for: primary.id))

        assertTornDown(harness, primary.id, "primary torn down")
        assertTornDown(harness, splitA.id, "depth-1 split torn down with the tab")
        assertTornDown(harness, splitB.id, "depth-2 split torn down with the tab")
        #expect(harness.store.sessions.isEmpty)
    }

    @Test("Retiring a workspace scope tears down every session's full bundle, other scopes intact")
    func retireScopeTearsDownFullBundle() throws {
        let harness = makeHarness()
        let home = harness.store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        _ = harness.store.automationEnvironment(for: home)
        let workspaceURL = URL(fileURLWithPath: "/Users/test/code/repo/workspaces/feature-a")
        let firstTab = harness.store.activateSession(
            key: .hostPath(workspaceURL.path),
            directory: workspaceURL
        ).session
        let secondTab = try #require(harness.store.createTab())
        let split = try #require(harness.store.splitFocusedTile(inTabContaining: firstTab.id))
        for session in [firstTab, secondTab, split] {
            _ = harness.store.automationEnvironment(for: session)
        }
        harness.commandStatusRegistry.ingest(markers: [.commandStart], for: split.id, commandLine: "make")

        for id in [firstTab.id, secondTab.id, split.id] {
            assertRegistered(harness, id, "workspace-scope session registered before retire")
        }

        let retired = harness.store.retireSessions(inScope: .hostPath(workspaceURL.path))
        #expect(Set(retired) == Set([split.id, firstTab.id, secondTab.id]))

        for id in [firstTab.id, secondTab.id, split.id] {
            assertTornDown(harness, id, "retired workspace-scope session fully torn down")
        }
        assertRegistered(harness, home.id, "out-of-scope session survives the retire")
    }

    @Test("Pruning a removed repo tears down its sessions' full bundle")
    func pruneRepoTearsDownFullBundle() throws {
        let harness = makeHarness()
        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo")
        let repo = harness.store.activateSession(
            key: .repoPath(repoURL.path),
            directory: repoURL
        ).session
        _ = harness.store.automationEnvironment(for: repo)
        let split = try #require(harness.store.splitFocusedTile(inTabContaining: repo.id))
        _ = harness.store.automationEnvironment(for: split)

        assertRegistered(harness, repo.id, "repo session registered before prune")
        assertRegistered(harness, split.id, "repo split registered before prune")

        // No valid repo paths → the repo's sessions are pruned.
        harness.store.pruneRepoSessions(validRepoPaths: [])

        assertTornDown(harness, repo.id, "pruned repo primary fully torn down")
        assertTornDown(harness, split.id, "pruned repo split fully torn down")
        #expect(harness.store.sessions.isEmpty)
    }

    @Test("After a split/close storm, registries hold exactly the surviving sessions — no ghosts")
    func stormLeavesNoGhostsOrMissing() throws {
        let harness = makeHarness()
        let primary = harness.store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        _ = harness.store.automationEnvironment(for: primary)

        // Build a depth-3 tree, then close two panes back down.
        let splitA = try #require(harness.store.splitFocusedTile(inTabContaining: primary.id))
        let splitB = try #require(harness.store.splitFocusedTile(inTabContaining: splitA.id))
        let splitC = try #require(harness.store.splitFocusedTile(inTabContaining: splitB.id))
        for session in [splitA, splitB, splitC] {
            _ = harness.store.automationEnvironment(for: session)
        }

        #expect(harness.store.handleProcessExit(for: splitC.id))
        #expect(harness.store.handleProcessExit(for: splitB.id))

        // Survivors: primary + splitA. Closed: splitB, splitC.
        let survivors: Set<UUID> = [primary.id, splitA.id]
        let closed: Set<UUID> = [splitB.id, splitC.id]

        for id in survivors {
            assertRegistered(harness, id, "survivor still registered after storm")
        }
        for id in closed {
            assertTornDown(harness, id, "closed pane left no ghost after storm")
        }

        // The registry holds exactly the survivors — no ghost, none missing.
        #expect(harness.agentRegistry.statuses.keys.allSatisfy { survivors.contains($0) })
        #expect(survivors.allSatisfy { harness.agentRegistry.statuses[$0] != nil })
    }
}
