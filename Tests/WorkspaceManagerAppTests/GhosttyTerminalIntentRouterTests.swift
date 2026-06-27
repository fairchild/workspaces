import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("GhosttyTerminalIntentRouter")
struct GhosttyTerminalIntentRouterTests {
    private let router = GhosttyTerminalIntentRouter()

    @Test("new split creates a split and returns delayed focus")
    func newSplitCreatesSplitAndReturnsDelayedFocus() throws {
        let store = makeStore()
        let primaryID = try #require(store.activeSessionID)

        let effects = router.route(
            .split(.newSplit(direction: .right)),
            sourceSessionID: nil,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store
        )

        let split = try #require(store.splitSession(for: primaryID))
        #expect(store.splitLayout(for: primaryID) == .defaultTrailing)
        #expect(effects == [.delayedFocus(split.id, delay: GhosttyTerminalIntentRouter.splitFocusDelay)])
    }

    @Test("split intents are ignored outside Ghostty-managed split mode")
    func splitIntentsAreIgnoredOutsideGhosttyManagedMode() throws {
        let store = makeStore()
        let primaryID = try #require(store.activeSessionID)

        let effects = router.route(
            .split(.newSplit(direction: .right)),
            sourceSessionID: nil,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )

        #expect(effects.isEmpty)
        #expect(store.sessions.count == 1)
        #expect(store.activeSessionID == primaryID)
        #expect(store.splitSession(for: primaryID) == nil)
    }

    @Test("goto split returns focus for paired pane")
    func gotoSplitReturnsFocusForPairedPane() throws {
        let store = makeStore()
        let primary = try #require(store.sessions.first)
        let split = try #require(store.splitFocusedTile(inTabContaining: primary.id))

        let effects = router.route(
            .split(.gotoSplit(direction: .right)),
            sourceSessionID: primary.id,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store
        )

        #expect(effects == [.focus(split.id)])
        #expect(store.activeSessionID == primary.id)
    }

    @Test("resize split updates split fraction")
    func resizeSplitUpdatesSplitFraction() throws {
        let store = makeStore()
        let primary = try #require(store.sessions.first)
        let split = try #require(store.splitFocusedTile(inTabContaining: primary.id))

        let effects = router.route(
            .split(.resizeSplit(direction: .left, amount: 100)),
            sourceSessionID: split.id,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store
        )

        #expect(effects.isEmpty)
        #expect(store.splitFraction(for: primary.id) == 0.45)
    }

    @Test("equalize splits resets split fraction")
    func equalizeSplitsResetsSplitFraction() throws {
        let store = makeStore()
        let primary = try #require(store.sessions.first)
        let split = try #require(store.splitFocusedTile(inTabContaining: primary.id))
        #expect(store.updateSplitFraction(0.7, forPrimarySessionID: primary.id))

        let effects = router.route(
            .split(.equalizeSplits),
            sourceSessionID: split.id,
            terminalMultiplexingMode: .ghosttyManagedSplits,
            hostTerminalState: store
        )

        #expect(effects.isEmpty)
        #expect(store.splitFraction(for: primary.id) == HostTerminalStateStore.defaultSplitFraction)
    }

    @Test("new tab duplicates source tab and returns focus")
    func newTabDuplicatesSourceTabAndReturnsFocus() throws {
        let store = makeStore()
        let first = try #require(store.sessions.first)

        let effects = router.route(
            .tab(.newTab),
            sourceSessionID: first.id,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )

        #expect(store.sessions.count == 2)
        #expect(store.sessions[1].key == first.key)
        #expect(effects == [.focus(store.sessions[1].id)])
    }

    @Test("close tab returns resolved close request")
    func closeTabReturnsResolvedCloseRequest() throws {
        let store = makeStore()
        _ = try #require(store.sessions.first)
        let second = try #require(store.createTab())
        let third = try #require(store.createTab())

        let effects = router.route(
            .tab(.closeTab(mode: .right)),
            sourceSessionID: second.id,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )

        #expect(effects == [.closeTabs([third.id])])
    }

    @Test("goto tab activates next previous and indexed targets")
    func gotoTabActivatesTargets() throws {
        let store = makeStore()
        let first = try #require(store.sessions.first)
        let second = try #require(store.createTab())
        let third = try #require(store.createTab())

        let nextEffects = router.route(
            .tab(.gotoTab(target: .next)),
            sourceSessionID: second.id,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )
        let previousEffects = router.route(
            .tab(.gotoTab(target: .previous)),
            sourceSessionID: second.id,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )
        let indexedEffects = router.route(
            .tab(.gotoTab(target: .index(1))),
            sourceSessionID: second.id,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )

        #expect(nextEffects == [.focus(third.id)])
        #expect(previousEffects == [.focus(first.id)])
        #expect(indexedEffects == [.focus(first.id)])
    }

    @Test("move tab reorders source tab and returns active focus")
    func moveTabReordersSourceTabAndReturnsActiveFocus() throws {
        let store = makeStore()
        let first = try #require(store.sessions.first)
        let second = try #require(store.createTab())

        let effects = router.route(
            .tab(.moveTab(amount: -1)),
            sourceSessionID: second.id,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )

        #expect(store.sessions.map(\.id) == [second.id, first.id])
        #expect(effects == [.focus(second.id)])
    }

    @Test("set tab title updates primary tab")
    func setTabTitleUpdatesPrimaryTab() throws {
        let store = makeStore()
        let primary = try #require(store.sessions.first)
        let split = try #require(store.splitFocusedTile(inTabContaining: primary.id))

        let effects = router.route(
            .tab(.setTabTitle("CI")),
            sourceSessionID: split.id,
            terminalMultiplexingMode: .tmuxPerSession,
            hostTerminalState: store
        )

        #expect(effects.isEmpty)
        #expect(store.tabTitleOverride(for: primary.id) == "CI")
    }

    private func makeStore() -> HostTerminalStateStore {
        let store = HostTerminalStateStore()
        _ = store.activateSession(
            key: .repoPath("/Users/test/repo"),
            directory: URL(fileURLWithPath: "/Users/test/repo")
        )
        return store
    }
}
