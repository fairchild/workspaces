//
//  TileExitClassificationTests.swift
//  WorkspaceManagerAppTests
//
//  What a tile's exit writes on its continuity row, through the store's own exit
//  path. The tmux answer is injected so each reason can be driven; the real tmux
//  reading is covered against an isolated server in TerminalSessionExitTests.
//

import Foundation
import SwiftUI
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("Tile exit classification")
struct TileExitClassificationTests {
    /// Every tmux question the store asked, so a test can assert it asked none.
    private actor ProbeCalls {
        private(set) var sessionNames: [String] = []
        func append(_ name: String) { sessionNames.append(name) }
    }

    private struct Harness {
        let store: TileTreeStore
        let sink: ContinuityWriteLog
        let probeCalls: ProbeCalls
        /// Every tmux session the store asked to kill, by host-session id.
        let reclaims: ProbeCalls

        /// The tmux sessions killed once `count` have been asked for, or every one asked for
        /// within ten seconds. Kills run as main-actor tasks in the order the store enqueues
        /// them, so a later kill arriving proves an earlier settle enqueued none.
        func reclaimed(awaiting count: Int) async -> [String] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while await reclaims.sessionNames.count < count, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await reclaims.sessionNames
        }

        func rowWrites(for sessionID: UUID) async -> [ContinuityWriteOperation] {
            await store.waitForExitClassifications()
            await store.continuityRecorder?.waitUntilDrained()
            return await sink.operations.filter {
                $0 == .ended(sessionID) || $0 == .holderLost(sessionID) || $0 == .deselected(sessionID)
            }
        }
    }

    private let registry = AgentSessionRegistry()

    private func makeHarness(answer: TmuxHolderState) -> Harness {
        let store = TileTreeStore()
        let sink = ContinuityWriteLog()
        let probeCalls = ProbeCalls()
        store.terminalModeForNewSession = { _ in .tmuxPerSession }
        store.continuityRecorder = TerminalContinuityRecorder(sink: sink)
        store.attach(agentSessionRegistry: registry, localStateStore: nil, hooksSocketPath: nil)
        store.tmuxHolderState = { name in
            await probeCalls.append(name)
            return answer
        }
        store.tmuxServerKeepsRunningWhenEmpty = { _ in true }
        let reclaims = ProbeCalls()
        store.terminateOwnedTmuxSession = { hostSessionID in
            await reclaims.append(hostSessionID.uuidString)
            return .notLive
        }
        return Harness(store: store, sink: sink, probeCalls: probeCalls, reclaims: reclaims)
    }

    /// Two tmux tiles in one scope, both launched through tmux.
    private func openTwoTmuxTiles(_ store: TileTreeStore) throws -> (HostTerminalSession, HostTerminalSession) {
        let directory = URL(fileURLWithPath: "/Users/test/code/repo")
        let primary = store.activateSession(key: .repoPath(directory.path), directory: directory).session
        let tab = try #require(store.createTab(from: primary.id))
        for session in [primary, tab] {
            store.surfaceStore.noteLaunch(sessionID: session.id, throughTmux: true)
        }
        return (primary, tab)
    }

    @Test("A tile whose tmux server died keeps its row open, marked holder lost")
    func serverDeathMarksHolderLost() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id))
        #expect(!harness.store.sessions.contains { $0.id == tab.id })

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
        #expect(await harness.probeCalls.sessionNames == [tab.effectiveTmuxSessionName])
    }

    @Test("A shell that exited on the server it launched on ends its row")
    func shellExitOnLiveServerEndsTheRow() async throws {
        let harness = makeHarness(answer: .sessionGone(serverPID: 4242))
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        harness.store.surfaceStore.noteLaunch(sessionID: tab.id, throughTmux: true, tmuxServerPID: 4242)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
    }

    /// The launch learns its server's pid only once the ownership read finds its session. A
    /// server answering before then may be a replacement, so the name missing there leaves
    /// the row as it was.
    @Test("A session missing before the launch's server was recorded leaves the row open")
    func sessionGoneWithoutLaunchServerLeavesTheRowOpen() async throws {
        let harness = makeHarness(answer: .sessionGone(serverPID: 9999))
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.deselected(tab.id)])
    }

    /// Before tmux 2.7 an empty server exits, so a last shell ending takes the server too.
    @Test("A gone server on a tmux not known to keep empty servers leaves the row open, unmarked")
    func goneServerWithoutExitEmptyLeavesTheRowOpen() async throws {
        for keepsRunningWhenEmpty: Bool? in [false, nil] {
            let harness = makeHarness(answer: .serverGone)
            harness.store.tmuxServerKeepsRunningWhenEmpty = { _ in keepsRunningWhenEmpty }
            let (_, tab) = try openTwoTmuxTiles(harness.store)

            #expect(harness.store.handleProcessExit(for: tab.id))

            #expect(await harness.rowWrites(for: tab.id) == [.deselected(tab.id)])
        }
    }

    @Test("A tile the user closed ends its row without asking tmux")
    func userCloseEndsTheRowWithoutAProbe() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id, cause: .userClosed))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.probeCalls.sessionNames.isEmpty)
    }

    @Test("A close the user asked for that arrives as a process exit is still a user close")
    func requestedCloseArrivingAsExitIsTheUsers() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        harness.store.noteCloseRequested(tab.id)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.probeCalls.sessionNames.isEmpty)
    }

    /// The client left a session that is still running. Reattaching on the spot would fight
    /// whoever detached it, so the tile goes and the row stays open for the next launch.
    @Test("A tile whose client detached from a running session leaves its row open")
    func detachLeavesTheRowOpen() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.deselected(tab.id)])
        #expect(!harness.store.sessions.contains { $0.id == tab.id })
    }

    @Test("A tmux-mode tile that launched without tmux ends as a shell exit without asking tmux")
    func tileWithoutRealizedTmuxIsAShellExit() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (primary, tab) = try openTwoTmuxTiles(harness.store)
        harness.store.surfaceStore.noteLaunch(sessionID: tab.id, throughTmux: false)
        _ = primary

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.probeCalls.sessionNames.isEmpty)
    }

    /// The launch script keeps the server running when empty, so a server that is gone was
    /// killed whether or not other tiles were on it.
    @Test("The only tmux tile on a server that was killed keeps its row, marked holder lost")
    func loneTileOnGoneServerLosesItsHolder() async throws {
        let harness = makeHarness(answer: .serverGone)
        let directory = URL(fileURLWithPath: "/Users/test/code/repo")
        let lone = harness.store.activateSession(key: .repoPath(directory.path), directory: directory).session
        harness.store.surfaceStore.noteLaunch(sessionID: lone.id, throughTmux: true)

        #expect(harness.store.handleProcessExit(for: lone.id))

        #expect(await harness.rowWrites(for: lone.id) == [.holderLost(lone.id)])
    }

    @Test("A tile whose tmux server restarted under it loses its holder, though its name is gone")
    func restartedServerIsALostHolder() async throws {
        let harness = makeHarness(answer: .sessionGone(serverPID: 9999))
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        harness.store.surfaceStore.noteLaunch(sessionID: tab.id, throughTmux: true, tmuxServerPID: 4242)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
    }

    @Test("A tmux that does not answer leaves the row open")
    func unansweredProbeLeavesTheRowOpen() async throws {
        let harness = makeHarness(answer: .unanswered)
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.deselected(tab.id)])
    }

    private typealias SplitTab = (
        primary: HostTerminalSession, split: HostTerminalSession, otherTab: HostTerminalSession
    )

    /// A tab with one split pane, and a second tab beside it, all launched through tmux.
    private func openSplitTab(_ store: TileTreeStore) throws -> SplitTab {
        let directory = URL(fileURLWithPath: "/Users/test/code/repo")
        let primary = store.activateSession(key: .repoPath(directory.path), directory: directory).session
        let otherTab = try #require(store.createTab(from: primary.id))
        _ = store.activateExistingSession(sessionID: primary.id)
        let split = try #require(store.splitFocusedTile(inTabContaining: primary.id))
        for session in [primary, split, otherTab] {
            store.surfaceStore.noteLaunch(sessionID: session.id, throughTmux: true, tmuxServerPID: 4242)
        }
        return (primary, split, otherTab)
    }

    /// Detaching leaves the pane's work running, so tearing the pane down with its tab must
    /// not kill it. The later user close of another tab is the first kill to arrive.
    @Test("Split panes torn down with a tab whose client detached stay open and keep their tmux sessions")
    func splitPanesStayOpenWithADetachedTab() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (primary, split, otherTab) = try openSplitTab(harness.store)

        #expect(harness.store.handleProcessExit(for: primary.id))

        #expect(await harness.rowWrites(for: primary.id) == [.deselected(primary.id)])
        #expect(await harness.rowWrites(for: split.id) == [.deselected(split.id)])
        #expect(harness.store.handleProcessExit(for: otherTab.id, cause: .userClosed))
        #expect(await harness.reclaimed(awaiting: 1) == [otherTab.id.uuidString])
    }

    /// An ended row whose pane-scoped session runs on has no way back (#1232), so a tab whose
    /// shell ended closes its panes as closing the tab would.
    @Test("Split panes torn down with a tab whose shell ended end their rows and are reclaimed")
    func splitPanesCloseWithATabWhoseShellEnded() async throws {
        let harness = makeHarness(answer: .sessionGone(serverPID: 4242))
        let (primary, split, _) = try openSplitTab(harness.store)

        #expect(harness.store.handleProcessExit(for: primary.id))

        #expect(await harness.rowWrites(for: primary.id) == [.ended(primary.id)])
        #expect(await harness.rowWrites(for: split.id) == [.ended(split.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [split.id.uuidString])
    }

    /// The pane's close sheet can be answered after its tab has already gone on a process exit.
    /// The close is the person's decision for that pane; the tab's later answer settles only the
    /// rows still waiting.
    @Test("A close that reaches a pane torn down with its tab settles that pane alone")
    func lateCloseOfATornDownPaneSettlesIt() async throws {
        let harness = makeHarness(answer: .serverGone)
        let answer = gateProbe(harness.store)
        let (primary, split, _) = try openSplitTab(harness.store)
        let sibling = try #require(harness.store.splitFocusedTile(inTabContaining: primary.id))
        harness.store.surfaceStore.noteLaunch(sessionID: sibling.id, throughTmux: true, tmuxServerPID: 4242)

        #expect(harness.store.handleProcessExit(for: primary.id))
        #expect(!harness.store.handleProcessExit(for: split.id, cause: .userClosed))
        answer.yield(.serverGone)
        answer.finish()

        #expect(await harness.rowWrites(for: split.id) == [.ended(split.id)])
        #expect(await harness.rowWrites(for: primary.id) == [.holderLost(primary.id)])
        #expect(await harness.rowWrites(for: sibling.id) == [.holderLost(sibling.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [split.id.uuidString])
    }

    @Test("Split panes torn down with a tab whose holder died keep their rows too")
    func splitPanesShareTheirTabsLostHolder() async throws {
        let harness = makeHarness(answer: .serverGone)
        let directory = URL(fileURLWithPath: "/Users/test/code/repo")
        let primary = harness.store.activateSession(key: .repoPath(directory.path), directory: directory).session
        let split = try #require(harness.store.splitFocusedTile(inTabContaining: primary.id))
        for session in [primary, split] {
            harness.store.surfaceStore.noteLaunch(sessionID: session.id, throughTmux: true)
        }

        #expect(harness.store.handleProcessExit(for: primary.id))

        #expect(await harness.rowWrites(for: primary.id) == [.holderLost(primary.id)])
        #expect(await harness.rowWrites(for: split.id) == [.holderLost(split.id)])
    }

    /// An exit reaches the store only through the surface's live view. A surface that was
    /// evicted or replaced has had its exit callback dropped, so its command ending later —
    /// a retired surface's shell or tmux client finishing — says nothing about the tile.
    @Test("An evicted or replaced surface's command exiting leaves the tile and its row alone")
    func retiredSurfaceExitIsIgnored() async throws {
        let harness = makeHarness(answer: .serverGone)
        // The surfaces below are realized, so they launch as Ghostty-split tiles: a tmux-mode
        // surface would start tmux for real. The exit path reads the launch the test notes.
        harness.store.terminalModeForNewSession = { _ in .ghosttyManagedSplits }
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        let store = harness.store
        let tile = store.renderTileID(forSession: tab)
        let wireExit: () -> Void = { _ = store.handleProcessExit(for: tab.id) }

        let evicted = store.surfaceStore.terminalSurface(for: tile, session: tab, onProcessExit: wireExit)
        let evictedExit = try #require(evicted.surfaceView.onProcessExit)
        store.surfaceStore.invalidate(tileID: tile)
        let replaced = store.surfaceStore.terminalSurface(for: tile, session: tab, onProcessExit: wireExit)
        let replacedExit = try #require(replaced.surfaceView.onProcessExit)
        #expect(store.surfaceStore.restartTerminalSurface(for: tile))
        store.surfaceStore.noteLaunch(sessionID: tab.id, throughTmux: true)

        for retired in [evicted, replaced] {
            retired.surfaceView.runtimeDidRequestClose(processAlive: false)
        }
        evictedExit()
        replacedExit()
        for _ in 0..<100 { await Task.yield() }

        #expect(store.sessions.contains { $0.id == tab.id })
        #expect(await harness.rowWrites(for: tab.id).isEmpty)
        #expect(await harness.probeCalls.sessionNames.isEmpty)

        let live = store.surfaceStore.terminalSurface(for: tile, session: tab, onProcessExit: wireExit)
        store.surfaceStore.noteLaunch(sessionID: tab.id, throughTmux: true)
        live.surfaceView.runtimeDidRequestClose(processAlive: false)
        for _ in 0..<100 where store.sessions.contains(where: { $0.id == tab.id }) { await Task.yield() }
        #expect(!store.sessions.contains { $0.id == tab.id })
        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
    }

    /// The tile leaves at once; its row waits for the reason. A row written ended and then
    /// reopened would briefly drop the tile from a restore read, so nothing is written early.
    @Test("No row is written before the exit's reason is known")
    func rowWaitsForTheReason() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (answers, answer) = AsyncStream.makeStream(of: TmuxHolderState.self)
        harness.store.tmuxHolderState = { _ in
            for await state in answers { return state }
            return .unanswered
        }
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id))
        #expect(!harness.store.sessions.contains { $0.id == tab.id })
        await harness.store.continuityRecorder?.waitUntilDrained()
        let beforeAnswer = await harness.sink.operations.filter {
            $0 == .ended(tab.id) || $0 == .holderLost(tab.id) || $0 == .deselected(tab.id)
        }
        #expect(beforeAnswer.isEmpty)

        answer.yield(.serverGone)
        answer.finish()

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
    }

    /// Gates the store's tmux question so a test can act while the answer is still out.
    private func gateProbe(_ store: TileTreeStore) -> AsyncStream<TmuxHolderState>.Continuation {
        let (answers, answer) = AsyncStream.makeStream(of: TmuxHolderState.self)
        store.tmuxHolderState = { _ in
            for await state in answers { return state }
            return .unanswered
        }
        return answer
    }

    @Test("A close that arrives while the exit's reason is still out wins, and the late answer writes nothing")
    func closeDuringClassificationWins() async throws {
        let harness = makeHarness(answer: .serverGone)
        let answer = gateProbe(harness.store)
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id))
        #expect(!harness.store.handleProcessExit(for: tab.id, cause: .userClosed))
        answer.yield(.serverGone)
        answer.finish()

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [tab.id.uuidString])
    }

    /// The close sheet as the main window drives it: one shown confirmation, raised,
    /// dismissed and answered through the terminal session controller.
    @MainActor
    private final class CloseSheet {
        let store: TileTreeStore
        let controller = MainWindowTerminalSessionController()
        var shown: TerminalCloseConfirmation?

        init(_ store: TileTreeStore) {
            self.store = store
        }

        var binding: Binding<TerminalCloseConfirmation?> {
            Binding(get: { self.shown }, set: { self.shown = $0 })
        }

        /// The tile's close asks for confirmation; a sheet already up for another tile goes.
        func raise(_ sessionID: UUID) {
            controller.dismissCloseConfirmation(binding, tileTreeStore: store)
            shown = controller.raiseCloseConfirmation(sessionID: sessionID, tileTreeStore: store)
        }

        func cancel() {
            controller.dismissCloseConfirmation(binding, tileTreeStore: store)
        }

        /// The framework takes the sheet down, as it does for Escape or a lost window.
        func dismissByFramework() {
            controller.closeConfirmationPresented(binding, tileTreeStore: store).wrappedValue = false
        }

        func close() {
            guard let confirmation = MainWindowPresentation.consume(binding) else { return }
            _ = controller.completeCloseConfirmation(
                confirmation, tileTreeStore: store,
                defaultHomeDirectory: URL(fileURLWithPath: "/private/tmp"), repos: [], normalizePath: { $0 })
        }
    }

    /// A close that raised the confirmation sheet belongs to the sheet: a cancelled sheet
    /// leaves the tile, whose later exit is whatever tmux says it was.
    @Test("A cancelled close confirmation leaves the tile's later exit to tmux")
    func cancelledConfirmationLeavesTheExitToTmux() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        let sheet = CloseSheet(harness.store)
        harness.store.noteCloseRequested(tab.id)
        sheet.raise(tab.id)

        sheet.cancel()
        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
    }

    /// Closing two busy tabs raises the sheet for each in turn, and the second replaces the
    /// first. Confirming the second closes it alone; the first, whose client later detaches,
    /// keeps its row.
    @Test("A batch close confirmed for one tab leaves the other tab's later exit to tmux")
    func batchCloseConfirmsOnlyTheShownTab() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (first, second) = try openTwoTmuxTiles(harness.store)
        let store = harness.store
        let sheet = CloseSheet(store)
        store.noteCloseRequested(first.id)
        sheet.raise(first.id)
        store.noteCloseRequested(second.id)
        sheet.raise(second.id)

        sheet.close()
        #expect(store.handleProcessExit(for: first.id))

        #expect(await harness.rowWrites(for: second.id) == [.ended(second.id)])
        #expect(await harness.rowWrites(for: first.id) == [.deselected(first.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [second.id.uuidString])
    }

    /// The pane's sheet is still up when its tab's exit settles the pane as a lost holder.
    /// Confirming it is the person closing that pane: its row ends and its tmux session goes.
    @Test("Confirming a close after the tile's exit settled its row ends the row and reclaims it")
    func confirmedCloseAfterSettlementEndsTheRow() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (primary, split, _) = try openSplitTab(harness.store)
        let sheet = CloseSheet(harness.store)
        harness.store.noteCloseRequested(split.id)
        sheet.raise(split.id)

        #expect(harness.store.handleProcessExit(for: primary.id))
        #expect(await harness.rowWrites(for: split.id) == [.holderLost(split.id)])
        sheet.close()

        #expect(await harness.rowWrites(for: split.id) == [.holderLost(split.id), .ended(split.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [split.id.uuidString])
    }

    @Test("Cancelling a close after the tile's exit settled its row leaves the row as the exit left it")
    func cancelledCloseAfterSettlementLeavesTheRow() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (primary, split, otherTab) = try openSplitTab(harness.store)
        let sheet = CloseSheet(harness.store)
        harness.store.noteCloseRequested(split.id)
        sheet.raise(split.id)

        #expect(harness.store.handleProcessExit(for: primary.id))
        #expect(await harness.rowWrites(for: split.id) == [.holderLost(split.id)])
        let cancelled = try #require(sheet.shown).context
        sheet.cancel()
        #expect(!harness.store.completeCloseConfirmation(cancelled))
        #expect(harness.store.handleProcessExit(for: otherTab.id, cause: .userClosed))

        #expect(await harness.rowWrites(for: split.id) == [.holderLost(split.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [otherTab.id.uuidString])
    }

    /// Where a tab's exit stands when the person confirms closing the whole tab.
    enum ConfirmedTabClose: CaseIterable {
        case beforeTheExit, whileTheExitIsRead, afterTheExitSettled
    }

    /// Closing a tab closes its split panes. The sheet was raised for the whole tab, so its
    /// Close ends every pane's row and reclaims every pane's tmux session, wherever the tab's
    /// own exit had got to.
    @Test(
        "Confirming a whole tab's close ends and reclaims its split panes wherever its exit stands",
        arguments: ConfirmedTabClose.allCases)
    func confirmedTabCloseEndsItsSplits(_ moment: ConfirmedTabClose) async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let answer = gateProbe(harness.store)
        let (primary, split, _) = try openSplitTab(harness.store)
        let store = harness.store
        let sheet = CloseSheet(store)
        store.noteCloseRequested(primary.id)
        sheet.raise(primary.id)

        switch moment {
        case .beforeTheExit:
            sheet.close()
        case .whileTheExitIsRead:
            #expect(store.handleProcessExit(for: primary.id))
            sheet.close()
        case .afterTheExitSettled:
            #expect(store.handleProcessExit(for: primary.id))
            answer.yield(.sessionPresent(serverPID: 4242))
            #expect(await harness.rowWrites(for: split.id) == [.deselected(split.id)])
            sheet.close()
        }
        answer.yield(.sessionPresent(serverPID: 4242))
        answer.finish()

        #expect(await harness.rowWrites(for: primary.id).last == .ended(primary.id))
        #expect(await harness.rowWrites(for: split.id).last == .ended(split.id))
        #expect(await harness.reclaimed(awaiting: 1) == [split.id.uuidString])
    }

    /// Cancelling names the confirmation it cancels: a sheet raised again for the same tile
    /// owns the close, and an older sheet going away leaves it.
    @Test("Cancelling an older confirmation leaves a newer one for the same tile in charge")
    func staleCancelLeavesTheNewerConfirmation() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        let store = harness.store
        let older = store.raiseCloseConfirmation(for: tab.id)
        let newer = store.raiseCloseConfirmation(for: tab.id)

        store.cancelCloseConfirmation(older)
        #expect(store.handleProcessExit(for: tab.id))
        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
        #expect(!store.completeCloseConfirmation(older))
        #expect(!store.completeCloseConfirmation(newer))

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id), .ended(tab.id)])
    }

    /// A sheet the framework takes down, by Escape or with its window, was not answered with
    /// Close, so it gives up the close it owned.
    @Test("A close sheet dismissed by the framework gives up its close")
    func frameworkDismissalCancelsTheClose() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (primary, split, otherTab) = try openSplitTab(harness.store)
        let store = harness.store
        let sheet = CloseSheet(store)
        store.noteCloseRequested(primary.id)
        sheet.raise(primary.id)
        let dismissed = try #require(sheet.shown).context

        sheet.dismissByFramework()
        #expect(sheet.shown == nil)
        #expect(store.handleProcessExit(for: primary.id))
        #expect(await harness.rowWrites(for: split.id) == [.deselected(split.id)])
        #expect(!store.completeCloseConfirmation(dismissed))
        #expect(store.handleProcessExit(for: otherTab.id, cause: .userClosed))

        #expect(await harness.rowWrites(for: primary.id) == [.deselected(primary.id)])
        #expect(await harness.rowWrites(for: split.id) == [.deselected(split.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [otherTab.id.uuidString])
    }

    /// The split detached and was adopted again as a tab of its own: a different tile now
    /// holds its session. The old sheet's Close is about the tab as it was, so it closes the
    /// tab and leaves the adopted tile, its row and its tmux session alone.
    @Test("Confirming a tab leaves a split that another tile has since adopted")
    func confirmedTabCloseLeavesAnAdoptedSplit() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (primary, split, otherTab) = try openSplitTab(harness.store)
        let store = harness.store
        let sheet = CloseSheet(store)
        store.noteCloseRequested(primary.id)
        sheet.raise(primary.id)
        #expect(store.handleProcessExit(for: split.id))
        #expect(await harness.rowWrites(for: split.id) == [.deselected(split.id)])
        let adopted = store.createRestoredSession(
            key: split.key, directory: split.directoryURL, recordedTerminalMode: split.terminalMode,
            tmuxSessionNameOverride: split.tmuxSessionName, adoptedHostSessionID: split.id)

        sheet.close()
        #expect(store.handleProcessExit(for: otherTab.id, cause: .userClosed))

        #expect(await harness.rowWrites(for: primary.id) == [.ended(primary.id)])
        #expect(await harness.rowWrites(for: split.id) == [.deselected(split.id)])
        #expect(store.allLiveSessions.contains { $0.id == adopted.id })
        #expect(await harness.reclaimed(awaiting: 1) == [otherTab.id.uuidString])
    }

    /// The tab's exit settled while its sheet was up, and a restore brought its session back
    /// in a new tile that has since gained a pane of its own. The old sheet's Close ends the
    /// rows it covered that no tile holds, and touches neither the new tile nor its pane.
    @Test("Confirming a tab's old sheet leaves a new tile holding its session, and that tile's panes")
    func confirmedTabCloseLeavesAReplacementTile() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (primary, oldSplit, _) = try openSplitTab(harness.store)
        let store = harness.store
        let sheet = CloseSheet(store)
        store.noteCloseRequested(primary.id)
        sheet.raise(primary.id)
        #expect(store.handleProcessExit(for: primary.id))
        #expect(await harness.rowWrites(for: primary.id) == [.deselected(primary.id)])
        let replacement = store.createRestoredSession(
            key: primary.key, directory: primary.directoryURL, recordedTerminalMode: primary.terminalMode,
            tmuxSessionNameOverride: primary.tmuxSessionName, adoptedHostSessionID: primary.id)
        let newSplit = try #require(store.splitFocusedTile(inTabContaining: replacement.id))

        sheet.close()

        #expect(await harness.rowWrites(for: primary.id) == [.deselected(primary.id)])
        #expect(await harness.rowWrites(for: newSplit.id) == [])
        #expect(store.allLiveSessions.contains { $0.id == newSplit.id })
        #expect(await harness.rowWrites(for: oldSplit.id) == [.deselected(oldSplit.id), .ended(oldSplit.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [oldSplit.id.uuidString])
    }

    /// A split the person closed, or whose shell ended, already has its row ended. Confirming
    /// the tab afterwards ends the rest of the tab and neither writes nor reclaims that split
    /// again.
    @Test("Confirming a tab leaves a split another reason already ended", arguments: [true, false])
    func confirmedTabCloseSkipsAnEndedSplit(_ splitClosedByThePerson: Bool) async throws {
        let harness = makeHarness(answer: .sessionGone(serverPID: 4242))
        let (primary, split, otherTab) = try openSplitTab(harness.store)
        let store = harness.store
        let sheet = CloseSheet(store)
        sheet.raise(primary.id)
        #expect(store.handleProcessExit(for: split.id, cause: splitClosedByThePerson ? .userClosed : nil))
        #expect(await harness.rowWrites(for: split.id) == [.ended(split.id)])

        sheet.close()
        #expect(store.handleProcessExit(for: otherTab.id, cause: .userClosed))

        #expect(await harness.rowWrites(for: split.id) == [.ended(split.id)])
        #expect(await harness.rowWrites(for: primary.id) == [.ended(primary.id)])
        let expected = (splitClosedByThePerson ? [split.id.uuidString] : []) + [otherTab.id.uuidString]
        #expect(await harness.reclaimed(awaiting: expected.count) == expected)
    }

    /// A sheet raised again for the same tile owns its close; the older one's Close is stale.
    @Test("A superseded sheet's Close closes nothing")
    func supersededSheetClosesNothing() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (primary, _, _) = try openSplitTab(harness.store)
        let store = harness.store
        let first = CloseSheet(store)
        let second = CloseSheet(store)
        first.raise(primary.id)
        let added = try #require(store.splitFocusedTile(inTabContaining: primary.id))
        second.raise(primary.id)

        first.close()

        #expect(store.allLiveSessions.contains { $0.id == primary.id })
        #expect(await harness.rowWrites(for: added.id) == [])
        #expect(second.shown != nil)
    }

    /// The sheet asked about the tab as it was. A pane added while it was up was never part
    /// of the question, so Close leaves the tab open rather than end that pane unasked.
    @Test("Confirming a tab that gained a pane after its sheet was raised closes nothing")
    func confirmedTabCloseRefusesAGrownTab() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (primary, split, _) = try openSplitTab(harness.store)
        let store = harness.store
        let sheet = CloseSheet(store)
        sheet.raise(primary.id)
        let added = try #require(store.splitFocusedTile(inTabContaining: primary.id))

        sheet.close()

        #expect(store.allLiveSessions.contains { $0.id == primary.id })
        #expect(store.allLiveSessions.contains { $0.id == added.id })
        #expect(await harness.rowWrites(for: split.id) == [])
        #expect(await harness.rowWrites(for: added.id) == [])
    }

    @Test("A retirement that lands as a process exit ends the row, asks tmux nothing and kills nothing")
    func retirementArrivingAsExitEndsTheRow() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        harness.store.noteCloseRequested(tab.id, as: .retired)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.probeCalls.sessionNames.isEmpty)
        #expect(await harness.reclaims.sessionNames.isEmpty)
    }

    /// A retirement that fails leaves the tile in place. Its request must not outlive it, or
    /// the tile's next exit, whatever it was, would end its row as retired.
    @Test("A retirement that fails withdraws its reason, so the tile's later exit is read from tmux")
    func failedRetirementWithdrawsItsReason() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        harness.store.closeSurfaceForRetirement = { _ in
            throw GhosttySurfaceRetirementCloseError.processStillRunning(title: "tab")
        }

        await #expect(throws: GhosttySurfaceRetirementCloseError.self) {
            try await harness.store.closeForRetirement(sessionID: tab.id)
        }
        #expect(harness.store.sessions.contains { $0.id == tab.id })
        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
    }

    /// A withdrawal names the request it made. A close the person asked for while the
    /// retirement was failing is newer, and stays.
    @Test("A failed retirement leaves a newer close request in place")
    func failedRetirementLeavesANewerRequest() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        let store = harness.store
        store.closeSurfaceForRetirement = { sessionID in
            store.noteCloseRequested(sessionID)
            throw GhosttySurfaceRetirementCloseError.processStillRunning(title: "tab")
        }

        await #expect(throws: GhosttySurfaceRetirementCloseError.self) {
            try await store.closeForRetirement(sessionID: tab.id)
        }
        #expect(store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.reclaimed(awaiting: 1) == [tab.id.uuidString])
        #expect(await harness.probeCalls.sessionNames.isEmpty)
    }

    /// The close sheet's Cancel withdraws its own close; a retirement in flight is the
    /// retiring scope's, and still reads as one.
    @Test("Cancelling a close confirmation leaves a retirement's request in place")
    func cancellingTheSheetKeepsARetirement() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (primary, tab) = try openTwoTmuxTiles(harness.store)
        let sheet = CloseSheet(harness.store)
        harness.store.noteCloseRequested(tab.id, as: .retired)

        sheet.raise(primary.id)
        sheet.cancel()
        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.probeCalls.sessionNames.isEmpty)
    }

    /// Teardown wired to the store as the app wires it, closing `session` alone.
    private func teardown(
        _ session: HostTerminalSession, in store: TileTreeStore, tmuxKilled: Bool,
        beforeAttempt: @escaping @MainActor (Int) -> Void
    ) -> WorkspaceTerminalTeardownController {
        var attempts = 0
        var controller = WorkspaceTerminalTeardownController(
            sessionsInScope: { _ in [session] },
            killTmuxSession: { _ in tmuxKilled },
            closeForRetirement: { sessionID in
                attempts += 1
                beforeAttempt(attempts)
                try await store.closeForRetirement(sessionID: sessionID, holdingRequestOnFailure: true)
            },
            abandonRetirement: { store.abandonRetirement($0) },
            retireSessions: { _ in [] }
        )
        controller.killedProcessExitBudget = .seconds(3600)
        controller.closeRetryInterval = .milliseconds(1)
        return controller
    }

    /// Teardown retries a close whose killed tmux client is still exiting, and the tile's exit
    /// can land between two attempts. It is still the retirement.
    @Test("A tile's exit between teardown's close attempts ends its row as retired, asking tmux nothing")
    func exitBetweenRetirementAttemptsIsTheRetirement() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        let store = harness.store
        store.closeSurfaceForRetirement = { _ in
            throw GhosttySurfaceRetirementCloseError.processStillRunning(title: "tab")
        }
        let controller = teardown(tab, in: store, tmuxKilled: true) { attempt in
            if attempt == 2 {
                store.handleProcessExit(for: tab.id)
            }
        }

        _ = await controller.teardown(scopeKey: tab.key)

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
        #expect(await harness.probeCalls.sessionNames.isEmpty)
        #expect(await harness.reclaims.sessionNames.isEmpty)
    }

    /// A blocked teardown leaves the tile in place, so its later exit is read from tmux.
    @Test("A tile left by a blocked teardown has its later exit read from tmux")
    func blockedTeardownWithdrawsTheRetirement() async throws {
        let harness = makeHarness(answer: .serverGone)
        let (_, tab) = try openTwoTmuxTiles(harness.store)
        let store = harness.store
        store.closeSurfaceForRetirement = { _ in
            throw GhosttySurfaceRetirementCloseError.processStillRunning(title: "tab")
        }

        let outcome = await teardown(tab, in: store, tmuxKilled: false) { _ in }.teardown(scopeKey: tab.key)
        guard case .closeBlockedByConfirmation = outcome else {
            Issue.record("expected close_blocked_by_confirmation, got \(outcome)")
            return
        }
        #expect(store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
    }
}
