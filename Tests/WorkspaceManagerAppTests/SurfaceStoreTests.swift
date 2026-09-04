import AppKit
import Foundation
import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@MainActor
@Suite("SurfaceStore")
struct SurfaceStoreTests {
    @Test("Creating a terminal surface retains it by tile and fires onSurfaceCreated once")
    func createTerminalSurfaceRetainsAndNotifies() {
        let store = SurfaceStore()
        var created: [TileID] = []
        store.onSurfaceCreated = { created.append($0) }

        let tile = TileID()
        let surface = store.terminalSurface(for: tile, session: makeSession())

        #expect(store.retainedTileIDs == [tile])
        #expect(created == [tile])
        #expect(store.surface(for: tile) === surface)
    }

    @Test("Requesting the same tile reuses the surface without re-notifying")
    func reuseSameTileReturnsSameInstance() {
        let store = SurfaceStore()
        var created: [TileID] = []
        store.onSurfaceCreated = { created.append($0) }

        let tile = TileID()
        let session = makeSession()
        let first = store.terminalSurface(for: tile, session: session)
        let second = store.terminalSurface(for: tile, session: session)

        #expect(first === second)
        #expect(created == [tile])
    }

    @Test("Rebinding a tile to a new session evicts the old surface and rebinds the resolver")
    func rebindTileToNewSessionReplacesSurface() {
        let store = SurfaceStore()
        var invalidated: [TileID] = []
        store.onSurfaceInvalidated = { invalidated.append($0) }

        let tile = TileID()
        let firstSession = makeSession(path: "/Users/test/first")
        let secondSession = makeSession(path: "/Users/test/second")

        let firstSurface = store.terminalSurface(for: tile, session: firstSession)
        let firstView = firstSurface.surfaceView
        let secondSurface = store.terminalSurface(for: tile, session: secondSession)

        #expect(secondSurface !== firstSurface)
        #expect(invalidated == [tile])
        #expect(store.retainedTileIDs == [tile])
        #expect(store.sessionID(for: secondSurface.surfaceView) == secondSession.id)
        // The old view's identity must no longer resolve — the reason the guard exists.
        #expect(store.sessionID(for: firstView) == nil)
    }

