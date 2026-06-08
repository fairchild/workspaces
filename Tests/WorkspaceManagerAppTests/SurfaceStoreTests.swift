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
