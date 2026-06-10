import AppKit
import WorkspaceManagerCore

/// Owns the live `Surface` for each `TileID` in a tile tree: a `[TileID: any Surface]` map plus the
/// resolver behavior the legacy `HostTerminalSurfaceStore` provided (surface-view → session lookup,
/// create/invalidate callbacks, display titles).
///
/// This is the generalized, `TileID`-keyed successor to `HostTerminalSurfaceStore`. It is not yet on
/// the live render path — Phase 3 swaps the renderer onto it, and Phase 5 makes `sync` the single
/// surface-eviction authority. Built and tested ahead of those flips so the wiring lands against a
/// proven store.
@MainActor
final class SurfaceStore {
    private var surfaces: [TileID: any Surface] = [:]

    /// Forwarded to terminal surfaces at creation so libghostty can reach the agent hook socket.
    var hooksSocketPath: String?

    /// Fired when a surface is first created for a tile (drives focus-coordinator readiness).
    var onSurfaceCreated: (@MainActor (TileID) -> Void)?
    /// Fired when a surface is evicted for a tile (process exit, close, or `sync` diff).
    var onSurfaceInvalidated: (@MainActor (TileID) -> Void)?

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
            onProcessExit: wrappedOnProcessExit,
            onCloseConfirmationRequired: onCloseConfirmationRequired,
            contextMenuProvider: contextMenuProvider
        )
        surfaces[tileID] = created
        onSurfaceCreated?(tileID)
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
            onBlockedNavigation: onBlockedNavigation
        )
        surfaces[tileID] = created
        onSurfaceCreated?(tileID)
        return created
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

    // MARK: - Eviction

    /// Evict the surface for `tileID`: tear it down and fire `onSurfaceInvalidated`. No-op if absent.
    ///
    /// Deliberate parity delta from the legacy `HostTerminalSurfaceStore.invalidate(sessionID:)`, which
    /// fired `onSurfaceInvalidated` unconditionally: here an absent tile is a silent no-op, so listeners
    /// see invalidations only for surfaces that actually existed. Phase 5 routes all teardown through
    /// `sync`, so this guard is what keeps that flip from emitting phantom invalidations.
    func invalidate(tileID: TileID) {
        guard let surface = surfaces.removeValue(forKey: tileID) else { return }
        surface.tearDown()
        onSurfaceInvalidated?(tileID)
    }

    /// Retain only the surfaces whose tiles are still live leaves; tear down the rest. A pure
    /// present-vs-retained diff — the eviction authority Phase 5 routes all teardown through, in place
    /// of today's scattered `invalidate` calls in `HostTerminalStateStore`.
    func sync(activeLeafIDs: [TileID]) {
        let active = Set(activeLeafIDs)
        let stale = surfaces.keys.filter { !active.contains($0) }
        for tileID in stale {
            invalidate(tileID: tileID)
        }
    }
}