    @Test("Resolver maps a surface view back to its session and tile")
    func resolverMapsViewToSessionAndTile() {
        let store = SurfaceStore()
        let tile = TileID()
        let session = makeSession()
        let surface = store.terminalSurface(for: tile, session: session)

        #expect(store.sessionID(for: surface.surfaceView) == session.id)
        #expect(store.tileID(for: surface.surfaceView) == tile)

        let unknownView = GhosttySurfaceView(workingDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(store.sessionID(for: unknownView) == nil)
        #expect(store.tileID(for: unknownView) == nil)
    }

    @Test("Invalidate evicts the surface and fires onSurfaceInvalidated")
    func invalidateEvictsAndNotifies() {
        let store = SurfaceStore()
        var invalidated: [TileID] = []
        store.onSurfaceInvalidated = { invalidated.append($0) }

        let tile = TileID()
        store.terminalSurface(for: tile, session: makeSession())
        store.invalidate(tileID: tile)

        #expect(store.retainedTileIDs.isEmpty)
        #expect(invalidated == [tile])
        #expect(store.surface(for: tile) == nil)

        // Second invalidate of an absent tile is a no-op (no duplicate notification).
        store.invalidate(tileID: tile)
        #expect(invalidated == [tile])
    }

    @Test("sync retains live leaves and tears down the rest")
    func syncRetainsLiveLeavesEvictsStale() {
        let store = SurfaceStore()
        var invalidated: Set<TileID> = []
        store.onSurfaceInvalidated = { invalidated.insert($0) }

        let keep = TileID()
        let dropA = TileID()
        let dropB = TileID()
        store.terminalSurface(for: keep, session: makeSession(path: "/Users/test/keep"))
        store.terminalSurface(for: dropA, session: makeSession(path: "/Users/test/a"))
        store.terminalSurface(for: dropB, session: makeSession(path: "/Users/test/b"))

        store.sync(activeLeafIDs: [keep])

        #expect(store.retainedTileIDs == [keep])
        #expect(invalidated == [dropA, dropB])
    }

    @Test("displayTitle falls back to the session directory, nil for an unknown tile")
    func displayTitleDirectoryFallback() {
        let store = SurfaceStore()
        let tile = TileID()
        store.terminalSurface(for: tile, session: makeSession(path: "/Users/test/myrepo"))

        #expect(store.displayTitle(for: tile) == "myrepo")
        #expect(store.displayTitle(for: TileID()) == nil)
    }

    // MARK: - Session-keyed facade (Phase 5: keeps the focus coordinator / OSC / tab strip session-keyed)

    @Test("Session-keyed terminal(for:) resolves a tile's view, nil for an unknown session")
    func sessionKeyedTerminalResolvesView() {
        let store = SurfaceStore()
        let tile = TileID()
        let session = makeSession()
        let surface = store.terminalSurface(for: tile, session: session)

        #expect(store.terminal(for: session.id) === surface.surfaceView)
        #expect(store.terminal(for: UUID()) == nil)
    }

    @Test("Session-keyed displayTitle resolves by session id with a directory fallback")
    func sessionKeyedDisplayTitle() {
        let store = SurfaceStore()
        let session = makeSession(path: "/Users/test/myrepo")
        store.terminalSurface(for: TileID(), session: session)

        #expect(store.displayTitle(for: session) == "myrepo")
        // A session with no mounted surface falls back to its own directory name.
        #expect(store.displayTitle(for: makeSession(path: "/Users/test/other")) == "other")
    }

    @Test("Terminal create / evict fire the session-keyed mirror callbacks")
    func sessionKeyedCreateAndInvalidateCallbacks() {
        let store = SurfaceStore()
        var created: [UUID] = []
        var invalidated: [UUID] = []
        store.onTerminalSurfaceCreated = { created.append($0) }
        store.onTerminalSurfaceInvalidated = { invalidated.append($0) }

        let tile = TileID()
        let session = makeSession()
        store.terminalSurface(for: tile, session: session)
        #expect(created == [session.id])
        #expect(invalidated.isEmpty)

        store.invalidate(tileID: tile)
        #expect(invalidated == [session.id])
    }

    @Test("sync fires the session-keyed invalidation mirror for every evicted terminal")
    func syncFiresSessionKeyedInvalidationForEvictedTiles() {
        let store = SurfaceStore()
        var invalidated: Set<UUID> = []
        store.onTerminalSurfaceInvalidated = { invalidated.insert($0) }

        let keep = TileID()
        let drop = TileID()
        let keepSession = makeSession(path: "/Users/test/keep")
        let dropSession = makeSession(path: "/Users/test/drop")
        store.terminalSurface(for: keep, session: keepSession)
        store.terminalSurface(for: drop, session: dropSession)

        store.sync(activeLeafIDs: [keep])

        #expect(invalidated == [dropSession.id])
        #expect(store.terminal(for: keepSession.id) != nil)
        #expect(store.terminal(for: dropSession.id) == nil)
    }

    @Test("Terminal title changes fire onTerminalTitleChanged keyed by session")
    func titleChangeFiresSessionKeyedHook() {
        let store = SurfaceStore()
        var titled: [UUID] = []
        store.onTerminalTitleChanged = { titled.append($0) }

        let session = makeSession()
        let surface = store.terminalSurface(for: TileID(), session: session)
        surface.surfaceView.updateTerminalTitle("Build")

        #expect(titled == [session.id])
    }

    // MARK: - Initial-command delivery on a shared tmux socket (#1267)

    @Test("A surface that adopted its tmux session prefills its command instead of running it")
    func adoptedTmuxSessionDowngradesExecuteToPrefill() {
        let store = SurfaceStore()
        let ledger = TmuxSessionOwnershipLedger()
        store.tmuxOwnershipLedger = ledger
        let session = makeSession(delivery: .execute)

        ledger.record(
            hostSessionID: session.id,
            identity: liveSession(createdAt: Date(timeIntervalSince1970: 1_000)),
            launchedAt: Date(timeIntervalSince1970: 2_000)
        )

        #expect(store.deliveryForLaunch(session: session, isTmuxBacked: true) == .prefill)
    }

    @Test("A surface that created its tmux session runs its command as asked")
    func createdTmuxSessionKeepsExecute() {
        let store = SurfaceStore()
        let ledger = TmuxSessionOwnershipLedger()
        store.tmuxOwnershipLedger = ledger
        let session = makeSession(delivery: .execute)

        ledger.record(
            hostSessionID: session.id,
            identity: liveSession(createdAt: Date(timeIntervalSince1970: 2_000)),
            launchedAt: Date(timeIntervalSince1970: 2_000)
        )

        #expect(store.deliveryForLaunch(session: session, isTmuxBacked: true) == .execute)
    }

    @Test("No ownership record is not evidence of adoption, so the command still runs")
    func unrecordedSessionKeepsExecute() {
        let store = SurfaceStore()
        store.tmuxOwnershipLedger = TmuxSessionOwnershipLedger()
        let session = makeSession(delivery: .execute)

        #expect(store.deliveryForLaunch(session: session, isTmuxBacked: true) == .execute)
    }

    @Test("A non-tmux surface is unaffected by an adoption record")
    func nonTmuxSurfaceKeepsExecute() {
        let store = SurfaceStore()
        let ledger = TmuxSessionOwnershipLedger()
        store.tmuxOwnershipLedger = ledger
        let session = makeSession(delivery: .execute)

        ledger.record(
            hostSessionID: session.id,
            identity: liveSession(createdAt: Date(timeIntervalSince1970: 1_000)),
            launchedAt: Date(timeIntervalSince1970: 2_000)
        )

        #expect(store.deliveryForLaunch(session: session, isTmuxBacked: false) == .execute)
    }

    @Test("A session that asked to prefill is never upgraded")
    func prefillStaysPrefill() {
        let store = SurfaceStore()
        let ledger = TmuxSessionOwnershipLedger()
        store.tmuxOwnershipLedger = ledger
        let session = makeSession(delivery: .prefill)

        ledger.record(
            hostSessionID: session.id,
            identity: liveSession(createdAt: Date(timeIntervalSince1970: 2_000)),
            launchedAt: Date(timeIntervalSince1970: 2_000)
        )

        #expect(store.deliveryForLaunch(session: session, isTmuxBacked: true) == .prefill)
    }

    private func liveSession(createdAt: Date) -> TmuxLiveSession {
        TmuxLiveSession(
            sessionID: "$0",
            name: "wm-repo-abcd1234",
            createdAt: createdAt,
            serverPID: 4242
        )
    }

    private func makeSession(
        path: String = "/Users/test/repo",
        delivery: HostTerminalSession.InitialCommandDelivery
    ) -> HostTerminalSession {
        HostTerminalSession(
            key: .repoPath(path),
            directory: URL(fileURLWithPath: path),
            initialCommand: "claude --resume",
            initialCommandDelivery: delivery
        )
    }

    private func makeSession(path: String = "/Users/test/repo") -> HostTerminalSession {
        HostTerminalSession(key: .repoPath(path), directory: URL(fileURLWithPath: path))
    }
}

@MainActor
@Suite("Surface conformers")
struct SurfaceConformerTests {
    @Test("TerminalSurface vends its libghostty view and reports terminal kind")
    func terminalSurfaceShape() {
        let tile = TileID()
        let session = HostTerminalSession(
            key: .repoPath("/Users/test/proj"),
            directory: URL(fileURLWithPath: "/Users/test/proj")
        )
        let surface = TerminalSurface(tileID: tile, session: session, hooksSocketPath: nil)

        #expect(surface.kind == .terminal)
        #expect(surface.tileID == tile)
        #expect(surface.makeContentView() === surface.surfaceView)
        #expect(surface.displayTitle == "proj")
    }

