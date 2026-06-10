import SwiftUI
import WorkspaceManagerCore

@MainActor
final class HostTerminalStateStore: ObservableObject {
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
    private var tileIDBySessionID: [UUID: TileID] = [:]
    private var primaryIDBySplitSessionID: [UUID: UUID] = [:]
    private let tileTreeReducer = TileTreeReducer()

    let surfaceStore = HostTerminalSurfaceStore()
    private var coordinator = HostTerminalSessionCoordinator()

    /// Agent session registry attached at scene mount. Optional because previews and
    /// fixtures construct stores without an app-scoped registry.
    private weak var agentSessionRegistry: AgentSessionRegistry?
    private weak var lastCommandStatusRegistry: LastCommandStatusRegistry?
    private var localStateStore: LocalStateStore?
    /// Stub probe used to seed `kind` on register; PR #1 ships a fail-safe
    /// `.claudeCode` default. Replace with the real probe in a Channel 3 follow-up.
    private let foregroundProbe = PTYForegroundProbe()
    /// Set of session IDs the store has already registered with the agent registry,
    /// so we only register/deregister on real edge transitions.
    private var registeredAgentSessionIDs: Set<UUID> = []

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
        self.localStateStore = localStateStore
        self.lastCommandStatusRegistry = lastCommandStatusRegistry
        self.surfaceStore.hooksSocketPath = hooksSocketPath
        guard self.agentSessionRegistry !== agentSessionRegistry else {
            syncRegistry()
            return
        }
        self.agentSessionRegistry = agentSessionRegistry
        // Backfill: any sessions already in the coordinator should be registered.
        syncRegistry()

