import SwiftUI
import WorkspaceManagerCore
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "TileTreeStore")

@MainActor
final class TileTreeStore: ObservableObject {
    struct SplitPaneLayout: Equatable {
        enum Axis: Equatable {
            case leadingTrailing
            case topBottom

            var tileAxis: SplitAxis {
                switch self {
                case .leadingTrailing: return .leadingTrailing
                case .topBottom: return .topBottom
                }
            }
        }

        let axis: Axis
        let splitBeforePrimary: Bool

        static let defaultTrailing = SplitPaneLayout(
            axis: .leadingTrailing,
            splitBeforePrimary: false
        )
    }

    static let defaultSplitFraction: CGFloat = 0.5
    private static let minimumSplitFraction: CGFloat = 0.2
    private static let maximumSplitFraction: CGFloat = 0.8
    private static let splitResizeStep: CGFloat = 0.05

    @Published private(set) var sessions: [HostTerminalSession] = []
    @Published private(set) var scopedSessions: [HostTerminalSession] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var tabTitleOverridesBySessionID: [UUID: String] = [:]
    @Published private(set) var sessionPresentation = HostTerminalSessionPresentation()

    /// Split layout source of truth, sparse: an entry exists only for a tab (keyed by primary
    /// session id) that currently has a split. No entry ⇒ single pane. Plain `var` (no consumer
    /// reads it directly); every mutator fires `objectWillChange` to match the legacy `@Published`
    /// split maps it replaced.
    private var treesByPrimaryID: [UUID: TileTreeState] = [:]
    /// Binds layout tiles to the agent-domain sessions that fill them, and back. The split
    /// `HostTerminalSession` (which never enters the coordinator) lives here; primary tiles are
    /// bound only while their tab has a split. The live split-session set is derived from
    /// `treesByPrimaryID` (non-primary leaves → `sessionByTileID`), so a dropped tree entry is the
    /// single source of truth — a stale binding can never keep a dead split registered.
    private var sessionByTileID: [TileID: HostTerminalSession] = [:]
    /// One tile identity per live session — split leaves *and* single-pane primaries. Split tiles are
    /// bound by `splitFocusedTile`; single-pane primaries get a stable id memoized here (and mirrored
    /// in `sessionByTileID`) so `activeLeafTileIDs` is total. This is the unified successor to the
    /// render binding and the #684 `automationTileIDBySessionID` map — one identity per session, shared
    /// by the renderer, `SurfaceStore.sync`, and the automation handle registry.
    private var tileIDBySessionID: [UUID: TileID] = [:]
    private var primaryIDBySplitSessionID: [UUID: UUID] = [:]
    private var automationHandleRegistry: AutomationHandleRegistry?
    private var automationSocketPath: String?
    private let automationWindowScopeID = UUID().uuidString
    private let automationAppScopeID = "workspaces.local"
    private let tileTreeReducer = TileTreeReducer()

    let surfaceStore = SurfaceStore()
    private var coordinator = HostTerminalSessionCoordinator()

    /// Agent session registry attached at scene mount. Optional because previews and
    /// fixtures construct stores without an app-scoped registry.
    private weak var agentSessionRegistry: AgentSessionRegistry?
    private weak var lastCommandStatusRegistry: LastCommandStatusRegistry?
    private var localStateStore: LocalStateStore?
    /// Ordered continuity write pipeline (#1239); created at attach around the
    /// local state store. Internal as a test seam: tests inject a recorder backed
    /// by an in-memory sink to bind write ordering and amplification.
    var continuityRecorder: TerminalContinuityRecorder?
    /// Stub probe used to seed `kind` on register; PR #1 ships a fail-safe
    /// `.claudeCode` default. Replace with the real probe in a foreground Agent
    /// detection follow-up.
    private let foregroundProbe = PTYForegroundProbe()
    /// Set of session IDs the store has already registered with the agent registry,
    /// so we only register/deregister on real edge transitions.
    private var registeredAgentSessionIDs: Set<UUID> = []

    /// Test seams for pane-scoped tmux session reclamation (#1232) and continuity
    /// row recording (#1239): production resolves the real multiplexing mode and
    /// kills on the workspaces socket; tests inject a fixed mode and a probe wired
    /// to a stubbed tmux executable.
    var resolveTerminalMultiplexingMode: () -> TerminalMultiplexingMode = { TerminalMultiplexingMode.resolve() }
    var killTmuxSession: @Sendable (String) async -> Bool = { await TmuxSessionProbe().killSession($0) }

