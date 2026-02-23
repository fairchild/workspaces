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
}
