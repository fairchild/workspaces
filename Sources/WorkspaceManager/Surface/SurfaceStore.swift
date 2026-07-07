import AppKit
import WorkspaceManagerCore

/// Owns the live `Surface` for each `TileID` in a tile tree: a `[TileID: any Surface]` map plus a
/// session-keyed facade (surface-view → session lookup, terminal-by-session resolution, display
/// titles, create/invalidate callbacks) for the consumers that still address terminals by
/// `HostTerminalSession.id` — the focus coordinator, OSC routing, and the tab strip.
///
/// The live surface owner of the main terminal column: the recursive renderer vends every tile's
/// surface here, and `sync(activeLeafIDs:)` is the single eviction authority — `TileTreeStore`
/// calls it after each tree mutation, so a leaf leaving the tree is the one trigger for surface
/// teardown (the agent-domain teardown bundle stays paired in the store via `syncRegistry`).
@MainActor
final class SurfaceStore {
    private var surfaces: [TileID: any Surface] = [:]

    /// Shared-per-source web view stores (the Phase 6 decision from the PR #633 review): a
    /// `WebSurfaceStore` — and its `WKWebView` — belongs to the `WebSource`, not to any one tile
    /// binding, so an evicted web surface's page survives the release grace window and a re-bound
    /// tile picks it up without a reload. Entries are dropped by `releaseWebResources(forSourceID:)`
    /// (source deleted); an idle entry otherwise holds no `WKWebView` after its deferred release fires.
    private var webStoresBySourceID: [UUID: WebSurfaceStore] = [:]

    /// Forwarded to terminal surfaces at creation so libghostty can reach the agent hook socket.
    var hooksSocketPath: String?
    /// Forwarded to terminal surfaces at creation so tile-local processes can reach the Automation
    /// API with an opaque capability handle.
    var automationEnvironmentProvider: ((HostTerminalSession) -> AutomationTerminalEnvironment?)?

    /// Fired when a surface is first created for a tile (drives focus-coordinator readiness).
    var onSurfaceCreated: (@MainActor (TileID) -> Void)?
    /// Fired when a surface is evicted for a tile (process exit, close, or `sync` diff).
    var onSurfaceInvalidated: (@MainActor (TileID) -> Void)?

    /// Session-keyed mirrors of the tile callbacks, fired for terminal surfaces only. They let the
    /// session-keyed `TerminalFocusCoordinator` stay session-keyed across the render-path flip: it
    /// drives pending-focus by `HostTerminalSession.id`, and the store resolves the owning session
    /// when it creates / evicts a `TerminalSurface`. Web surfaces (no agent identity) skip these.
    var onTerminalSurfaceCreated: (@MainActor (UUID) -> Void)?
    var onTerminalSurfaceInvalidated: (@MainActor (UUID) -> Void)?
    /// Fired when a terminal surface's libghostty title changes, so the tab strip / subtitle refresh.
    var onTerminalTitleChanged: (@MainActor (UUID) -> Void)?

    // MARK: - Access

    func surface(for tileID: TileID) -> (any Surface)? {
        surfaces[tileID]
    }

    /// The tiles that currently hold a live surface. Drives lifecycle assertions and `sync` diffs.
    var retainedTileIDs: Set<TileID> {
        Set(surfaces.keys)
    }

    // MARK: - Terminal