    @Test("TerminalSurface tearDown detaches the view from its superview")
    func terminalSurfaceTearDownDetachesView() {
        let tile = TileID()
        let session = HostTerminalSession(
            key: .repoPath("/Users/test/proj"),
            directory: URL(fileURLWithPath: "/Users/test/proj")
        )
        let surface = TerminalSurface(tileID: tile, session: session, hooksSocketPath: nil)

        let container = NSView()
        container.addSubview(surface.surfaceView)
        #expect(surface.surfaceView.superview === container)

        surface.tearDown()
        #expect(surface.surfaceView.superview == nil)
    }

    @Test("Web surfaces share one store per source across rebinds — flip-back keeps the live page")
    func webStoreSharedPerSourceAcrossRebinds() {
        let store = SurfaceStore()
        let tile = TileID()
        let sourceA = makeWebSource(name: "A", host: "a.example.com")
        let sourceB = makeWebSource(name: "B", host: "b.example.com")

        let surfaceA = store.webSurface(for: tile, source: sourceA)
        let webViewA = surfaceA.webView
        let storeA = store.webStore(forSourceID: sourceA.id)
        #expect(storeA.hasActiveSurface)

        // Rebinding the tile to B evicts A's surface (identity guard) but A's page release is
        // deferred — the web half of the per-conformer eviction policy.
        let surfaceB = store.webSurface(for: tile, source: sourceB)
        #expect(surfaceB !== surfaceA)
        #expect(store.webStore(forSourceID: sourceB.id) !== storeA)
        #expect(storeA.hasActiveSurface)

        // Rebinding back to A inside the grace window resumes the same live web view — no reload.
        let surfaceA2 = store.webSurface(for: tile, source: sourceA)
        #expect(surfaceA2 !== surfaceA)
        #expect(surfaceA2.webView === webViewA)
    }

