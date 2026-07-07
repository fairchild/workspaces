//
//  TileTreeStoreTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies split layout and directional focus behavior for host terminal splits.
//

import Combine
import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("TileTreeStore")
struct TileTreeStoreTests {
    @Test("Creating a tab duplicates the active session without reusing by path")
    func createTabDuplicatesActiveSessionWithoutReusingByPath() throws {
        let store = TileTreeStore()
        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo")
        let first = store.activateSession(
            key: .repoPath(repoURL.path),
            directory: repoURL
        ).session

        let second = try #require(store.createTab())

        #expect(store.sessions.count == 2)
        #expect(second.id != first.id)
        #expect(second.key == first.key)
        #expect(second.directoryPath == first.directoryPath)
        #expect(store.activeSessionID == second.id)
    }

    @Test("Adjacent tab activation wraps in both directions")
    func adjacentTabActivationWraps() throws {
        let store = TileTreeStore()
        let first = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let second = try #require(store.createTab())

        #expect(store.activateAdjacentTab(offset: 1)?.id == first.id)
        #expect(store.activateAdjacentTab(offset: -1)?.id == second.id)
    }

    @Test("Moving tabs reorders sessions and keeps moved tab active")
    func movingTabsReordersSessions() throws {
        let store = TileTreeStore()
        let first = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let second = try #require(store.createTab())
        let third = try #require(store.createTab())

        #expect(store.moveTab(containing: third.id, offset: -2))

        #expect(store.sessions.map(\.id) == [third.id, first.id, second.id])
        #expect(store.activeSessionID == third.id)
    }

    @Test("Tab title overrides are scoped to primary sessions")
    func tabTitleOverridesAreScopedToPrimarySessions() throws {
        let store = TileTreeStore()
        let primary = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let split = try #require(store.splitFocusedTile(inTabContaining: primary.id))

        #expect(store.setTabTitle("Build", for: split.id))
        #expect(store.tabTitleOverride(for: primary.id) == "Build")
    }

    @Test("Tab title overrides trim and clear empty titles")
    func tabTitleOverridesTrimAndClearEmptyTitles() {
        let store = TileTreeStore()
        let session = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session

        #expect(store.setTabTitle("  Build  ", for: session.id))
        #expect(store.tabTitleOverride(for: session.id) == "Build")

        #expect(store.setTabTitle("   ", for: session.id))
        #expect(store.tabTitleOverride(for: session.id) == nil)
    }

    @Test("Surface title changes publish host terminal state updates")
    func surfaceTitleChangesPublishHostTerminalStateUpdates() {
        let store = TileTreeStore()
        let session = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let terminal = store.terminalSurfaceView(for: session)

        var emissions = 0
        let cancellable = store.objectWillChange.sink { _ in
            emissions += 1
        }
        defer { cancellable.cancel() }

        terminal.updateTerminalTitle("Build")

        #expect(store.surfaceStore.displayTitle(for: session) == "Build")
        #expect(emissions == 1)

        terminal.updateTerminalTitle("Build")
        #expect(emissions == 1)
    }

    @Test("Close tab candidates support this other and right")
    func closeTabCandidatesSupportModes() throws {
        let store = TileTreeStore()
        let first = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let second = try #require(store.createTab())
        let third = try #require(store.createTab())

        #expect(store.tabIDsForClose(mode: .this, sourceSessionID: second.id) == [second.id])
        #expect(store.tabIDsForClose(mode: .other, sourceSessionID: second.id) == [first.id, third.id])
        #expect(store.tabIDsForClose(mode: .right, sourceSessionID: second.id) == [third.id])
    }

    @Test("Scoped sessions follow the active terminal scope")
    func scopedSessionsFollowActiveScope() throws {
        let store = TileTreeStore()
        let home = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let secondHomeTab = try #require(store.createTab())
        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo")
        let repo = store.activateSession(
            key: .repoPath(repoURL.path),
            directory: repoURL
        ).session
        let secondRepoTab = try #require(store.createTab())

        #expect(store.scopedSessions.map(\.id) == [repo.id, secondRepoTab.id])

        #expect(store.activateExistingSession(sessionID: secondHomeTab.id))
        #expect(store.scopedSessions.map(\.id) == [home.id, secondHomeTab.id])
    }

