import AppKit
import WebKit
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "SurfaceStore")

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
    /// (source deleted) or by the lingering-page trim; an idle entry otherwise holds no `WKWebView`
    /// after its deferred release fires.
    private var webStoresBySourceID: [UUID: WebSurfaceStore] = [:]

    /// Most-recently-used order of web sources, oldest first. Bounds the deferred-release policy:
    /// rapid switching across many sources would otherwise keep one live `WKWebView` per source for
    /// the whole grace window (unbounded transient memory). Beyond the cap, the least-recently-used
    /// *unbound* page is hard-released — reopening it reloads, which is the pre-seam behavior.
    private var webSourceUseOrder: [UUID] = []
    private static let maxLingeringWebPages = 3

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
        deliverLaunchWorkIfNeeded(created)
        return created
    }

    /// Sessions whose post-creation launch work has run. Once per session, never per
    /// surface: a respawned shell must not re-run the agent.
    private var launchWorkDeliveredSessionIDs: Set<UUID> = []

    /// Bring a newly created terminal surface up to its launch contract, then hand it
    /// `session.initialCommand`.
    ///
    /// #889 is open on a symptom, not on an established mechanism. It was filed as
    /// libghostty dropping `command`, `env_vars`, and `initial_input` for surfaces
    /// after the app's first; that attribution has not held up. The marshalling seam
    /// is now pinned by `GhosttyTerminalConfigTests.cValueCarriesEveryPerSurfaceField`,
    /// which proves every per-surface field Swift holds — `command`, `env_vars`,
    /// `working_directory` — is written into `ghostty_surface_config_s`, and staged
    /// spawn-layer runs delivered those three to every surface with this repair path
    /// enabled and firing zero times. (`initial_input` is never launch-embedded here,
    /// so nothing exercises it.) Nothing proves what libghostty does with the struct
    /// after it is handed over, and the
    /// 2026-08-30 installed-build restore — 12 of 15 surfaces up bare — is still
    /// unexplained. Treat the loss point as unknown rather than as settled upstream
    /// behavior.
    ///
    /// The symptom is what this path answers: a tmux-mode surface that loses its
    /// `command` comes up as a bare login shell beside the session it was supposed to
    /// attach, holding none of its tile-scoped environment — which is why a restored
    /// tile looks empty and why its agent cannot report identity afterwards (#1478).
    ///
    /// So the surface is verified against tmux, repaired by typing its launch script
    /// when the launch lost, and only then handed the initial command. Verifying
    /// first keeps the fast path's win: typed delivery is visible to the user and
    /// races shell startup, so it is worth paying only when the launch actually lost.
    private func deliverLaunchWorkIfNeeded(_ terminal: TerminalSurface) {
        let session = terminal.session
        let tmuxLaunchScript = terminal.surfaceView.tmuxLaunchScript
        guard tmuxLaunchScript != nil || session.initialCommand != nil else { return }
        guard !launchWorkDeliveredSessionIDs.contains(session.id) else { return }
        launchWorkDeliveredSessionIDs.insert(session.id)

        Task { @MainActor [weak self, weak terminal] in
            // Wait for the surface's shell to come alive, then settle briefly so
            // the paste lands at a prompt instead of racing shell/tmux startup.
            for _ in 0..<40 {
                guard terminal != nil else { break }
                if terminal?.surfaceView.isSurfaceAlive == true { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .milliseconds(1500))

            // Surface evicted mid-poll: nothing ran, so un-mark and let a recreated
            // surface retry from the top.
            guard let terminal else {
                self?.launchWorkDeliveredSessionIDs.remove(session.id)
                return
            }

            if let tmuxLaunchScript {
                await self?.repairLaunchContractIfNeeded(
                    terminal: terminal,
                    session: session,
                    tmuxLaunchScript: tmuxLaunchScript
                )
            }

            guard let initialCommand = session.initialCommand else { return }
            self?.deliverInitialCommand(initialCommand, to: terminal, session: session)
        }
    }

    /// Attach a tmux-backed surface to its session when the launch command never ran.
    ///
    /// A tmux-mode surface execs `new-session -A`, so a live session with at least one
    /// attached client is the observable proof the launch landed. Zero clients means
    /// it did not, and typing the same script into the bare shell reaches the same
    /// state — environment included, because the script carries the tile-scoped pairs
    /// as `-e` and `set-environment` arguments.
    ///
    /// Repairs only on evidence, never on doubt, and three separate things can call
    /// it off. An unanswered client probe means the pane may in fact be attached and
    /// running something. A tmux binary that does not answer at all makes "no such
    /// session" meaningless, because `isSessionAlive` reports a timeout and a real
    /// absence identically. And a surface that has heard a keystroke belongs to the
    /// person now, whatever tmux says about it — that last check sits immediately
    /// before the write, because the gap between observing and typing is exactly
    /// where someone starts an editor.
    ///
    /// What is typed is guarded too: `tmuxRepairScript` short-circuits inside tmux,
    /// so a repair that races a launch which just attached does nothing rather than
    /// `exec`-ing a nested tmux and taking the pane down with it.
    private func repairLaunchContractIfNeeded(
        terminal: TerminalSurface,
        session: HostTerminalSession,
        tmuxLaunchScript: String
    ) async {
        let sessionName = session.effectiveTmuxSessionName
        let probe = TmuxSessionProbe()
        // Give the launch its own chance to land before concluding it lost. A slow
        // login shell can still be on its way to `exec tmux` after the settle, and
        // typing a second launch into a shell that is about to exec one would put
        // the text inside the attached pane — in front of whatever runs there.
        for attempt in 0..<12 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard await probe.isSessionAlive(sessionName) else { continue }
            guard let attached = await probe.attachedClientCount(forSessionNamed: sessionName) else {
                log.notice(
                    "[SurfaceStore] launch contract unverifiable for session \(session.id.uuidString, privacy: .public): tmux \(sessionName, privacy: .public) did not answer; leaving the surface alone"
                )
                return
            }
            if attached > 0 { return }
        }

        // Absence only counts when tmux is the one reporting it.
        guard await probe.isCommandAvailable() else {
            log.notice(
                "[SurfaceStore] launch contract unverifiable for session \(session.id.uuidString, privacy: .public): tmux did not answer at all; leaving the surface alone"
            )
            return
        }

        guard !terminal.surfaceView.hasReceivedUserInput else {
            log.notice(
                "[SurfaceStore] skipping launch repair for session \(session.id.uuidString, privacy: .public): the surface has taken keyboard input and is no longer an untouched shell"
            )
            return
        }

        log.notice(
            "[SurfaceStore] launch contract unmet for session \(session.id.uuidString, privacy: .public): tmux \(sessionName, privacy: .public) has no attached client; repairing over the text bridge"
        )

        guard
            GhosttySurfaceTextInputBridge.writeAutomationText(
                into: terminal.surfaceView,
                text: GhosttyTerminalConfig.tmuxRepairScript(tmuxLaunchScript)),
            GhosttySurfaceTextInputBridge.sendAutomationReturn(into: terminal.surfaceView)
        else {
            log.error(
                "[SurfaceStore] launch repair could not reach the shell for session \(session.id.uuidString, privacy: .public)"
            )
            return
        }

        try? await Task.sleep(for: .milliseconds(1200))
        let attachedAfter = await probe.attachedClientCount(forSessionNamed: sessionName)
        log.info(
            "[SurfaceStore] launch repair \((attachedAfter ?? 0) > 0 ? "attached" : "DID NOT ATTACH", privacy: .public) tmux \(sessionName, privacy: .public) clients=\(attachedAfter.map(String.init) ?? "unknown", privacy: .public)"
        )
    }

    /// Type `initialCommand` into the surface, pressing Return only when the session
    /// asked to execute it. Restore asks for `.prefill`, so the command waits at the
    /// prompt: reconnecting to a live process is free, but starting an agent spends
    /// memory and tokens the user may not want spent on a restart.
    private func deliverInitialCommand(
        _ initialCommand: String,
        to terminal: TerminalSurface,
        session: HostTerminalSession
    ) {
        let delivery = session.initialCommandDelivery
        // The command reached no shell unless every bridge call succeeds. On any
        // failure (dead surface, dropped write), un-mark the session so a recreated
        // surface retries — nothing ran, so a retry cannot double-run the agent.
        var delivered = GhosttySurfaceTextInputBridge.writeAutomationText(
            into: terminal.surfaceView, text: initialCommand)
        if delivered, delivery == .execute {
            delivered = GhosttySurfaceTextInputBridge.sendAutomationReturn(into: terminal.surfaceView)
        }
        if !delivered {
            launchWorkDeliveredSessionIDs.remove(session.id)
        }
        log.info(
            "[SurfaceStore] initial command \(delivered ? "delivered" : "DROPPED (will retry on a new surface)", privacy: .public) delivery=\(delivery.rawValue, privacy: .public) for session \(session.id.uuidString, privacy: .public)"
        )
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
            touchWebSource(source.id)
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
        touchWebSource(source.id)
        return created
    }

    /// The web surface bound to `tileID`, if any. Backs source-level actions (reload,
    /// open-in-browser) that need the live `WKWebView` behind the current web tile.
    func webSurface(for tileID: TileID) -> WebSurface? {
        surfaces[tileID] as? WebSurface
    }

    /// Live navigation state for an already-instantiated web surface, or `nil` when
    /// none is live. A non-creating peek: unlike `webStore(forSourceID:)` it never
    /// instantiates a store, so listing web surfaces can't spin up hidden WKWebViews.
    func liveWebState(forSourceID sourceID: UUID) -> WebSurfaceLiveState? {
        webStoresBySourceID[sourceID]?.liveState
    }

    /// The live `WKWebView` backing `sourceID`, or `nil` when none is instantiated. The
    /// non-creating peek the Automation API's browser-read snapshot resolves through: like
    /// `liveWebState(forSourceID:)` it never spins up a store, so snapshotting a released
    /// surface fails closed instead of loading a hidden page.
    func liveWebView(forSourceID sourceID: UUID) -> WKWebView? {
        webStoresBySourceID[sourceID]?.liveWebView
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
        webSourceUseOrder.removeAll { $0 == sourceID }
        guard let store = webStoresBySourceID.removeValue(forKey: sourceID) else { return }
        store.releaseInactiveSurface()
    }

    /// Marks `sourceID` most-recently-used and trims lingering pages beyond the cap. A page is
    /// "lingering" when its source has a live `WKWebView` but no surface currently bound to a tile —
    /// exactly the flip-back candidates the deferred-release policy exists for.
    private func touchWebSource(_ sourceID: UUID) {
        webSourceUseOrder.removeAll { $0 == sourceID }
        webSourceUseOrder.append(sourceID)

        let boundSourceIDs = Set(surfaces.values.compactMap { ($0 as? WebSurface)?.source.id })

        // Housekeeping: an unbound store whose deferred release already fired holds no page —
        // drop its registry/order entries so slow drift across many sources leaves no metadata.
        let expired = webStoresBySourceID.filter { id, store in
            !boundSourceIDs.contains(id) && !store.hasActiveSurface
        }.keys
        for id in expired {
            webStoresBySourceID.removeValue(forKey: id)
            webSourceUseOrder.removeAll { $0 == id }
        }

        var lingering = webSourceUseOrder.filter { id in
            !boundSourceIDs.contains(id) && webStoresBySourceID[id]?.hasActiveSurface == true
        }
        while lingering.count > Self.maxLingeringWebPages {
            releaseWebResources(forSourceID: lingering.removeFirst())
        }
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

    func terminalPlainText(for sessionID: UUID) -> String? {
        terminalSurface(forSession: sessionID)?.surfaceView.readPlainScreenText()
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
        guard let surface = terminalSurface(forSession: sessionID) else {
            return false
        }
        try await surface.closeForSessionRetirement()
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