    @Test("Web eviction defers release; releaseWebResources frees immediately and drops the store")
    func webEvictionPolicyAndHardRelease() {
        let store = SurfaceStore()
        let tile = TileID()
        let source = makeWebSource(name: "Docs", host: "docs.example.com")

        let surface = store.webSurface(for: tile, source: source)
        _ = surface.webView
        let webStore = store.webStore(forSourceID: source.id)
        #expect(webStore.hasActiveSurface)

        store.invalidate(tileID: tile)
        #expect(store.surface(for: tile) == nil)
        #expect(webStore.hasActiveSurface)

        store.releaseWebResources(forSourceID: source.id)
        #expect(!webStore.hasActiveSurface)
        #expect(store.webStore(forSourceID: source.id) !== webStore)
    }

    @Test("Lingering web pages are capped LRU — rapid source switching cannot pile up WKWebViews")
    func lingeringWebPagesCappedLRU() {
        let store = SurfaceStore()
        let tile = TileID()
        let sources = (0..<6).map { makeWebSource(name: "S\($0)", host: "s\($0).example.com") }

        // Visit each source on the same tile, instantiating its page (as mounting would).
        for source in sources {
            _ = store.webSurface(for: tile, source: source).webView
        }

        // The bound tile holds the last source; lingering (unbound, live-page) sources are capped.
        let lingering = sources.dropLast().filter {
            store.webStore(forSourceID: $0.id).hasActiveSurface
        }
        #expect(lingering.count == 3)
        // LRU: the survivors are the most recently visited, the oldest were hard-released.
        #expect(lingering.map(\.name) == ["S2", "S3", "S4"])
        #expect(!store.webStore(forSourceID: sources[0].id).hasActiveSurface)

        // Flip-back inside the cap still resumes the live page.
        let s4View = store.webStore(forSourceID: sources[4].id).ensureSurface(for: sources[4])
        #expect(store.webSurface(for: tile, source: sources[4]).webView === s4View)
    }

    private func makeWebSource(name: String, host: String) -> WebSource {
        WebSource(name: name, baseURLString: "https://\(host)", allowedHost: host)
    }

    @Test("WebSurface carries no agent coupling and titles from its source")
    func webSurfaceShape() {
        let tile = TileID()
        let source = WebSource(
            name: "Docs",
            baseURLString: "https://docs.example.com",
            allowedHost: "docs.example.com"
        )
        let surface = WebSurface(tileID: tile, source: source)

        #expect(surface.kind == .web)
        #expect(surface.tileID == tile)
        #expect(surface.displayTitle == "Docs")

        // tearDown is safe before any web view has been instantiated.
        surface.tearDown()
    }
}
