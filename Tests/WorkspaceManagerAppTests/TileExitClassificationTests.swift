//
//  TileExitClassificationTests.swift
//  WorkspaceManagerAppTests
//
//  What a tile's exit writes on its continuity row, through the store's own exit
//  path. The tmux answer is injected so each reason can be driven; the real tmux
//  reading is covered against an isolated server in TerminalSessionExitTests.
//

import Foundation
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

        func rowWrites(for sessionID: UUID) async -> [ContinuityWriteOperation] {
            await store.waitForExitClassifications()
            await store.continuityRecorder?.waitUntilDrained()
            return await sink.operations.filter {
                $0 == .ended(sessionID) || $0 == .holderLost(sessionID)
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
        store.terminateOwnedTmuxSession = { _ in .notLive }
        return Harness(store: store, sink: sink, probeCalls: probeCalls)
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

    @Test("A shell that exited on a live server ends its row")
    func shellExitOnLiveServerEndsTheRow() async throws {
        let harness = makeHarness(answer: .sessionGone(serverPID: 4242))
        let (_, tab) = try openTwoTmuxTiles(harness.store)

        #expect(harness.store.handleProcessExit(for: tab.id))

        #expect(await harness.rowWrites(for: tab.id) == [.ended(tab.id)])
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

        #expect(await harness.rowWrites(for: tab.id).isEmpty)
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

        #expect(await harness.rowWrites(for: tab.id).isEmpty)
    }

    @Test("Split panes torn down with a tab whose client detached stay open with it")
    func splitPanesStayOpenWithADetachedTab() async throws {
        let harness = makeHarness(answer: .sessionPresent(serverPID: 4242))
        let directory = URL(fileURLWithPath: "/Users/test/code/repo")
        let primary = harness.store.activateSession(key: .repoPath(directory.path), directory: directory).session
        let split = try #require(harness.store.splitFocusedTile(inTabContaining: primary.id))
        for session in [primary, split] {
            harness.store.surfaceStore.noteLaunch(sessionID: session.id, throughTmux: true)
        }

        #expect(harness.store.handleProcessExit(for: primary.id))

        #expect(await harness.rowWrites(for: primary.id).isEmpty)
        #expect(await harness.rowWrites(for: split.id).isEmpty)
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
            $0 == .ended(tab.id) || $0 == .holderLost(tab.id)
        }
        #expect(beforeAnswer.isEmpty)

        answer.yield(.serverGone)
        answer.finish()

        #expect(await harness.rowWrites(for: tab.id) == [.holderLost(tab.id)])
    }
}