    init() {
        surfaceStore.onTerminalTitleChanged = { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// The full live-leaf `TileID` set across every tab — split tabs' tree leaves plus single-pane
    /// tabs' memoized primary tiles. This is `SurfaceStore.sync`'s input: after any mutation the
    /// retained surface set must equal this, so a leaf that left the tree is the single trigger for
    /// surface eviction (no scattered per-session `invalidate`).
    private var activeLeafTileIDs: [TileID] {
        var ids: [TileID] = []
        var seen: Set<TileID> = []
        for primarySession in coordinator.sessions {
            if let tree = treesByPrimaryID[primarySession.id] {
                for leaf in tree.leafIDs where seen.insert(leaf).inserted {
                    ids.append(leaf)
                }
            } else if let tileID = tileIDBySessionID[primarySession.id], seen.insert(tileID).inserted {
                ids.append(tileID)
            }
        }
        return ids
    }

    /// The stable render `TileID` for a single-pane (unsplit) session, memoized so the renderer,
    /// `SurfaceStore.sync`, and the automation handle all resolve one identity. Split leaves are bound
    /// by `splitFocusedTile`; this seeds the binding for a primary that has no split yet.
    private func renderTileID(for sessionID: UUID) -> TileID {
        if let tileID = tileIDBySessionID[sessionID] {
            return tileID
        }
        let tileID = TileID()
        tileIDBySessionID[sessionID] = tileID
        if let session = coordinator.sessions.first(where: { $0.id == sessionID }) {
            sessionByTileID[tileID] = session
        }
        return tileID
    }

    /// The render `TileID` for the leaf filling `sessionID`, single-pane or split. The renderer uses
    /// this to vend the tile's surface from `SurfaceStore`.
    func renderTileID(forSession session: HostTerminalSession) -> TileID {
        renderTileID(for: session.id)
    }

    /// Vend (get-or-create) the terminal surface view for a session's leaf — the perf-prewarm path.
    @discardableResult
    func terminalSurfaceView(for session: HostTerminalSession) -> GhosttySurfaceView {
        surfaceStore.terminalSurface(for: renderTileID(for: session.id), session: session).surfaceView
    }

    func attach(agentSessionRegistry: AgentSessionRegistry) {
        attach(
            agentSessionRegistry: agentSessionRegistry,
            localStateStore: nil,
            hooksSocketPath: ClaudeIntegrationLifecycle.shared.socketPath
        )
    }

    func attach(
        agentSessionRegistry: AgentSessionRegistry,
        localStateStore: LocalStateStore?,
        hooksSocketPath: String?,
        lastCommandStatusRegistry: LastCommandStatusRegistry? = nil
    ) {
        if self.localStateStore !== localStateStore {
            self.localStateStore = localStateStore
            continuityRecorder = localStateStore.map { TerminalContinuityRecorder(sink: $0) }
        }
        self.lastCommandStatusRegistry = lastCommandStatusRegistry
        self.surfaceStore.hooksSocketPath = hooksSocketPath
        self.surfaceStore.automationEnvironmentProvider = { [weak self] session in
            self?.automationEnvironment(for: session)
        }
        guard self.agentSessionRegistry !== agentSessionRegistry else {
            syncRegistry()
            return
        }
        self.agentSessionRegistry = agentSessionRegistry
        // Backfill: any sessions already in the coordinator should be registered.
        syncRegistry()

        // Terminal attention fallback: hook the surface→host-session resolver
        // into the OSC router so libghostty desktop notifications and BEL events
        // can find their session.
        let store = self.surfaceStore
        AgentOSCRouter.shared.attach(registry: agentSessionRegistry) { surfaceView in
            store.sessionID(for: surfaceView)
        }
    }

    func configureAutomation(handleRegistry: AutomationHandleRegistry?, socketPath: String?) {
        automationHandleRegistry = handleRegistry
        automationSocketPath = socketPath
        surfaceStore.automationEnvironmentProvider = { [weak self] session in
            self?.automationEnvironment(for: session)
        }
        syncAutomationRegistry()
    }

    var hasSessions: Bool {
        !sessions.isEmpty
    }

    var activeScopeKey: HostTerminalSessionKey? {
        coordinator.activeScopeKey
    }

    var activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID] {
        coordinator.activeSessionIDByScopeKey
    }

    func sessions(inScope scopeKey: HostTerminalSessionKey?) -> [HostTerminalSession] {
        coordinator.sessions(inScope: scopeKey)
    }

    func terminalSessionIDs(inScope scopeKey: HostTerminalSessionKey) -> [UUID] {
        coordinator.sessions(inScope: scopeKey).flatMap { primarySession in
            var sessionIDs: [UUID] = []

            if let tree = treesByPrimaryID[primarySession.id],
                let primaryTile = tileIDBySessionID[primarySession.id]
            {
                for tileID in tree.leafIDs where tileID != primaryTile {
                    if let splitSession = sessionByTileID[tileID] {
                        sessionIDs.append(splitSession.id)
                    }
                }
            }

            sessionIDs.append(primarySession.id)
            return sessionIDs
        }
    }

    func activeSession(inScope scopeKey: HostTerminalSessionKey) -> HostTerminalSession? {
        let scopedSessions = coordinator.sessions(inScope: scopeKey)
        guard !scopedSessions.isEmpty else { return nil }

        if let activeSessionID = coordinator.activeSessionIDByScopeKey[scopeKey.normalized()],
            let activeSession = scopedSessions.first(where: { $0.id == activeSessionID })
        {
            return activeSession
        }

        return scopedSessions.first
    }

    @discardableResult
    func activateSession(
        key: HostTerminalSessionKey,
        directory: URL,
        customCommand: String? = nil,
        initialCommand: String? = nil
    ) -> HostTerminalSessionActivationResult {
        let result = coordinator.activate(
            key: key,
            directory: directory,
            customCommand: customCommand,
            initialCommand: initialCommand
        )
        publishSnapshot()
        return result
    }

    /// Restore-only activation: always creates, never key-reuses. Restore retires the
    /// owned scope first and then launches one surface per continuity row, so sibling
    /// rows sharing a key (a primary and its recorded split panes) each get their own
    /// session carrying their own recorded tmux target and initial command (#1232).
    ///
    /// `adoptedHostSessionID` carries a reattach surface's recorded identity through
    /// to the session it creates, so the registry the hook listener consults is keyed
    /// by the id the surviving pane already exports (#1397).
    @discardableResult
    func createRestoredSession(
        key: HostTerminalSessionKey,
        directory: URL,
        initialCommand: String? = nil,
        initialCommandDelivery: HostTerminalSession.InitialCommandDelivery = .prefill,
        tmuxSessionNameOverride: String? = nil,
        adoptedHostSessionID: UUID? = nil
    ) -> HostTerminalSession {
        let session = coordinator.createSession(
            key: key,
            directory: directory,
            initialCommand: initialCommand,
            initialCommandDelivery: initialCommandDelivery,
            tmuxSessionNameOverride: tmuxSessionNameOverride,
            adoptedID: adoptedHostSessionID
        )
        publishSnapshot()
        return session
    }

    @discardableResult
    func ensureSession(
        key: HostTerminalSessionKey,
        directory: URL,
        customCommand: String? = nil,
        initialCommand: String? = nil
    ) -> HostTerminalSessionActivationResult {
        let result = coordinator.ensureSession(
            key: key,
            directory: directory,
            customCommand: customCommand,
            initialCommand: initialCommand
        )
        _ = renderTileID(for: result.session.id)
        publishSnapshot()
        return result
    }

    @discardableResult
    func activateExistingSession(sessionID: UUID) -> Bool {
        guard coordinator.activate(sessionID: sessionID) != nil else { return false }
        publishSnapshot()
        return true
    }

    func restoreSessions(
        _ sessions: [HostTerminalSession],
        activeSessionID: UUID?,
        activeSessionIDByScopeKey: [HostTerminalSessionKey: UUID]
    ) {
        guard !sessions.isEmpty else { return }
        coordinator = HostTerminalSessionCoordinator(
            sessions: sessions,
            activeSessionID: activeSessionID,
            activeSessionIDByScopeKey: activeSessionIDByScopeKey
        )
        publishSnapshot()
    }

    @discardableResult
    func createTab(from sourceSessionID: UUID? = nil) -> HostTerminalSession? {
        let sourceSession: HostTerminalSession?
        if let sourceSessionID,
            let primarySessionID = primarySessionID(containing: sourceSessionID)
        {
            sourceSession = coordinator.sessions.first(where: { $0.id == primarySessionID })
        } else if let activeSessionID {
            sourceSession = coordinator.sessions.first(where: { $0.id == activeSessionID })
        } else {
            sourceSession = coordinator.sessions.last
        }

        guard let sourceSession else { return nil }
        let session = coordinator.createTab(from: sourceSession)
        publishSnapshot()
        return session
    }

    @discardableResult
    func activateAdjacentTab(offset: Int, from sourceSessionID: UUID? = nil) -> HostTerminalSession? {
        guard let sourceSessionID = resolvedPrimarySessionID(sourceSessionID) else { return nil }
        let session = coordinator.activateAdjacent(to: sourceSessionID, offset: offset)
        publishSnapshot()
        return session
    }

    @discardableResult
    func activateTab(atOneBasedIndex index: Int) -> HostTerminalSession? {
        let session = coordinator.activateTab(atOneBasedIndex: index)
        publishSnapshot()
        return session
    }

    @discardableResult
    func activateLastTab() -> HostTerminalSession? {
        let session = coordinator.activateLastTab()
        publishSnapshot()
        return session
    }

    @discardableResult
    func moveTab(containing sourceSessionID: UUID?, offset: Int) -> Bool {
        guard let primarySessionID = resolvedPrimarySessionID(sourceSessionID) else { return false }
        guard coordinator.moveTab(sessionID: primarySessionID, offset: offset) else { return false }
        publishSnapshot()
        return true
    }

    func tabIDsForClose(mode: GhosttyAppManager.TabCloseMode, sourceSessionID: UUID?) -> [UUID] {
        guard let primarySessionID = resolvedPrimarySessionID(sourceSessionID),
            let primarySession = coordinator.sessions.first(where: { $0.id == primarySessionID })
        else {
            return []
        }

        let scopedSessions = coordinator.sessions(inScope: primarySession.key)
        guard let primaryIndex = scopedSessions.firstIndex(where: { $0.id == primarySessionID }) else {
            return []
        }

        switch mode {
        case .this:
            return [primarySessionID]
        case .other:
            return scopedSessions.map(\.id).filter { $0 != primarySessionID }
        case .right:
            let rightStart = scopedSessions.index(after: primaryIndex)
            guard rightStart < scopedSessions.endIndex else { return [] }
            return scopedSessions[rightStart...].map(\.id)
        }
    }

    @discardableResult
    func setTabTitle(_ title: String?, for sourceSessionID: UUID?) -> Bool {
        guard let primarySessionID = resolvedPrimarySessionID(sourceSessionID) else { return false }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updatedOverrides = tabTitleOverridesBySessionID
        if let normalizedTitle, !normalizedTitle.isEmpty {
            updatedOverrides[primarySessionID] = normalizedTitle
        } else {
            updatedOverrides.removeValue(forKey: primarySessionID)
        }
        if updatedOverrides != tabTitleOverridesBySessionID {
            tabTitleOverridesBySessionID = updatedOverrides
        }
        return true
    }

    func tabTitleOverride(for sessionID: UUID) -> String? {
        tabTitleOverridesBySessionID[sessionID]
    }

    func primarySessionID(containing sessionID: UUID) -> UUID? {
        if coordinator.sessions.contains(where: { $0.id == sessionID }) {
            return sessionID
        }

        return primaryIDBySplitSessionID[sessionID]
    }

    /// Ensures the primary (non-split) session that contains `sessionID` is active.
    /// If `sessionID` already refers to a primary session, it becomes active directly.
    @discardableResult
    func activatePrimarySession(containing sessionID: UUID) -> UUID? {
        guard let primarySessionID = primarySessionID(containing: sessionID) else {
            return nil
        }

        guard activateExistingSession(sessionID: primarySessionID) else { return nil }
        return primarySessionID
    }

    func pruneRepoSessions(validRepoPaths: Set<String>) {
        let removedSessionIDs = coordinator.pruneRepoSessions(validRepoPaths: validRepoPaths)
        guard !removedSessionIDs.isEmpty else { return }

        for removedSessionID in removedSessionIDs {
            removeSplitState(forPrimarySessionID: removedSessionID)
            tabTitleOverridesBySessionID.removeValue(forKey: removedSessionID)
        }

        publishSnapshot()
    }

    @discardableResult
    func retireSessions(inScope scopeKey: HostTerminalSessionKey) -> [UUID] {
        let primarySessionIDs = coordinator.sessions(inScope: scopeKey).map(\.id)
        guard !primarySessionIDs.isEmpty else { return [] }

        var retiredSessionIDs: [UUID] = []
        for primarySessionID in primarySessionIDs {
            for splitSession in dropSplitTree(forPrimarySessionID: primarySessionID) {
                retireTerminalSession(splitSession.id)
                retiredSessionIDs.append(splitSession.id)
            }

            guard coordinator.remove(sessionID: primarySessionID) != nil else { continue }
            retireTerminalSession(primarySessionID)
            tabTitleOverridesBySessionID.removeValue(forKey: primarySessionID)
            retiredSessionIDs.append(primarySessionID)
        }

        if !retiredSessionIDs.isEmpty {
            publishSnapshot()
        }
        return retiredSessionIDs
    }

    @discardableResult
    func handleProcessExit(for sessionID: UUID) -> Bool {
        var removed = false

        if let primarySessionID = primaryIDBySplitSessionID[sessionID] {
            closeSplitPane(sessionID, primarySessionID: primarySessionID)
            removed = true
        }

        if let removedSession = coordinator.remove(sessionID: sessionID) {
            // A restored split pane lives on as a tab carrying its pane-scoped
            // override; closing that tab is the same reclaim as closing the pane.
            killPaneScopedTmuxSession(for: removedSession)
            removeSplitState(forPrimarySessionID: sessionID)
            tabTitleOverridesBySessionID.removeValue(forKey: sessionID)
            removed = true
        }

        if removed {
            publishSnapshot()
        }

        return removed
    }

    /// Handles process-exit cleanup and resolves which session should receive focus.
    /// Returns `nil` if the session was unknown/no-op.
    @discardableResult
    func handleProcessExitAndResolveFocusTarget(
        for sessionID: UUID,
        defaultHomeDirectory: URL
    ) -> UUID? {
        guard handleProcessExit(for: sessionID) else {
            return nil
        }

        if sessions.isEmpty {
            let replacement = activateSession(
                key: .defaultHome,
                directory: defaultHomeDirectory
            )
            return replacement.session.id
        }

        return activeSessionID
    }

    // MARK: - Depth-1 split projections
    //
    // Read-only views of a two-leaf tree in the legacy `splitSession`/`splitLayout`/`splitFraction`
    // vocabulary. No production code reads them — the recursive renderer and resize/focus paths walk
    // the tree directly. They survive as the two-pane store tests' assertion vocabulary, and the
    // `assert(leafIDs == 2)` in `splitTileID(in:)` is their depth-1 contract: a deeper tree trips it
    // loudly rather than letting a projection silently pick one arbitrary sibling.

    func splitSession(for primarySessionID: UUID?) -> HostTerminalSession? {
        guard let primarySessionID, let tree = treesByPrimaryID[primarySessionID] else { return nil }
        return splitSession(in: tree, primarySessionID: primarySessionID)
    }

    func splitLayout(for primarySessionID: UUID?) -> SplitPaneLayout? {
        guard let primarySessionID,
            let tree = treesByPrimaryID[primarySessionID],
            case .split(_, let axis, _, _, let second) = tree.root,
            let primaryTile = tileIDBySessionID[primarySessionID]
        else {
            return nil
        }
        // `splitBeforePrimary` ⇔ the new (split) tile was inserted ahead of the primary, leaving the
        // primary as the split's trailing (`second`) child.
        return SplitPaneLayout(
            axis: axis == .leadingTrailing ? .leadingTrailing : .topBottom,
            splitBeforePrimary: second == .tile(primaryTile)
        )
    }

    func splitFraction(for primarySessionID: UUID?) -> CGFloat? {
        guard let primarySessionID,
            let tree = treesByPrimaryID[primarySessionID],
            case .split(_, _, let ratio, _, _) = tree.root
        else {
            return nil
        }
        // The tree's `first`-child ratio is always the legacy leading-pane fraction.
        return CGFloat(ratio)
    }

    /// The split sibling's session inside `tree` — the one leaf that is not the primary's tile.
    private func splitSession(in tree: TileTreeState, primarySessionID: UUID) -> HostTerminalSession? {
        guard let splitTileID = splitTileID(in: tree, primarySessionID: primarySessionID) else {
            return nil
        }
        return sessionByTileID[splitTileID]
    }

    /// The non-primary leaf of `tree` (the split tile). Returns `nil` if the primary binding is gone.
    private func splitTileID(in tree: TileTreeState, primarySessionID: UUID) -> TileID? {
        // Depth-1 contract for the projections above: a two-leaf tree has exactly one non-primary leaf.
        // On a deeper tree "first leaf that isn't the primary" would pick an arbitrary sibling, so trip
        // loudly — production reads the tree directly and never routes a deep tree through here.
        assert(tree.leafIDs.count == 2, "split projections are depth-1 only — read the tree for deeper layouts")
        guard let primaryTile = tileIDBySessionID[primarySessionID] else { return nil }
        return tree.leafIDs.first(where: { $0 != primaryTile })
    }

    /// Live split sessions across every tab — every non-primary leaf of every tab's tree. Derived from
    /// the trees rather than a free-standing binding scan, so it is the single source of truth for what
    /// is registered with the agent subsystems and holds at any depth (each extra pane is a leaf here).
    private var derivedSplitSessions: [HostTerminalSession] {
        treesByPrimaryID.flatMap { primarySessionID, tree -> [HostTerminalSession] in
            splitSessions(in: tree, primarySessionID: primarySessionID)
        }
    }

    /// Live split sessions for a tab, including depth ≥ 2 panes. This is the public read path for
    /// app controllers that need every non-primary surface; the legacy `splitSession` projection above
    /// intentionally remains depth-1 only.
    func splitSessions(forPrimarySessionID primarySessionID: UUID?) -> [HostTerminalSession] {
        guard let primarySessionID, let tree = treesByPrimaryID[primarySessionID] else { return [] }
        return splitSessions(in: tree, primarySessionID: primarySessionID)
    }

    private func splitSessions(in tree: TileTreeState, primarySessionID: UUID) -> [HostTerminalSession] {
        guard let primaryTile = tileIDBySessionID[primarySessionID] else { return [] }
        return tree.leafIDs.compactMap { tileID in
            tileID == primaryTile ? nil : sessionByTileID[tileID]
        }
    }

    /// The active arrangement for a tab, or `nil` for a single-pane tab (sparse model: no split ⇒ no
    /// entry). The recursive renderer walks this; the depth-1 projections above read it.
    func tileTree(forPrimarySessionID primarySessionID: UUID?) -> TileTreeState? {
        guard let primarySessionID else { return nil }
        return treesByPrimaryID[primarySessionID]
    }

    /// Resolves the session filling a leaf tile — the renderer's `.tile` → terminal binding.
    func session(forTile tileID: TileID) -> HostTerminalSession? {
        sessionByTileID[tileID]
    }

    /// Live pane count for a tab: a split tab's leaf count, or `1` for a single pane. Depth-agnostic,
    /// so the sidebar's "has live session" badge counts every tile, not just a single split sibling.
    func paneCount(forPrimarySessionID primarySessionID: UUID) -> Int {
        treesByPrimaryID[primarySessionID]?.leafIDs.count ?? 1
    }

    /// Splits the tile holding `sourceSessionID` along `preferredLayout`, growing the tab's tree by one
    /// pane and binding a fresh `HostTerminalSession` to the new tile (focused on return). A tab with no
    /// split yet is seeded with a single tile bound to its primary (the depth-0 shape), so the first
    /// split grows from there; subsequent calls split whatever pane was the source → deeper trees.
    @discardableResult
    func splitFocusedTile(
        inTabContaining sourceSessionID: UUID,
        preferredLayout: SplitPaneLayout = .defaultTrailing
    ) -> HostTerminalSession? {
        guard let primarySessionID = primarySessionID(containing: sourceSessionID),
            let primarySession = sessions.first(where: { $0.id == primarySessionID })
        else {
            return nil
        }

        let existingTree = treesByPrimaryID[primarySessionID]
        let primaryTile = tileIDBySessionID[primarySessionID] ?? automationTileID(for: primarySessionID)
        let seedTree = existingTree ?? TileTreeState(singleTile: primaryTile)
        // Split the source pane's tile when it is bound; a freshly seeded tab has only the primary,
        // whose tile is `seedTree.focusedTileID`.
        let parentTile = tileIDBySessionID[sourceSessionID] ?? seedTree.focusedTileID

        let grownTree = tileTreeReducer.reduce(
            seedTree,
            .split(
                parent: parentTile,
                axis: preferredLayout.axis.tileAxis,
                insertNewBefore: preferredLayout.splitBeforePrimary
            )
        )
        let newTile = grownTree.focusedTileID
        // The reducer focuses the inserted tile; an unchanged focus means `parentTile` was not a live
        // leaf and no split happened — abort before mutating any binding (keeps a seeded tab pristine).
        guard newTile != parentTile else { return nil }

        // A non-primary pane needs its own tmux session name: the primary's is a pure
        // function of the shared directory, so two `new-session -A` launches on that
        // name would attach to one session — two mirrored views, one shell (#1232).
        let splitSessionID = UUID()
        let splitSession = HostTerminalSession(
            id: splitSessionID,
            key: primarySession.key,
            directory: primarySession.directoryURL,
            tmuxSessionNameOverride: TmuxSessionNaming.splitPaneName(
                for: primarySession.directoryURL,
                paneSessionID: splitSessionID
            )
        )

        if existingTree == nil {
            sessionByTileID[primaryTile] = primarySession
            tileIDBySessionID[primarySessionID] = primaryTile
        }
        sessionByTileID[newTile] = splitSession
        tileIDBySessionID[splitSession.id] = newTile
        primaryIDBySplitSessionID[splitSession.id] = primarySessionID
        treesByPrimaryID[primarySessionID] = grownTree

        syncRegistry()
        syncAutomationRegistry()
        surfaceStore.sync(activeLeafIDs: activeLeafTileIDs)
        objectWillChange.send()
        return splitSession
    }

    /// Sets the ratio of a specific split — the recursive renderer's divider-drag entry. `splitID`
    /// identifies the dragged split anywhere in the tree, so depth-≥2 dividers resize their own split.
    @discardableResult
    func updateSplitRatio(
        _ ratio: CGFloat,
        splitID: SplitID,
        forPrimarySessionID primarySessionID: UUID
    ) -> Bool {
        // Outer clamp before the reducer's own `clampRatio` preserves legacy NaN handling (NaN → 0.2,
        // the host bound) rather than the reducer's NaN → defaultRatio.
        let clampedFraction = Self.clampedSplitFraction(ratio)
        return applySplitMutation(
            forPrimarySessionID: primarySessionID,
            action: .setRatio(split: splitID, ratio: Double(clampedFraction))
        )
    }

    /// Depth-1 convenience: set the root split's ratio. Retained for the two-pane store tests; the live
    /// renderer drags through `updateSplitRatio(_:splitID:…)` with the dragged split's id.
    @discardableResult
    func updateSplitFraction(_ fraction: CGFloat, forPrimarySessionID primarySessionID: UUID) -> Bool {
        guard let tree = treesByPrimaryID[primarySessionID],
            case .split(let splitID, _, _, _, _) = tree.root
        else {
            return false
        }
        return updateSplitRatio(fraction, splitID: splitID, forPrimarySessionID: primarySessionID)
    }

    @discardableResult
    func equalizeSplit(containing sourceSessionID: UUID) -> Bool {
        guard let primarySessionID = primarySessionID(containing: sourceSessionID),
            treesByPrimaryID[primarySessionID] != nil
        else {
            return false
        }
        return applySplitMutation(
            forPrimarySessionID: primarySessionID,
            action: .equalize(subtreeRoot: nil)
        )
    }

    @discardableResult
    func resizeSplit(
        containing sourceSessionID: UUID,
        direction: GhosttyAppManager.SplitResizeDirection,
        amount: Int
    ) -> Bool {
        guard let primarySessionID = primarySessionID(containing: sourceSessionID),
            let tree = treesByPrimaryID[primarySessionID],
            let sourceTile = tileIDBySessionID[sourceSessionID],
            let enclosing = tree.root.enclosingSplit(of: sourceTile)
        else {
            return false
        }

        // Resize the split enclosing the source pane (not the root), so a nested pane grows its own
        // divider. `leafIsFirst` plays the role the legacy leading-pane test did at depth 1.
        guard
            let delta = resizeDelta(
                axis: enclosing.axis,
                sourceIsLeadingPane: enclosing.leafIsFirst,
                direction: direction,
                amount: amount
            )
        else {
            return false
        }

        return applySplitMutation(
            forPrimarySessionID: primarySessionID,
            action: .resize(split: enclosing.id, ratioDelta: Double(delta))
        )
    }

    /// Runs a reducer action against the tab's tree and commits it iff the tree actually changed —
    /// preserving the `Bool`/`objectWillChange` semantics (no over-firing) while generalizing the
    /// legacy root-ratio diff to a whole-tree compare, so a ratio change on any nested split commits.
    private func applySplitMutation(
        forPrimarySessionID primarySessionID: UUID,
        action: TileTreeAction
    ) -> Bool {
        guard let tree = treesByPrimaryID[primarySessionID] else { return false }
        let next = tileTreeReducer.reduce(tree, action)
        guard next != tree else { return false }
        treesByPrimaryID[primarySessionID] = next
        objectWillChange.send()
        return true
    }

    /// Resolves the focus target for `goto_split` by reducing from the source pane's tile: directional
    /// moves use the reducer's geometric traversal (unit-square frames, edge adjacency, max
    /// perpendicular overlap — hardened for depth ≥ 2 in #690), previous/next cycle the depth-first
    /// leaf order. Persists the moved focus so a following split grows from the right tile.
    func splitFocusTarget(
        from sourceSessionID: UUID,
        direction: GhosttyAppManager.SplitFocusDirection
    ) -> UUID? {
        guard let primarySessionID = activatePrimarySession(containing: sourceSessionID),
            let tree = treesByPrimaryID[primarySessionID],
            let sourceTile = tileIDBySessionID[sourceSessionID]
        else {
            return nil
        }

        let action: TileTreeAction
        switch direction {
        case .previous:
            action = .focusRelative(from: sourceTile, order: .previous)
        case .next:
            action = .focusRelative(from: sourceTile, order: .next)
        case .left:
            action = .focusDirectional(from: sourceTile, direction: .left)
        case .right:
            action = .focusDirectional(from: sourceTile, direction: .right)
        case .up:
            action = .focusDirectional(from: sourceTile, direction: .up)
        case .down:
            action = .focusDirectional(from: sourceTile, direction: .down)
        }

        // Normalize focus to the source pane first so "no neighbor" is a focus that did not move.
        let normalized = tileTreeReducer.reduce(tree, .setFocus(sourceTile))
        let navigated = tileTreeReducer.reduce(normalized, action)
        guard navigated.focusedTileID != sourceTile,
            let targetSession = sessionByTileID[navigated.focusedTileID]
        else {
            return nil
        }

        treesByPrimaryID[primarySessionID] = navigated
        return targetSession.id
    }

    static func clampedSplitFraction(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, minimumSplitFraction), maximumSplitFraction)
    }

    private func publishSnapshot() {
        sessions = coordinator.sessions
        scopedSessions = coordinator.sessions(inScope: coordinator.activeScopeKey)
        activeSessionID = coordinator.activeSessionID
        sessionPresentation = coordinator.presentation

        let validPrimaryIDs = Set(sessions.map(\.id))
        let stalePrimaryIDs = treesByPrimaryID.keys.filter { !validPrimaryIDs.contains($0) }
        for primaryID in stalePrimaryIDs {
            removeSplitState(forPrimarySessionID: primaryID)
        }

        syncRegistry()
        syncAutomationRegistry()

        for session in sessions {
            recordTerminalSession(
                session,
                isActive: coordinator.activeSessionIDByScopeKey[session.key] == session.id
            )
        }
        for splitSession in derivedSplitSessions {
            recordTerminalSession(splitSession, isActive: false)
        }

        // Surface eviction authority: after the tree/registry reconcile settles, free every surface
        // whose leaf is no longer live. `sync`'s absent-tile path is a silent no-op, so this is safe
        // to run after every snapshot even when nothing was dropped.
        surfaceStore.sync(activeLeafIDs: activeLeafTileIDs)
    }

    /// Mirror the coordinator's session list into the agent session registry so the
    /// hook listener has somewhere to land payloads. Idempotent — `register` and
    /// `deregister` are no-ops on already-registered / already-removed ids.
    private func syncRegistry() {
        guard let registry = agentSessionRegistry else { return }
        let allSessions = coordinator.sessions + derivedSplitSessions
        let liveIDs = Set(allSessions.map(\.id))

        // Register newly-seen sessions.
        for session in allSessions where !registeredAgentSessionIDs.contains(session.id) {
            // PR #1: probe is a stub returning `.claudeCode` for every surface.
            // Replace surfaceID with a real value when foreground Agent
            // detection lands.
            let kind = foregroundProbe.detect(surfaceID: 0)
            registry.register(
                hostSessionID: session.id,
                cwd: session.directoryPath,
                kind: kind
            )
            registeredAgentSessionIDs.insert(session.id)
            recordTerminalSession(
                session,
                isActive: coordinator.activeSessionIDByScopeKey[session.key] == session.id
            )
        }

        // Deregister sessions that have left the coordinator.
        let removed = registeredAgentSessionIDs.subtracting(liveIDs)
        for sessionID in removed {
            registry.deregister(hostSessionID: sessionID)
            lastCommandStatusRegistry?.clear(terminalSessionID: sessionID)
            recordTerminalSessionEnded(sessionID)
            automationHandleRegistry?.remove(hostSessionID: sessionID)
            forgetTileBinding(for: sessionID)
        }
        registeredAgentSessionIDs.subtract(removed)
    }

    /// Upserts an automation handle for every live session against its unified tile id. The stale-removal
    /// half that the old `syncAutomationRegistry` carried now lives in `syncRegistry`'s removed loop and
    /// `deregisterTerminalSession`, so eviction has one authority.
    private func syncAutomationRegistry() {
        guard let automationHandleRegistry, automationSocketPath != nil else { return }
        for session in coordinator.sessions + derivedSplitSessions {
            _ = automationHandleRegistry.upsert(
                hostSessionID: session.id,
                tileID: automationTileID(for: session.id),
                surfaceKind: .terminal,
                windowScopeID: automationWindowScopeID,
                appScopeID: automationAppScopeID,
                capabilities: automationGrantedCapabilities
            )
        }
    }

    /// Grant list for automation handles. `input.write` joins only while its experiment is on;
    /// `AutomationController` re-checks the flag per request because handles outlive settings changes.
    private var automationGrantedCapabilities: [AutomationCapability] {
        ExperimentalFeatures.isEnabled(.automationInputWrite)
            ? AutomationAPI.inputWriteCapabilities
            : AutomationAPI.v1Capabilities
    }

    /// Drops a single-pane primary's memoized tile binding when its session leaves. Split leaf bindings
    /// are removed by the tree-collapse paths (`dropSplitTree` / `closeSplitPane`); this guards the
    /// unsplit case so a retired single-pane session leaves no stale tile identity behind.
    private func forgetTileBinding(for sessionID: UUID) {
        guard let tileID = tileIDBySessionID.removeValue(forKey: sessionID) else { return }
        if sessionByTileID[tileID]?.id == sessionID {
            sessionByTileID.removeValue(forKey: tileID)
        }
    }

    /// Collapses the split for `primarySessionID` (process-exit / reconcile path): drops its tree and
    /// bindings, then deregisters the split session(s). Surface eviction follows from the dropped leaf
    /// via `SurfaceStore.sync` (run by the enclosing `publishSnapshot`), not a per-session invalidate.
    /// Dropping the dict entry — rather than reducing a `.close` (which would re-seed a single tile) —
    /// is the sparse-model collapse: no entry ⇒ single pane.
    private func removeSplitState(forPrimarySessionID primarySessionID: UUID) {
        for session in dropSplitTree(forPrimarySessionID: primarySessionID) {
            killPaneScopedTmuxSession(for: session)
            deregisterTerminalSession(session.id)
        }
    }

    /// Closes a single split pane (its process exited): reduces `.close` on the pane's tile so its
    /// enclosing split collapses into the surviving sibling, leaving every other pane intact. When the
    /// tab is left with only its primary the tree drops to the sparse single-pane shape; otherwise the
    /// rebalanced tree (one fewer pane) is kept. The pane's session is torn down either way. At depth 1
    /// this is identical to dropping the whole tree — there is only ever one split pane to remove.
    private func closeSplitPane(_ sessionID: UUID, primarySessionID: UUID) {
        guard let tree = treesByPrimaryID[primarySessionID],
            let tile = tileIDBySessionID[sessionID]
        else {
            return
        }

        let reduced = tileTreeReducer.reduce(tree, .close(tile))

        let paneSession = sessionByTileID.removeValue(forKey: tile)
        tileIDBySessionID.removeValue(forKey: sessionID)
        primaryIDBySplitSessionID.removeValue(forKey: sessionID)
        if let paneSession {
            killPaneScopedTmuxSession(for: paneSession)
        }

        if reduced.leafIDs.count <= 1 {
            // Only the primary remains → collapse to the sparse single-pane shape (no tree). The
            // primary keeps its tile binding: under the unified identity that tile is now the
            // single-pane render id, so the live surface mounted on it stays bound across the
            // collapse (re-keying would orphan the terminal and lose its scrollback) and
            // `activeLeafTileIDs` keeps including it, so `sync` won't evict the survivor.
            treesByPrimaryID.removeValue(forKey: primarySessionID)
        } else {
            treesByPrimaryID[primarySessionID] = reduced
        }

        deregisterTerminalSession(sessionID)
        objectWillChange.send()
    }

    /// Drops the split tree for `primarySessionID` and every binding it owned, returning the split
    /// session(s) it held (the non-primary leaves) so the caller can tear them down its own way —
    /// collapse invalidation vs post-close workspace cleanup. The primary tile binding falls away
    /// with the tree; the primary session itself stays in the coordinator and is untouched here.
    @discardableResult
    private func dropSplitTree(forPrimarySessionID primarySessionID: UUID) -> [HostTerminalSession] {
        guard let tree = treesByPrimaryID.removeValue(forKey: primarySessionID) else { return [] }
        // A live tree always carries its primary tile binding; without it the `tileID != primaryTile`
        // guard below would treat the primary as a split and tear down a session still in the
        // coordinator. The drop mutates the tree dict, so notify (callers also `publishSnapshot`,
        // making this a benign double-fire that keeps the mutator self-sufficient for direct callers).
        let primaryTile = tileIDBySessionID[primarySessionID]
        assert(primaryTile != nil, "primary tile binding must exist while its split tree does")
        objectWillChange.send()

        var splitSessions: [HostTerminalSession] = []
        for tileID in tree.leafIDs {
            guard let session = sessionByTileID.removeValue(forKey: tileID) else { continue }
            tileIDBySessionID.removeValue(forKey: session.id)
            guard tileID != primaryTile else { continue }

            primaryIDBySplitSessionID.removeValue(forKey: session.id)
            splitSessions.append(session)
        }
        return splitSessions
    }

    /// The tmux session a torn-down session must reclaim, or `nil` when nothing may die: no
    /// override, an override that is not shaped like the app's own split-pane naming, or
    /// non-tmux mode. A pane-scoped override is unreachable by directory derivation, and
    /// teardown ends its continuity row, so an unkilled one would be stranded with no reclaim
    /// path (#1232).
    ///
    /// The shape check — not "differs from the directory derivation" — is what this guards.
    /// That broader test also matched a restored primary override (a live session a *previous*
    /// run created, safe: any future launch in that directory `-A`-reattaches it) and, once
    /// adoption could bind an arbitrary live session by directory match (#1390), an externally
    /// owned session with no relationship to this app at all. Closing that tab would otherwise
    /// `kill-session` someone else's live shell.
    func paneScopedTmuxSessionNameToKill(for session: HostTerminalSession) -> String? {
        guard let sessionName = session.tmuxSessionNameOverride,
            TmuxSessionNaming.isPaneScopedName(sessionName, for: session.directoryURL),
            resolveTerminalMultiplexingMode() == .tmuxPerSession
        else {
            return nil
        }
        return sessionName
    }

    /// Best-effort async kill of a torn-down pane's tmux session. In-app teardown only —
    /// app quit never reaches the close paths, so directory-derived sessions (and every
    /// session on quit) survive for cold-start restore. Failure just logs: the session
    /// may already be gone (its shell exited, which is what ended the surface).
    private func killPaneScopedTmuxSession(for session: HostTerminalSession) {
        guard let sessionName = paneScopedTmuxSessionNameToKill(for: session) else { return }
        let kill = killTmuxSession
        Task {
            if await kill(sessionName) {
                log.info(
                    "[TileTreeStore] reclaimed pane tmux session \(sessionName, privacy: .public) on close")
            } else {
                log.notice(
                    "[TileTreeStore] pane tmux session \(sessionName, privacy: .public) kill failed or already gone"
                )
            }
        }
    }

    /// Deregisters a session from the agent subsystems if it was registered. Shared by the
    /// collapse and retire teardown paths, which differ only in their surface-store call.
    private func deregisterTerminalSession(_ sessionID: UUID) {
        defer {
            automationHandleRegistry?.remove(hostSessionID: sessionID)
            forgetTileBinding(for: sessionID)
        }
        guard registeredAgentSessionIDs.contains(sessionID) else { return }
        agentSessionRegistry?.deregister(hostSessionID: sessionID)
        lastCommandStatusRegistry?.clear(terminalSessionID: sessionID)
        recordTerminalSessionEnded(sessionID)
        registeredAgentSessionIDs.remove(sessionID)
    }

    private func retireTerminalSession(_ sessionID: UUID) {
        deregisterTerminalSession(sessionID)
    }

    private func recordTerminalSession(_ session: HostTerminalSession, isActive: Bool) {
        continuityRecorder?.record(
            session,
            terminalMode: resolveTerminalMultiplexingMode().rawValue,
            isActive: isActive,
            hooksSocketPath: surfaceStore.hooksSocketPath
        )
    }

    private func recordTerminalSessionEnded(_ sessionID: UUID) {
        continuityRecorder?.recordEnded(sessionID)
    }

    func automationEnvironment(for session: HostTerminalSession) -> AutomationTerminalEnvironment? {
        guard let automationHandleRegistry, let automationSocketPath else {
            if ExperimentalFeatures.isEnabled(.automationAPI) {
                log.error(
                    "[TileTreeStore] automation environment unavailable for session \(session.id.uuidString, privacy: .public) while Automation API is enabled (handleRegistry=\(self.automationHandleRegistry == nil ? "nil" : "configured", privacy: .public) socketPath=\(self.automationSocketPath == nil ? "nil" : "configured", privacy: .public))"
                )
            }
            return nil
        }
        let entry = automationHandleRegistry.upsert(
            hostSessionID: session.id,
            tileID: automationTileID(for: session.id),
            surfaceKind: .terminal,
            windowScopeID: automationWindowScopeID,
            appScopeID: automationAppScopeID,
            capabilities: automationGrantedCapabilities
        )
        return AutomationTerminalEnvironment(socketPath: automationSocketPath, handle: entry.handle)
    }

    func automationTileIDString(for sessionID: UUID) -> String? {
        automationTileID(for: sessionID).rawValue.uuidString
    }

    /// The automation handle's tile id for a session — the same unified `tileIDBySessionID` identity
    /// the renderer and `SurfaceStore.sync` use. Memoizes a single-pane primary's tile if it has no
    /// split yet (via `renderTileID`), so automation and render never disagree on a session's tile.
    private func automationTileID(for sessionID: UUID) -> TileID {
        if let tileID = tileIDBySessionID[sessionID] {
            return tileID
        }
        return renderTileID(for: sessionID)
    }

    private func resolvedPrimarySessionID(_ sourceSessionID: UUID?) -> UUID? {
        if let sourceSessionID {
            return primarySessionID(containing: sourceSessionID)
        }
        return activeSessionID
    }

    private func resizeDelta(
        axis: SplitAxis,
        sourceIsLeadingPane: Bool,
        direction: GhosttyAppManager.SplitResizeDirection,
        amount: Int
    ) -> CGFloat? {
        let stepCount = max(1, Int(round(Double(max(amount, 1)) / 100.0)))
        let delta = CGFloat(stepCount) * Self.splitResizeStep

        switch (axis, sourceIsLeadingPane, direction) {
        case (.leadingTrailing, true, .right), (.topBottom, true, .down):
            return delta
        case (.leadingTrailing, false, .left), (.topBottom, false, .up):
            return -delta
        default:
            return nil
        }
    }
}