        // Channel 3: hook the surface→host-session resolver into the OSC router so
        // libghostty desktop notifications and BEL events can find their session.
        let store = self.surfaceStore
        AgentOSCRouter.shared.attach(registry: agentSessionRegistry) { surfaceView in
            store.sessionID(for: surfaceView)
        }
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
        customCommand: String? = nil
    ) -> HostTerminalSessionActivationResult {
        let result = coordinator.activate(key: key, directory: directory, customCommand: customCommand)
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
        if let normalizedTitle, !normalizedTitle.isEmpty {
            tabTitleOverridesBySessionID[primarySessionID] = normalizedTitle
        } else {
            tabTitleOverridesBySessionID.removeValue(forKey: primarySessionID)
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
            surfaceStore.invalidate(sessionID: removedSessionID)
            removeSplitState(forPrimarySessionID: removedSessionID)
            tabTitleOverridesBySessionID.removeValue(forKey: removedSessionID)
        }

        publishSnapshot()
    }

    @discardableResult
    func handleProcessExit(for sessionID: UUID) -> Bool {
        var removed = false

        if let primarySessionID = primaryIDBySplitSessionID[sessionID] {
            removeSplitState(forPrimarySessionID: primarySessionID)
            removed = true
        }

        if coordinator.remove(sessionID: sessionID) != nil {
            surfaceStore.invalidate(sessionID: sessionID)
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
        guard let primaryTile = tileIDBySessionID[primarySessionID] else { return nil }
        return tree.leafIDs.first(where: { $0 != primaryTile })
    }

    /// Live split sessions across every tab, derived from the tree entries rather than a free-standing
    /// binding scan — the single source of truth for what is registered with the agent subsystems.
    private var derivedSplitSessions: [HostTerminalSession] {
        treesByPrimaryID.compactMap { primarySessionID, tree in
            splitSession(in: tree, primarySessionID: primarySessionID)
        }
    }

    @discardableResult
    func ensureSplitForActiveSession(
        preferredLayout: SplitPaneLayout = .defaultTrailing
    ) -> HostTerminalSession? {
        guard let activeSessionID else { return nil }
        return ensureSplit(
            forPrimarySessionID: activeSessionID,
            preferredLayout: preferredLayout
        )
    }

    @discardableResult
    func ensureSplit(
        forPrimarySessionID primarySessionID: UUID,
        preferredLayout: SplitPaneLayout = .defaultTrailing
    ) -> HostTerminalSession? {
        guard let primarySession = sessions.first(where: { $0.id == primarySessionID }) else {
            return nil
        }

        if treesByPrimaryID[primarySessionID] != nil {
            return relayoutSplit(forPrimarySessionID: primarySessionID, preferredLayout: preferredLayout)
        }

        let splitSession = HostTerminalSession(
            key: primarySession.key,
            directory: primarySession.directoryURL
        )
        let primaryTile = TileID()
        var tree = TileTreeState(singleTile: primaryTile)
        tree = tileTreeReducer.reduce(
            tree,
            .split(
                parent: primaryTile,
                axis: preferredLayout.axis.tileAxis,
                insertNewBefore: preferredLayout.splitBeforePrimary
            )
        )
        let splitTile = tree.focusedTileID

        sessionByTileID[primaryTile] = primarySession
        sessionByTileID[splitTile] = splitSession
        tileIDBySessionID[primarySessionID] = primaryTile
        tileIDBySessionID[splitSession.id] = splitTile
        primaryIDBySplitSessionID[splitSession.id] = primarySessionID
        treesByPrimaryID[primarySessionID] = tree

        syncRegistry()
        objectWillChange.send()
        return splitSession
    }

    /// Re-applies `preferredLayout` to an existing split **without re-minting identity**: the live
    /// terminal would orphan if relayout routed through `.close` + `.split` (fresh `TileID`/`SplitID`
    /// and a new session). Instead the root `.split` is hand-transformed — only `axis` and the
    /// `(first, second)` order may change; `SplitID`, `ratio`, and both tile leaves are preserved.
    /// Fires `objectWillChange` only when axis/order actually changed, and never re-syncs the registry
    /// (the session set is unchanged), matching the legacy relayout branch.
    private func relayoutSplit(
        forPrimarySessionID primarySessionID: UUID,
        preferredLayout: SplitPaneLayout
    ) -> HostTerminalSession? {
        guard var tree = treesByPrimaryID[primarySessionID],
            case .split(let splitID, let axis, let ratio, let first, let second) = tree.root,
            let primaryTile = tileIDBySessionID[primarySessionID],
            let splitTile = splitTileID(in: tree, primarySessionID: primarySessionID),
            let splitSession = sessionByTileID[splitTile]
        else {
            return nil
        }

        let targetAxis = preferredLayout.axis.tileAxis
        let primaryLeaf = TileTree.tile(primaryTile)
        let splitLeaf = TileTree.tile(splitTile)
        let (newFirst, newSecond) =
            preferredLayout.splitBeforePrimary ? (splitLeaf, primaryLeaf) : (primaryLeaf, splitLeaf)

        guard axis != targetAxis || first != newFirst || second != newSecond else {
            return splitSession
        }

        tree.root = .split(id: splitID, axis: targetAxis, ratio: ratio, first: newFirst, second: newSecond)
        treesByPrimaryID[primarySessionID] = tree
        objectWillChange.send()
        return splitSession
    }

    @discardableResult
    func updateSplitFraction(_ fraction: CGFloat, forPrimarySessionID primarySessionID: UUID) -> Bool {
        guard let tree = treesByPrimaryID[primarySessionID],
            case .split(let splitID, _, _, _, _) = tree.root
        else {
            return false
        }
        let clampedFraction = Self.clampedSplitFraction(fraction)
        return applyRootSplitMutation(
            forPrimarySessionID: primarySessionID,
            action: .setRatio(split: splitID, ratio: Double(clampedFraction))
        )
    }

    @discardableResult
    func equalizeSplit(containing sourceSessionID: UUID) -> Bool {
        guard let primarySessionID = primarySessionID(containing: sourceSessionID),
            treesByPrimaryID[primarySessionID] != nil
        else {
            return false
        }
        return applyRootSplitMutation(
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
            case .split(let splitID, _, _, _, _) = tree.root,
            let splitSession = splitSession(in: tree, primarySessionID: primarySessionID)
        else {
            return false
        }

        let layout = splitLayout(for: primarySessionID) ?? .defaultTrailing
        let sourceIsSplit = splitSession.id == sourceSessionID
        guard
            let delta = resizeDelta(
                for: layout,
                sourceIsSplit: sourceIsSplit,
                direction: direction,
                amount: amount
            )
        else {
            return false
        }

        return applyRootSplitMutation(
            forPrimarySessionID: primarySessionID,
            action: .resize(split: splitID, ratioDelta: Double(delta))
        )
    }

    /// Runs a ratio-only reducer action against the tab's tree and commits it iff the root ratio
    /// actually changed — preserving the legacy `Bool`/`objectWillChange` semantics (no over-firing).
    private func applyRootSplitMutation(
        forPrimarySessionID primarySessionID: UUID,
        action: TileTreeAction
    ) -> Bool {
        guard let tree = treesByPrimaryID[primarySessionID],
            case .split(_, _, let oldRatio, _, _) = tree.root
        else {
            return false
        }
        let next = tileTreeReducer.reduce(tree, action)
        guard case .split(_, _, let newRatio, _, _) = next.root, newRatio != oldRatio else {
            return false
        }
        treesByPrimaryID[primarySessionID] = next
        objectWillChange.send()
        return true
    }

    /// Computes the target session for split focus navigation in our current
    /// two-pane split model (primary + optional split with direction-aware layout).
    func splitFocusTarget(
        from sourceSessionID: UUID,
        direction: GhosttyAppManager.SplitFocusDirection
    ) -> UUID? {
        guard let primarySessionID = activatePrimarySession(containing: sourceSessionID),
            let splitSession = splitSession(for: primarySessionID)
        else {
            return nil
        }

        let layout = splitLayout(for: primarySessionID) ?? .defaultTrailing
        let sourceIsSplit = splitSession.id == sourceSessionID

        switch direction {
        case .previous, .next:
            return sourceIsSplit ? primarySessionID : splitSession.id

        case .left:
            guard layout.axis == .leadingTrailing else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? nil : splitSession.id
            }
            return sourceIsSplit ? primarySessionID : nil

        case .right:
            guard layout.axis == .leadingTrailing else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? primarySessionID : nil
            }
            return sourceIsSplit ? nil : splitSession.id

        case .up:
            guard layout.axis == .topBottom else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? nil : splitSession.id
            }
            return sourceIsSplit ? primarySessionID : nil

        case .down:
            guard layout.axis == .topBottom else { return nil }
            if layout.splitBeforePrimary {
                return sourceIsSplit ? primarySessionID : nil
            }
            return sourceIsSplit ? nil : splitSession.id
        }
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

        for session in sessions {
            recordTerminalSession(
                session,
                isActive: coordinator.activeSessionIDByScopeKey[session.key] == session.id
            )
        }
        for splitSession in derivedSplitSessions {
            recordTerminalSession(splitSession, isActive: false)
        }
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
            // Replace surfaceID with a real value when the Channel 3 probe lands.
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
        }
        registeredAgentSessionIDs.subtract(removed)
    }

    /// Collapses the split for `primarySessionID` by dropping its tree entry and every binding it
    /// owned, then deregistering the split session(s) it held. Dropping the dict entry — rather than
    /// reducing a `.close` (which would re-seed a single tile) — is the sparse-model collapse: no
    /// entry ⇒ single pane. The primary tile binding falls away with the tree; the primary session
    /// itself stays in the coordinator and is untouched here.
    private func removeSplitState(forPrimarySessionID primarySessionID: UUID) {
        guard let tree = treesByPrimaryID.removeValue(forKey: primarySessionID) else { return }
        let primaryTile = tileIDBySessionID[primarySessionID]

        for tileID in tree.leafIDs {
            guard let session = sessionByTileID.removeValue(forKey: tileID) else { continue }
            tileIDBySessionID.removeValue(forKey: session.id)
            guard tileID != primaryTile else { continue }

            primaryIDBySplitSessionID.removeValue(forKey: session.id)
            surfaceStore.invalidate(sessionID: session.id)
            if registeredAgentSessionIDs.contains(session.id) {
                agentSessionRegistry?.deregister(hostSessionID: session.id)
                lastCommandStatusRegistry?.clear(terminalSessionID: session.id)
                recordTerminalSessionEnded(session.id)
                registeredAgentSessionIDs.remove(session.id)
            }
        }
    }

    private func recordTerminalSession(_ session: HostTerminalSession, isActive: Bool) {
        guard let localStateStore else { return }
        let terminalMode = TerminalMultiplexingMode.resolve().rawValue
        let hooksSocketPath = surfaceStore.hooksSocketPath
        Task {
            try? await localStateStore.recordTerminalSession(
                session,
                terminalMode: terminalMode,
                isActive: isActive,
                hooksSocketPath: hooksSocketPath
            )
        }
    }

    private func recordTerminalSessionEnded(_ sessionID: UUID) {
        guard let localStateStore else { return }
        Task {
            try? await localStateStore.markTerminalSessionEnded(hostSessionID: sessionID)
        }
    }

    private func resolvedPrimarySessionID(_ sourceSessionID: UUID?) -> UUID? {
        if let sourceSessionID {
            return primarySessionID(containing: sourceSessionID)
        }
        return activeSessionID
    }

    private func resizeDelta(
        for layout: SplitPaneLayout,
        sourceIsSplit: Bool,
        direction: GhosttyAppManager.SplitResizeDirection,
        amount: Int
    ) -> CGFloat? {
        let sourceIsLeadingPane = layout.splitBeforePrimary ? sourceIsSplit : !sourceIsSplit
        let stepCount = max(1, Int(round(Double(max(amount, 1)) / 100.0)))
        let delta = CGFloat(stepCount) * Self.splitResizeStep

        switch (layout.axis, sourceIsLeadingPane, direction) {
        case (.leadingTrailing, true, .right), (.topBottom, true, .down):
            return delta
        case (.leadingTrailing, false, .left), (.topBottom, false, .up):
            return -delta
        default:
            return nil
        }
    }
}
