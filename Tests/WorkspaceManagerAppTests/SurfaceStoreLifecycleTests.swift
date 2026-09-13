//
//  SurfaceStoreLifecycleTests.swift
//  WorkspaceManagerAppTests
//
//  Pins the full teardown-parity contract for a closing tile/session: every close path must, in
//  lockstep, free the surface AND fire the agent-domain + automation-handle teardown bundle
//  (`agentSessionRegistry.deregister`, `lastCommandStatusRegistry.clear`,
//  `automationHandleRegistry.remove`, and the unified `tileIDBySessionID` binding). This is the
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
    @Test("Sandbox restart replaces only realized terminals, preserving tabs, splits, identity, and focus")
    func restartScopePreservesSessionTreeAndReplacesRealizedSurfaces() throws {
        let harness = makeHarness()
        let store = harness.store
        let home = store.activateSession(key: .defaultHome, directory: URL(fileURLWithPath: "/tmp")).session
        let homeTile = store.renderTileID(forSession: home)
        let homeSurface = store.surfaceStore.terminalSurface(for: homeTile, session: home)
        let scope = HostTerminalSessionKey.backendSession(providerID: "compose", instanceID: "ws-test")
        let command = "docker compose exec agent tmux new-session -A -s ws-__WORKSPACES_COMPOSE_TERMINAL_SESSION_ID__"
        let primary = store.activateSession(
            key: scope, directory: URL(fileURLWithPath: "/tmp"), customCommand: command
        ).session
        let hiddenTab = try #require(store.createTab())
        let unopenedTab = try #require(store.createTab())
        let split = try #require(store.splitFocusedTile(inTabContaining: primary.id))
        let deeperSplit = try #require(store.splitFocusedTile(inTabContaining: split.id))
        #expect(store.activateExistingSession(sessionID: primary.id))
        let originalSessions = store.allLiveSessions
        let originalTree = try #require(store.tileTree(forPrimarySessionID: primary.id))
        let realized = [primary, split, deeperSplit, hiddenTab]
        let tiles = realized.map { store.renderTileID(forSession: $0) }
        let oldSurfaces = zip(tiles, realized).map { tile, session in
            store.surfaceStore.terminalSurface(for: tile, session: session)
        }
        let unopenedTile = store.renderTileID(forSession: unopenedTab)
        let handles = realized.map { store.automationEnvironment(for: $0) }

        let restarted = store.restartTerminalSurfaces(inScope: scope)

        #expect(Set(restarted) == Set(realized.map(\.id)))
        #expect(store.allLiveSessions == originalSessions)
        #expect(store.tileTree(forPrimarySessionID: primary.id) == originalTree)
        #expect(store.activeSessionID == primary.id)
        #expect(realized.map { store.renderTileID(forSession: $0) } == tiles)
        #expect(store.surfaceStore.surface(for: homeTile) === homeSurface)
        #expect(store.surfaceStore.terminalRenderGeneration(for: homeTile) == 0)
        #expect(store.surfaceStore.surface(for: unopenedTile) == nil)
        #expect(store.surfaceStore.terminalRenderGeneration(for: unopenedTile) == 0)

        for (index, session) in realized.enumerated() {
            let tile = tiles[index]
            #expect(store.surfaceStore.surface(for: tile) == nil)
            #expect(store.surfaceStore.terminalRenderGeneration(for: tile) == 1)
            let replacement = store.surfaceStore.terminalSurface(for: tile, session: session)
            #expect(replacement !== oldSurfaces[index])
            #expect(replacement.session == session)
            #expect(replacement.session.customCommand == command)
            #expect(store.automationEnvironment(for: session) == handles[index])
            assertRegistered(harness, session.id, "restart keeps the terminal registered")
        }

        // Rendering and an unrelated tree publication do not restart the guest again.
        let primaryReplacement = store.surfaceStore.surface(for: tiles[0])
        #expect(store.surfaceStore.terminalSurface(for: tiles[0], session: primary) === primaryReplacement)
        store.surfaceStore.sync(activeLeafIDs: [homeTile, unopenedTile] + tiles)
        #expect(store.surfaceStore.terminalRenderGeneration(for: tiles[0]) == 1)
        _ = store.retireSessions(inScope: scope)
        #expect(tiles.allSatisfy { store.surfaceStore.terminalRenderGeneration(for: $0) == 0 })
    }

    /// A store wired with the same registries the app attaches, so teardown parity is observable.
    private struct Harness {
        let store: TileTreeStore
        let agentRegistry: AgentSessionRegistry
        let commandStatusRegistry: LastCommandStatusRegistry
        let automationRegistry: AutomationHandleRegistry
    }

    private func makeHarness() -> Harness {
        let store = TileTreeStore()
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

    // MARK: - SurfaceStore as the eviction authority (Phase 5 render-path flip)

    @Test("sync evicts a closed single-pane tab's surface via the unified tile identity")
    func syncEvictsClosedSinglePaneSurface() throws {
        let harness = makeHarness()
        let first = harness.store.activateSession(
            key: .hostPath("/Users/test/a"),
            directory: URL(fileURLWithPath: "/Users/test/a")
        ).session
        let second = try #require(harness.store.createTab())

        // Mount both tabs' surfaces the way the renderer does — by the unified render tile id.
        harness.store.terminalSurfaceView(for: first)
        harness.store.terminalSurfaceView(for: second)
        let firstTile = harness.store.renderTileID(forSession: first)
        let secondTile = harness.store.renderTileID(forSession: second)
        #expect(harness.store.surfaceStore.retainedTileIDs == [firstTile, secondTile])

        // Closing the second tab leaves only the first tab's surface retained — sync, not a scattered
        // invalidate, freed it.
        #expect(harness.store.handleProcessExit(for: second.id))

        #expect(harness.store.surfaceStore.retainedTileIDs == [firstTile])
        #expect(harness.store.surfaceStore.terminal(for: first.id) != nil)
        #expect(harness.store.surfaceStore.terminal(for: second.id) == nil)
    }

    @Test("A split pane's surface is evicted by sync when the pane closes, primary surface intact")
    func syncEvictsClosedSplitSurfaceKeepsPrimary() throws {
        let harness = makeHarness()
        let primary = harness.store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        let split = try #require(harness.store.splitFocusedTile(inTabContaining: primary.id))

        let primaryTile = harness.store.renderTileID(forSession: primary)
        let splitTile = harness.store.renderTileID(forSession: split)
        harness.store.surfaceStore.terminalSurface(for: primaryTile, session: primary)
        harness.store.surfaceStore.terminalSurface(for: splitTile, session: split)
        #expect(harness.store.surfaceStore.retainedTileIDs == [primaryTile, splitTile])

        #expect(harness.store.handleProcessExit(for: split.id))

        #expect(harness.store.surfaceStore.retainedTileIDs == [primaryTile])
        #expect(harness.store.surfaceStore.terminal(for: primary.id) != nil)
        #expect(harness.store.surfaceStore.terminal(for: split.id) == nil)
    }
}
