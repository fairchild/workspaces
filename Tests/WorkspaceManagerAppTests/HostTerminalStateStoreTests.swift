//
//  HostTerminalStateStoreTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies split layout and directional focus behavior for host terminal splits.
//

import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("HostTerminalStateStore")
struct HostTerminalStateStoreTests {
    @Test("Creating a tab duplicates the active session without reusing by path")
    func createTabDuplicatesActiveSessionWithoutReusingByPath() throws {
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
        let primary = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test")
        ).session
        let split = try #require(store.ensureSplit(forPrimarySessionID: primary.id))

        #expect(store.setTabTitle("Build", for: split.id))
        #expect(store.tabTitleOverride(for: primary.id) == "Build")
    }

    @Test("Close tab candidates support this other and right")
    func closeTabCandidatesSupportModes() throws {
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
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

    @Test("ensureSplit stores preferred top-bottom layout")
    func ensureSplitStoresPreferredLayout() {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )

        let preferredLayout = HostTerminalStateStore.SplitPaneLayout(
            axis: .topBottom,
            splitBeforePrimary: false
        )
        let split = store.ensureSplit(
            forPrimarySessionID: activation.session.id,
            preferredLayout: preferredLayout
        )

        #expect(split != nil)
        #expect(store.splitLayout(for: activation.session.id) == preferredLayout)
        #expect(store.splitFraction(for: activation.session.id) == HostTerminalStateStore.defaultSplitFraction)
    }

    @Test("Split fraction updates clamp to supported bounds")
    func splitFractionUpdatesClampToSupportedBounds() {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        _ = store.ensureSplit(
            forPrimarySessionID: primaryID,
            preferredLayout: .defaultTrailing
        )

        #expect(store.updateSplitFraction(0.95, forPrimarySessionID: primaryID))
        #expect(store.splitFraction(for: primaryID) == 0.8)

        #expect(store.updateSplitFraction(0.01, forPrimarySessionID: primaryID))
        #expect(store.splitFraction(for: primaryID) == 0.2)
    }

    @Test("Equalize split resets fraction to default")
    func equalizeSplitResetsFractionToDefault() throws {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.ensureSplit(
                forPrimarySessionID: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        #expect(store.updateSplitFraction(0.7, forPrimarySessionID: primaryID))
        #expect(store.equalizeSplit(containing: split.id))
        #expect(store.splitFraction(for: primaryID) == HostTerminalStateStore.defaultSplitFraction)
    }

    @Test("Resize split grows trailing pane for left action from trailing split")
    func resizeSplitGrowsTrailingPaneForLeftAction() throws {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.ensureSplit(
                forPrimarySessionID: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        #expect(store.resizeSplit(containing: split.id, direction: .left, amount: 100))
        #expect(store.splitFraction(for: primaryID) == 0.45)
    }

    @Test("Resize split ignores orthogonal and outer-edge directions")
    func resizeSplitIgnoresOrthogonalAndOuterEdgeDirections() throws {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.ensureSplit(
                forPrimarySessionID: primaryID,
                preferredLayout: .defaultTrailing
            )
        )

        #expect(!store.resizeSplit(containing: split.id, direction: .up, amount: 100))
        #expect(!store.resizeSplit(containing: primaryID, direction: .left, amount: 100))
        #expect(store.splitFraction(for: primaryID) == HostTerminalStateStore.defaultSplitFraction)
    }

    @Test("Directional focus follows top-bottom split layout")
    func directionalFocusFollowsTopBottomLayout() throws {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let splitLayout = HostTerminalStateStore.SplitPaneLayout(
            axis: .topBottom,
            splitBeforePrimary: false
        )
        let split = store.ensureSplit(
            forPrimarySessionID: primaryID,
            preferredLayout: splitLayout
        )

        let splitID = try #require(split?.id)
        #expect(store.splitFocusTarget(from: primaryID, direction: .down) == splitID)
        #expect(store.splitFocusTarget(from: primaryID, direction: .right) == nil)
        #expect(store.splitFocusTarget(from: splitID, direction: .up) == primaryID)
    }

    @Test("Process exit in split pane keeps primary session alive")
    func processExitInSplitKeepsPrimarySessionAlive() throws {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let split = try #require(
            store.ensureSplit(
                forPrimarySessionID: primaryID,
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
        let store = HostTerminalStateStore()
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
            store.ensureSplit(
                forPrimarySessionID: primaryID,
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
        let store = HostTerminalStateStore()
        let defaultHome = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        ).session
        let repoSession = store.activateSession(
            key: .repoPath("/Users/test/code/repo"),
            directory: URL(fileURLWithPath: "/Users/test/code/repo")
        ).session
        _ = try #require(
            store.ensureSplit(
                forPrimarySessionID: repoSession.id,
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
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id
        let split = try #require(
            store.ensureSplit(
                forPrimarySessionID: primaryID,
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
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
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
        let store = HostTerminalStateStore()
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
        let split = try #require(store.ensureSplit(forPrimarySessionID: firstWorkspaceTab.id))

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
        let store = HostTerminalStateStore()
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

    @Test("ensureSplit registers the split session and tears it down on split exit")
    func ensureSplitRegistersSplitSessionLifecycle() throws {
        let store = HostTerminalStateStore()
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
            store.ensureSplit(
                forPrimarySessionID: primaryID,
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

    @Test("ensureSplit relayout preserves split-session identity and fraction")
    func ensureSplitRelayoutPreservesIdentityAndFraction() throws {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        let split = try #require(
            store.ensureSplit(forPrimarySessionID: primaryID, preferredLayout: .defaultTrailing)
        )
        #expect(store.updateSplitFraction(0.7, forPrimarySessionID: primaryID))

        let relaidOut = HostTerminalStateStore.SplitPaneLayout(axis: .topBottom, splitBeforePrimary: true)
        let after = try #require(
            store.ensureSplit(forPrimarySessionID: primaryID, preferredLayout: relaidOut)
        )

        // Same live split session — a fresh tile/session would orphan the running terminal.
        #expect(after.id == split.id)
        #expect(store.splitSession(for: primaryID)?.id == split.id)
        // Relayout swaps axis/order but leaves the existing fraction in place.
        #expect(store.splitLayout(for: primaryID) == relaidOut)
        #expect(store.splitFraction(for: primaryID) == 0.7)
    }

    @Test(
        "Split layout projects every axis and order combination",
        arguments: [
            HostTerminalStateStore.SplitPaneLayout(axis: .leadingTrailing, splitBeforePrimary: false),
            HostTerminalStateStore.SplitPaneLayout(axis: .leadingTrailing, splitBeforePrimary: true),
            HostTerminalStateStore.SplitPaneLayout(axis: .topBottom, splitBeforePrimary: false),
            HostTerminalStateStore.SplitPaneLayout(axis: .topBottom, splitBeforePrimary: true),
        ]
    )
    func splitLayoutProjectsEveryCombination(layout: HostTerminalStateStore.SplitPaneLayout) throws {
        let store = HostTerminalStateStore()
        let activation = store.activateSession(
            key: .defaultHome,
            directory: URL(fileURLWithPath: "/Users/test/code")
        )
        let primaryID = activation.session.id

        _ = try #require(store.ensureSplit(forPrimarySessionID: primaryID, preferredLayout: layout))

        #expect(store.splitLayout(for: primaryID) == layout)
        #expect(store.splitFraction(for: primaryID) == HostTerminalStateStore.defaultSplitFraction)
    }
}