    @Test("Active session lookup restores the active backend scope tab")
    func activeSessionLookupRestoresActiveBackendScopeTab() throws {
        let store = TileTreeStore()
        let backendKey = HostTerminalSessionKey.backendSession(providerID: "lume", instanceID: "vm-123")
        _ =
            store.activateSession(
                key: backendKey,
                directory: URL(fileURLWithPath: "/tmp/workspaces/vm-123"),
                customCommand: "/usr/local/bin/lume ssh vm-123"
            ).session
        let secondBackendTab = try #require(store.createTab())
        _ =
            store.activateSession(
                key: .defaultHome,
                directory: URL(fileURLWithPath: "/Users/test")
            ).session

        let activeBackendTab = try #require(store.activeSession(inScope: backendKey))

        #expect(activeBackendTab.id == secondBackendTab.id)
        #expect(store.activateExistingSession(sessionID: activeBackendTab.id))
        #expect(store.activeSessionID == secondBackendTab.id)
    }

    @Test("Close other and right candidates stay within the source scope")
    func closeCandidatesStayWithinSourceScope() throws {
        let store = TileTreeStore()
        _ =
            store.activateSession(
                key: .defaultHome,
                directory: URL(fileURLWithPath: "/Users/test")
            ).session
        _ = try #require(store.createTab())

        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo")
        let firstRepoTab = store.activateSession(
            key: .repoPath(repoURL.path),
            directory: repoURL
        ).session
        let secondRepoTab = try #require(store.createTab())
        let thirdRepoTab = try #require(store.createTab())

        #expect(
            store.tabIDsForClose(mode: .other, sourceSessionID: secondRepoTab.id) == [
                firstRepoTab.id,
                thirdRepoTab.id,
            ])
        #expect(store.tabIDsForClose(mode: .right, sourceSessionID: secondRepoTab.id) == [thirdRepoTab.id])
    }

    @Test("Splitting stores the preferred top-bottom layout")
    func splitStoresPreferredLayout() {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )

        let preferredLayout = TileTreeStore.SplitPaneLayout(
            axis: .topBottom,
            splitBeforePrimary: false
        )
        let split = store.splitFocusedTile(
            inTabContaining: activation.session.id,
            preferredLayout: preferredLayout
        )

        #expect(split != nil)
        #expect(store.splitLayout(for: activation.session.id) == preferredLayout)
        #expect(store.splitFraction(for: activation.session.id) == TileTreeStore.defaultSplitFraction)
    }

    @Test("Split fraction updates clamp to supported bounds")
    func splitFractionUpdatesClampToSupportedBounds() {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        _ = store.splitFocusedTile(
            inTabContaining: primaryID,
            preferredLayout: .defaultTrailing
        )

        #expect(store.updateSplitFraction(0.95, forPrimarySessionID: primaryID))
        #expect(store.splitFraction(for: primaryID) == 0.8)

        #expect(store.updateSplitFraction(0.01, forPrimarySessionID: primaryID))
        #expect(store.splitFraction(for: primaryID) == 0.2)
    }

    @Test("Equalize split resets fraction to default")
    func equalizeSplitResetsFractionToDefault() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.splitFocusedTile(
                inTabContaining: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        #expect(store.updateSplitFraction(0.7, forPrimarySessionID: primaryID))
        #expect(store.equalizeSplit(containing: split.id))
        #expect(store.splitFraction(for: primaryID) == TileTreeStore.defaultSplitFraction)
    }

    @Test("Resize split grows trailing pane for left action from trailing split")
    func resizeSplitGrowsTrailingPaneForLeftAction() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.splitFocusedTile(
                inTabContaining: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        #expect(store.resizeSplit(containing: split.id, direction: .left, amount: 100))
        #expect(store.splitFraction(for: primaryID) == 0.45)
    }

    @Test("Resize split ignores orthogonal and outer-edge directions")
    func resizeSplitIgnoresOrthogonalAndOuterEdgeDirections() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.splitFocusedTile(
                inTabContaining: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        #expect(!store.resizeSplit(containing: split.id, direction: .up, amount: 100))
        #expect(!store.resizeSplit(containing: primaryID, direction: .left, amount: 100))
        #expect(store.splitFraction(for: primaryID) == TileTreeStore.defaultSplitFraction)
    }

    @Test("Directional focus follows top-bottom split layout")
    func directionalFocusFollowsTopBottomLayout() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let splitLayout = TileTreeStore.SplitPaneLayout(
            axis: .topBottom,
            splitBeforePrimary: false
        )
        let split = store.splitFocusedTile(
            inTabContaining: primaryID,
            preferredLayout: splitLayout
        )

        let splitID = try #require(split?.id)
        #expect(store.splitFocusTarget(from: primaryID, direction: .down) == splitID)
        #expect(store.splitFocusTarget(from: primaryID, direction: .right) == nil)
        #expect(store.splitFocusTarget(from: splitID, direction: .up) == primaryID)
    }

    @Test("Process exit in split pane keeps primary session alive")
    func processExitInSplitKeepsPrimarySessionAlive() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let split = try #require(
            store.splitFocusedTile(
                inTabContaining: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        let removed = store.handleProcessExit(for: split.id)

        #expect(removed)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == primaryID)
        #expect(store.activeSessionID == primaryID)
        #expect(store.splitSession(for: primaryID) == nil)
        #expect(store.splitLayout(for: primaryID) == nil)
    }

    @Test("Process exit in primary pane removes attached split session")
    func processExitInPrimaryRemovesSplitSession() throws {
        let store = TileTreeStore()
        let registry = AgentSessionRegistry()
        let commandStatusRegistry = LastCommandStatusRegistry()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        store.attach(
            agentSessionRegistry: registry,
            localStateStore: nil,
            hooksSocketPath: nil,
            lastCommandStatusRegistry: commandStatusRegistry
        )

        let split = try #require(
            store.splitFocusedTile(
                inTabContaining: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        // The split session is registered alongside the primary before exit.
        #expect(registry.statuses[split.id] != nil)
        commandStatusRegistry.ingest(markers: [.commandStart], for: split.id, commandLine: "make")
        #expect(commandStatusRegistry.statusByTerminalSession[split.id] != nil)

        let removed = store.handleProcessExit(for: primaryID)

        #expect(removed)
        #expect(store.sessions.isEmpty)
        #expect(store.activeSessionID == nil)
        #expect(store.splitSession(for: primaryID) == nil)
        #expect(store.splitLayout(for: primaryID) == nil)
        #expect(!store.handleProcessExit(for: split.id))

        // Closing the primary tears the split session down with it.
        #expect(registry.statuses[primaryID] == nil)
        #expect(registry.statuses[split.id] == nil)
        #expect(commandStatusRegistry.statusByTerminalSession[split.id] == nil)
    }

    @Test("Process exit of active primary falls back to remaining session")
    func processExitPrimaryFallsBackToRemainingSession() throws {
        let store = TileTreeStore()
        let defaultHome = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        let repoSession = store.activateSession(
            key: .repoPath("/Users/test/code/repo"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo")
        ).session
        _ = try #require(
            store.splitFocusedTile(
                inTabContaining: repoSession.id,
                preferredLayout: .defaultTrailing
            )
        )

        #expect(store.activeSessionID == repoSession.id)

        let removed = store.handleProcessExit(for: repoSession.id)

        #expect(removed)
        #expect(store.sessions.count == 1)
        #expect(store.sessions.first?.id == defaultHome.id)
        #expect(store.activeSessionID == defaultHome.id)
        #expect(store.splitSession(for: repoSession.id) == nil)
        #expect(store.splitLayout(for: repoSession.id) == nil)
    }

    @Test("Process exit for unknown session is a no-op")
    func processExitUnknownSessionIsNoOp() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.splitFocusedTile(
                inTabContaining: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        let sessionsBefore = store.sessions
        let activeBefore = store.activeSessionID

        let removed = store.handleProcessExit(for: UUID())

        #expect(!removed)
        #expect(store.sessions == sessionsBefore)
        #expect(store.activeSessionID == activeBefore)
        #expect(store.splitSession(for: primaryID)?.id == split.id)
        #expect(store.splitLayout(for: primaryID) == .defaultTrailing)
    }

    @Test("Process exit helper creates default-home session when none remain")
    func processExitHelperCreatesDefaultHomeFallback() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let focusTarget = store.handleProcessExitAndResolveFocusTarget(
            for: primaryID,
            defaultHomeDirectory: URL(fileURLWithPath: "/Users/test/code")
        )

        let focusSessionID = try #require(focusTarget)
        #expect(store.sessions.count == 1)
        #expect(store.activeSessionID == focusSessionID)
        #expect(store.sessions.first?.id == focusSessionID)
        #expect(store.sessions.first?.key == .defaultHome)
    }

    @Test("Attaching the agent registry registers existing and new host sessions")
    func attachRegistersHostSessionsWithAgentRegistry() throws {
        let store = TileTreeStore()
        let repoURL = URL(fileURLWithPath: "/Users/test/code/repo")
        let pre = store.activateSession(key: .repoPath(repoURL.path), directory: repoURL).session

        let registry = AgentSessionRegistry()
        let commandStatusRegistry = LastCommandStatusRegistry()
        store.attach(
            agentSessionRegistry: registry,
            localStateStore: nil,
            hooksSocketPath: nil,
            lastCommandStatusRegistry: commandStatusRegistry
        )

        // Backfill: pre-existing session is registered on attach.
        #expect(registry.statuses[pre.id] != nil)
        #expect(registry.statuses[pre.id]?.kind == .claudeCode)
        #expect(registry.statuses[pre.id]?.cwd.contains("/repo") == true)

        // Newly created session also registers via publishSnapshot.
        let next = store.activateSession(
            key: .repoPath("/Users/test/code/another"),
            directory: URL(fileURLWithPath: "/Users/test/code/another")
        ).session
        #expect(registry.statuses[next.id] != nil)
        #expect(registry.statuses[pre.id] != nil)

        commandStatusRegistry.ingest(markers: [.commandStart], for: pre.id, commandLine: "make")
        #expect(commandStatusRegistry.statusByTerminalSession[pre.id] != nil)

        // Process exit deregisters.
        _ = store.handleProcessExit(for: pre.id)
        #expect(registry.statuses[pre.id] == nil)
        #expect(registry.statuses[next.id] != nil)
        #expect(commandStatusRegistry.statusByTerminalSession[pre.id] == nil)
    }

    @Test("Retiring a workspace scope removes primary tabs, splits, and registry state")
    func retiringWorkspaceScopeRemovesSessionsAndRegistryState() throws {
        let store = TileTreeStore()
        let defaultHome = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let workspaceURL = URL(fileURLWithPath: "/Users/test/code/repo/workspaces/feature-a")
        let firstWorkspaceTab = store.activateSession(
            key: .hostPath(workspaceURL.path),
            directory: workspaceURL
        ).session
        let secondWorkspaceTab = try #require(store.createTab())
        let split = try #require(store.splitFocusedTile(inTabContaining: firstWorkspaceTab.id))

        let registry = AgentSessionRegistry()
        let commandStatusRegistry = LastCommandStatusRegistry()
        store.attach(
            agentSessionRegistry: registry,
            localStateStore: nil,
            hooksSocketPath: nil,
            lastCommandStatusRegistry: commandStatusRegistry
        )
        commandStatusRegistry.ingest(markers: [.commandStart], for: firstWorkspaceTab.id, commandLine: "make")
        commandStatusRegistry.ingest(markers: [.commandStart], for: split.id, commandLine: "claude")

        let retired = store.retireSessions(inScope: .hostPath(workspaceURL.path))

        #expect(Set(retired) == Set([split.id, firstWorkspaceTab.id, secondWorkspaceTab.id]))
        #expect(store.sessions.map(\.id) == [defaultHome.id])
        #expect(store.activeSessionID == defaultHome.id)
        #expect(store.splitSession(for: firstWorkspaceTab.id) == nil)
        #expect(registry.statuses[firstWorkspaceTab.id] == nil)
        #expect(registry.statuses[secondWorkspaceTab.id] == nil)
        #expect(registry.statuses[split.id] == nil)
        #expect(registry.statuses[defaultHome.id] != nil)
        #expect(commandStatusRegistry.statusByTerminalSession[firstWorkspaceTab.id] == nil)
        #expect(commandStatusRegistry.statusByTerminalSession[split.id] == nil)
    }

    @Test("Process exit helper returns active fallback session when others remain")
    func processExitHelperReturnsRemainingActiveSession() throws {
        let store = TileTreeStore()
        let defaultHome = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        let repoSession = store.activateSession(
            key: .repoPath("/Users/test/code/repo"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo")
        ).session

        let focusTarget = store.handleProcessExitAndResolveFocusTarget(
            for: repoSession.id,
            defaultHomeDirectory: URL(fileURLWithPath: "/Users/test/code")
        )

        #expect(focusTarget == defaultHome.id)
        #expect(store.sessions.count == 1)
        #expect(store.activeSessionID == defaultHome.id)
        #expect(store.sessions.first?.id == defaultHome.id)
    }

    @Test("Splitting registers the split session and tears it down on split exit")
    func splitRegistersSplitSessionLifecycle() throws {
        let store = TileTreeStore()
        let registry = AgentSessionRegistry()
        let commandStatusRegistry = LastCommandStatusRegistry()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        store.attach(
            agentSessionRegistry: registry,
            localStateStore: nil,
            hooksSocketPath: nil,
            lastCommandStatusRegistry: commandStatusRegistry
        )

        let split = try #require(
            store.splitFocusedTile(
                inTabContaining: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        // Creating the split registers it in the agent registry next to the primary.
        #expect(registry.statuses[primaryID] != nil)
        #expect(registry.statuses[split.id] != nil)
        #expect(registry.statuses[split.id]?.cwd == activation.session.directoryPath)

        commandStatusRegistry.ingest(markers: [.commandStart], for: split.id, commandLine: "make")
        #expect(commandStatusRegistry.statusByTerminalSession[split.id] != nil)

        // Exiting the split deregisters it and clears its command status, primary untouched.
        #expect(store.handleProcessExit(for: split.id))
        #expect(registry.statuses[split.id] == nil)
        #expect(commandStatusRegistry.statusByTerminalSession[split.id] == nil)
        #expect(registry.statuses[primaryID] != nil)
    }

    @Test("Splitting the focused tile grows the tree to three distinct panes")
    func splittingFocusedTileGrowsTree() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let splitA = try #require(
            store.splitFocusedTile(inTabContaining: primaryID, preferredLayout: .defaultTrailing)
        )
        // The new pane is now focused/source; splitting it again deepens the tree rather than relaying.
        let splitB = try #require(
            store.splitFocusedTile(inTabContaining: splitA.id, preferredLayout: .defaultTrailing)
        )

        #expect(splitB.id != splitA.id)
        let tree = try #require(store.tileTree(forPrimarySessionID: primaryID))
        #expect(tree.leafIDs.count == 3)

        let leafSessionIDs = tree.leafIDs.compactMap { store.session(forTile: $0)?.id }
        #expect(Set(leafSessionIDs) == Set([primaryID, splitA.id, splitB.id]))
    }

    @Test("Every split pane registers with the agent registry at depth ≥ 2")
    func depthTwoRegistersEverySplitSession() throws {
        let store = TileTreeStore()
        let registry = AgentSessionRegistry()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        store.attach(agentSessionRegistry: registry, localStateStore: nil, hooksSocketPath: nil)

        let splitA = try #require(store.splitFocusedTile(inTabContaining: primaryID))
        let splitB = try #require(store.splitFocusedTile(inTabContaining: splitA.id))

        // The derived split-session set is every non-primary leaf, so both deep panes are registered.
        #expect(registry.statuses[primaryID] != nil)
        #expect(registry.statuses[splitA.id] != nil)
        #expect(registry.statuses[splitB.id] != nil)

        // Collapsing the tab tears every pane down with it.
        #expect(store.handleProcessExit(for: primaryID))
        #expect(registry.statuses[splitA.id] == nil)
        #expect(registry.statuses[splitB.id] == nil)
    }

    @Test("Resize targets the split enclosing the source pane, not the root")
    func resizeTargetsEnclosingSplit() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        // [primary | A], then split A top/bottom → primary beside an (A over B) column.
        let splitA = try #require(
            store.splitFocusedTile(inTabContaining: primaryID, preferredLayout: .defaultTrailing)
        )
        let splitB = try #require(
            store.splitFocusedTile(
                inTabContaining: splitA.id,
                preferredLayout: TileTreeStore.SplitPaneLayout(axis: .topBottom, splitBeforePrimary: false)
            )
        )

        // Growing B upward resizes the inner top/bottom split; the root left/right split is untouched.
        #expect(store.resizeSplit(containing: splitB.id, direction: .up, amount: 100))

        let tree = try #require(store.tileTree(forPrimarySessionID: primaryID))
        guard case .split(_, .leadingTrailing, let rootRatio, _, let second) = tree.root else {
            Issue.record("Expected a leading/trailing root split")
            return
        }
        #expect(rootRatio == 0.5)
        guard case .split(_, .topBottom, let innerRatio, _, _) = second else {
            Issue.record("Expected a top/bottom inner split")
            return
        }
        #expect(innerRatio == 0.45)
    }

    @Test("Relative split focus cycles through every pane in order")
    func relativeFocusCyclesAllPanes() throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let splitA = try #require(store.splitFocusedTile(inTabContaining: primaryID))
        let splitB = try #require(store.splitFocusedTile(inTabContaining: splitA.id))

        // Depth-first leaf order is [primary, A, B]; next wraps, previous walks back.
        #expect(store.splitFocusTarget(from: primaryID, direction: .next) == splitA.id)
        #expect(store.splitFocusTarget(from: splitA.id, direction: .next) == splitB.id)
        #expect(store.splitFocusTarget(from: splitB.id, direction: .next) == primaryID)
        #expect(store.splitFocusTarget(from: primaryID, direction: .previous) == splitB.id)
    }

    @Test(
        "Split layout projects every axis and order combination",
        arguments: [
            TileTreeStore.SplitPaneLayout(axis: .leadingTrailing, splitBeforePrimary: false),
            TileTreeStore.SplitPaneLayout(axis: .leadingTrailing, splitBeforePrimary: true),
            TileTreeStore.SplitPaneLayout(axis: .topBottom, splitBeforePrimary: false),
            TileTreeStore.SplitPaneLayout(axis: .topBottom, splitBeforePrimary: true),
        ]
    )
    func splitLayoutProjectsEveryCombination(layout: TileTreeStore.SplitPaneLayout) throws {
        let store = TileTreeStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        _ = try #require(store.splitFocusedTile(inTabContaining: primaryID, preferredLayout: layout))

        #expect(store.splitLayout(for: primaryID) == layout)
        #expect(store.splitFraction(for: primaryID) == TileTreeStore.defaultSplitFraction)
    }

    @Test("Closing one pane of three rebalances the tree instead of collapsing it")
    func closingOnePaneOfThreeRebalances() throws {
        let store = TileTreeStore()
        let registry = AgentSessionRegistry()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        store.attach(agentSessionRegistry: registry, localStateStore: nil, hooksSocketPath: nil)

        let splitA = try #require(store.splitFocusedTile(inTabContaining: primaryID))
        let splitB = try #require(store.splitFocusedTile(inTabContaining: splitA.id))

        // Closing B (process exit) leaves primary + A, not a bare single pane.
        #expect(store.handleProcessExit(for: splitB.id))
        let afterClose = try #require(store.tileTree(forPrimarySessionID: primaryID))
        #expect(afterClose.leafIDs.count == 2)
        #expect(
            Set(afterClose.leafIDs.compactMap { store.session(forTile: $0)?.id })
                == Set([primaryID, splitA.id])
        )
        #expect(registry.statuses[splitB.id] == nil)
        #expect(registry.statuses[splitA.id] != nil)

        // Closing the last split pane collapses the tab to the sparse single-pane shape.
        #expect(store.handleProcessExit(for: splitA.id))
        #expect(store.tileTree(forPrimarySessionID: primaryID) == nil)
        #expect(store.sessions.map(\.id) == [primaryID])
        #expect(registry.statuses[splitA.id] == nil)
        #expect(registry.statuses[primaryID] != nil)
    }
}
