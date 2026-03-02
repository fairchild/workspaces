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

        let removed = store.handleProcessExit(for: primaryID)

        #expect(removed)
        #expect(store.sessions.isEmpty)
        #expect(store.activeSessionID == nil)
        #expect(store.splitSession(for: primaryID) == nil)
        #expect(store.splitLayout(for: primaryID) == nil)
        #expect(!store.handleProcessExit(for: split.id))
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
}