    /// Get-or-create the terminal surface bound to `tileID`. On reuse the per-render callbacks are
    /// refreshed; on creation `onSurfaceCreated` fires. The process-exit callback is wrapped to evict
    /// the surface before invoking the caller's handler, matching the legacy store.
    @discardableResult
    func terminalSurface(
        for tileID: TileID,
        session: HostTerminalSession,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil,
        contextMenuProvider: (() -> NSMenu?)? = nil
    ) -> TerminalSurface {
        let wrappedOnProcessExit: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.invalidate(tileID: tileID)
                onProcessExit?()
            }
        }

        if let existing = surfaces[tileID] as? TerminalSurface, existing.session.id == session.id {
            existing.update(
                onProcessExit: wrappedOnProcessExit,
                onCloseConfirmationRequired: onCloseConfirmationRequired,
                contextMenuProvider: contextMenuProvider
            )
            return existing
        }

        // A stale binding (tile rebound to a different session) or a mismatched/absent surface: evict
        // before recreating so `sessionID(for:)` never reports the previous session's identity.
        invalidate(tileID: tileID)

        let created = TerminalSurface(
            tileID: tileID,
            session: session,
            hooksSocketPath: hooksSocketPath,
            automationEnvironment: automationEnvironmentProvider?(session),
            onProcessExit: wrappedOnProcessExit,
            onCloseConfirmationRequired: onCloseConfirmationRequired,
            contextMenuProvider: contextMenuProvider
        )
        let sessionID = session.id
        created.surfaceView.onTerminalTitleChanged = { [weak self] _ in
            self?.onTerminalTitleChanged?(sessionID)
        }
        surfaces[tileID] = created
        onSurfaceCreated?(tileID)
        onTerminalSurfaceCreated?(sessionID)
        return created
    }

    // MARK: - Web

    /// Get-or-create the web surface bound to `tileID`. Reuse refreshes the blocked-navigation hook.
    @discardableResult
    func webSurface(
        for tileID: TileID,
        source: WebSource,
        onBlockedNavigation: ((URL) -> Void)? = nil
    ) -> WebSurface {
        if let existing = surfaces[tileID] as? WebSurface, existing.source.id == source.id {
            existing.onBlockedNavigation = onBlockedNavigation
            return existing
        }

        // Stale/mismatched binding: evict before rebinding the tile to a different source.
        invalidate(tileID: tileID)

        let created = WebSurface(
            tileID: tileID,
            source: source,
            surfaceStore: webStore(forSourceID: source.id),
            onBlockedNavigation: onBlockedNavigation
        )
        surfaces[tileID] = created
        onSurfaceCreated?(tileID)
        return created
    }

    /// The web surface bound to `tileID`, if any. Backs source-level actions (reload,
    /// open-in-browser) that need the live `WKWebView` behind the current web tile.
    func webSurface(for tileID: TileID) -> WebSurface? {
        surfaces[tileID] as? WebSurface
    }

    /// Get-or-create the shared per-source store backing `sourceID`'s web views.
    func webStore(forSourceID sourceID: UUID) -> WebSurfaceStore {
        if let store = webStoresBySourceID[sourceID] {
            return store
        }
        let store = WebSurfaceStore()
        webStoresBySourceID[sourceID] = store
        return store
    }

    /// Immediately release everything held for `sourceID` — the web surface (if a tile is bound to
    /// it) and the per-source store's `WKWebView`, skipping the deferred-release grace window. For
    /// hard teardown (the source was deleted), where lazy release would keep a dead page alive.
    func releaseWebResources(forSourceID sourceID: UUID) {
        for (tileID, surface) in surfaces {
            if let webSurface = surface as? WebSurface, webSurface.source.id == sourceID {
                invalidate(tileID: tileID)
            }
        }
        guard let store = webStoresBySourceID.removeValue(forKey: sourceID) else { return }
        store.releaseInactiveSurface()
    }

    // MARK: - Resolver

    /// The terminal surface whose libghostty view is `view`, if any. Backs OSC / split routing that
    /// arrive holding a `GhosttySurfaceView` and need the owning tile or agent session.
    func terminalSurface(owning view: GhosttySurfaceView) -> TerminalSurface? {
        surfaces.values
            .lazy
            .compactMap { $0 as? TerminalSurface }
            .first { $0.surfaceView === view }
    }

    /// The agent-domain session id for `view` — the value OSC routing resolves against the registry.
    func sessionID(for view: GhosttySurfaceView) -> UUID? {
        terminalSurface(owning: view)?.session.id
    }

    /// The layout tile id for `view`.
    func tileID(for view: GhosttySurfaceView) -> TileID? {
        terminalSurface(owning: view)?.tileID
    }

    /// The display title for `tileID`'s surface, or `nil` when no surface exists yet (the caller
    /// supplies its own fallback — e.g. a session's directory name — before the surface mounts).
    func displayTitle(for tileID: TileID) -> String? {
        surfaces[tileID]?.displayTitle
    }

    // MARK: - Session-keyed facade
    //
    // The render path keys surfaces by `TileID`, but the focus coordinator, OSC routing, and tab
    // strip address terminals by `HostTerminalSession.id`. These resolve session → owning terminal
    // surface by scanning the (shallow, one-per-visible-pane) surface map, so those consumers keep
    // their session-keyed shape without `SurfaceStore` learning the tile↔session binding (that stays
    // in `TileTreeStore`).

    private func terminalSurface(forSession sessionID: UUID) -> TerminalSurface? {
        surfaces.values
            .lazy
            .compactMap { $0 as? TerminalSurface }
            .first { $0.session.id == sessionID }
    }

    /// The libghostty view backing `sessionID`'s terminal tile, if mounted. Focus restoration and
    /// close-intent routing resolve through this.
    func terminal(for sessionID: UUID) -> GhosttySurfaceView? {
        terminalSurface(forSession: sessionID)?.surfaceView
    }

    /// The display title for `session`'s terminal, falling back to its directory name before the
    /// surface mounts. Mirrors the legacy `HostTerminalSurfaceStore.displayTitle(for:)`.
    func displayTitle(for session: HostTerminalSession) -> String {
        if let title = terminalSurface(forSession: session.id)?.displayTitle, !title.isEmpty {
            return title
        }
        let fallback = session.directoryURL.lastPathComponent
        return fallback.isEmpty ? "Terminal" : fallback
    }

    /// Run the terminal's session-retirement close (process-alive teardown) if a surface is mounted.
    @discardableResult
    func closeForSessionRetirement(sessionID: UUID) async throws -> Bool {
        guard let surfaceView = terminalSurface(forSession: sessionID)?.surfaceView else {
            return false
        }
        try await surfaceView.requestCloseForSessionRetirement()
        return true
    }

    // MARK: - Eviction

    /// Evict the surface for `tileID`: tear it down and fire `onSurfaceInvalidated`. No-op if absent.
    ///
    /// Deliberate parity delta from the legacy `HostTerminalSurfaceStore.invalidate(sessionID:)`, which
    /// fired `onSurfaceInvalidated` unconditionally: here an absent tile is a silent no-op, so listeners
    /// see invalidations only for surfaces that actually existed. Phase 5 routes all teardown through
    /// `sync`, so this guard is what keeps that flip from emitting phantom invalidations.
    func invalidate(tileID: TileID) {
        guard let surface = surfaces.removeValue(forKey: tileID) else { return }
        let terminalSessionID = (surface as? TerminalSurface)?.session.id
        surface.tearDown()
        onSurfaceInvalidated?(tileID)
        if let terminalSessionID {
            onTerminalSurfaceInvalidated?(terminalSessionID)
        }
    }

    /// Retain only the surfaces whose tiles are still live leaves; tear down the rest. A pure
    /// present-vs-retained diff — the eviction authority Phase 5 routes all teardown through, in place
    /// of today's scattered `invalidate` calls in `TileTreeStore`.
    func sync(activeLeafIDs: [TileID]) {
        let active = Set(activeLeafIDs)
        let stale = surfaces.keys.filter { !active.contains($0) }
        for tileID in stale {
            invalidate(tileID: tileID)
        }
    }
}
