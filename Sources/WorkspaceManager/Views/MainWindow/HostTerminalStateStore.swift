import SwiftUI
import WorkspaceManagerCore

@MainActor
final class HostTerminalStateStore: ObservableObject {
    struct SplitPaneLayout: Equatable {
        enum Axis: Equatable {
            case leadingTrailing
            case topBottom
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
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var splitSessionsByPrimaryID: [UUID: HostTerminalSession] = [:]
    @Published private(set) var splitLayoutsByPrimaryID: [UUID: SplitPaneLayout] = [:]
    @Published private(set) var splitFractionsByPrimaryID: [UUID: CGFloat] = [:]
    @Published private(set) var tabTitleOverridesBySessionID: [UUID: String] = [:]
    @Published private(set) var sessionPresentation = HostTerminalSessionPresentation()

    let surfaceStore = HostTerminalSurfaceStore()
    private var coordinator = HostTerminalSessionCoordinator()

    /// Agent session registry attached at scene mount. Optional because previews and
    /// fixtures construct stores without an app-scoped registry.
    private weak var agentSessionRegistry: AgentSessionRegistry?
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
        hooksSocketPath: String?
    ) {
        self.localStateStore = localStateStore
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
        guard let session = coordinator.sessions.first(where: { $0.id == sessionID }) else {
            return false
        }

        _ = coordinator.activate(key: session.key, directory: session.directoryURL)
        publishSnapshot()
        return true
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
            let primaryIndex = coordinator.sessions.firstIndex(where: { $0.id == primarySessionID })
        else {
            return []
        }

        switch mode {
        case .this:
            return [primarySessionID]
        case .other:
            return coordinator.sessions.map(\.id).filter { $0 != primarySessionID }
        case .right:
            let rightStart = coordinator.sessions.index(after: primaryIndex)
            guard rightStart < coordinator.sessions.endIndex else { return [] }
            return coordinator.sessions[rightStart...].map(\.id)
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

        return splitSessionsByPrimaryID.first(where: { $0.value.id == sessionID })?.key
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

        if let primarySessionID = splitSessionsByPrimaryID.first(where: { $0.value.id == sessionID })?.key {
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
        guard let primarySessionID else { return nil }
        return splitSessionsByPrimaryID[primarySessionID]
    }

    func splitLayout(for primarySessionID: UUID?) -> SplitPaneLayout? {
        guard let primarySessionID else { return nil }
        return splitLayoutsByPrimaryID[primarySessionID]
    }

    func splitFraction(for primarySessionID: UUID?) -> CGFloat? {
        guard let primarySessionID else { return nil }
        return splitFractionsByPrimaryID[primarySessionID]
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

        if let existing = splitSessionsByPrimaryID[primarySessionID] {
            var changed = false
            if splitLayoutsByPrimaryID[primarySessionID] != preferredLayout {
                splitLayoutsByPrimaryID[primarySessionID] = preferredLayout
                changed = true
            }
            if splitFractionsByPrimaryID[primarySessionID] == nil {
                splitFractionsByPrimaryID[primarySessionID] = Self.defaultSplitFraction
                changed = true
            }
            if changed {
                objectWillChange.send()
            }
            return existing
        }

        let splitSession = HostTerminalSession(
            key: primarySession.key,
            directory: primarySession.directoryURL
        )
        splitSessionsByPrimaryID[primarySessionID] = splitSession
        splitLayoutsByPrimaryID[primarySessionID] = preferredLayout
        splitFractionsByPrimaryID[primarySessionID] = Self.defaultSplitFraction
        syncRegistry()
        objectWillChange.send()
        return splitSession
    }

    @discardableResult
    func updateSplitFraction(_ fraction: CGFloat, forPrimarySessionID primarySessionID: UUID) -> Bool {
        guard splitSessionsByPrimaryID[primarySessionID] != nil else { return false }
        let clampedFraction = Self.clampedSplitFraction(fraction)
        guard splitFractionsByPrimaryID[primarySessionID] != clampedFraction else {
            return false
        }
        splitFractionsByPrimaryID[primarySessionID] = clampedFraction
        objectWillChange.send()
        return true
    }

    @discardableResult
    func equalizeSplit(containing sourceSessionID: UUID) -> Bool {
        guard let primarySessionID = primarySessionID(containing: sourceSessionID) else {
            return false
        }
        return updateSplitFraction(Self.defaultSplitFraction, forPrimarySessionID: primarySessionID)
    }

    @discardableResult
    func resizeSplit(
        containing sourceSessionID: UUID,
        direction: GhosttyAppManager.SplitResizeDirection,
        amount: Int
    ) -> Bool {
        guard let primarySessionID = primarySessionID(containing: sourceSessionID),
            let splitSession = splitSessionsByPrimaryID[primarySessionID]
        else {
            return false
        }

        let layout = splitLayoutsByPrimaryID[primarySessionID] ?? .defaultTrailing
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

        let currentFraction = splitFractionsByPrimaryID[primarySessionID] ?? Self.defaultSplitFraction
        return updateSplitFraction(currentFraction + delta, forPrimarySessionID: primarySessionID)
    }

    /// Computes the target session for split focus navigation in our current
    /// two-pane split model (primary + optional split with direction-aware layout).
    func splitFocusTarget(
        from sourceSessionID: UUID,
        direction: GhosttyAppManager.SplitFocusDirection
    ) -> UUID? {
        guard let primarySessionID = activatePrimarySession(containing: sourceSessionID),
            let splitSession = splitSessionsByPrimaryID[primarySessionID]
        else {
            return nil
        }

        let layout = splitLayoutsByPrimaryID[primarySessionID] ?? .defaultTrailing
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
        activeSessionID = coordinator.activeSessionID
        sessionPresentation = coordinator.presentation

        let validPrimaryIDs = Set(sessions.map(\.id))
        let stalePrimaryIDs = splitSessionsByPrimaryID.keys.filter { !validPrimaryIDs.contains($0) }
        for primaryID in stalePrimaryIDs {
            removeSplitState(forPrimarySessionID: primaryID)
        }

        syncRegistry()

        for session in sessions {
            recordTerminalSession(session, isActive: session.id == activeSessionID)
        }
        for splitSession in splitSessionsByPrimaryID.values {
            recordTerminalSession(splitSession, isActive: false)
        }
    }

    /// Mirror the coordinator's session list into the agent session registry so the
    /// hook listener has somewhere to land payloads. Idempotent — `register` and
    /// `deregister` are no-ops on already-registered / already-removed ids.
    private func syncRegistry() {
        guard let registry = agentSessionRegistry else { return }
        let allSessions = coordinator.sessions + Array(splitSessionsByPrimaryID.values)
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
            recordTerminalSession(session, isActive: session.id == activeSessionID)
        }

        // Deregister sessions that have left the coordinator.
        let removed = registeredAgentSessionIDs.subtracting(liveIDs)
        for sessionID in removed {
            registry.deregister(hostSessionID: sessionID)
            recordTerminalSessionEnded(sessionID)
        }
        registeredAgentSessionIDs.subtract(removed)
    }

    private func removeSplitState(forPrimarySessionID primarySessionID: UUID) {
        if let splitSession = splitSessionsByPrimaryID.removeValue(forKey: primarySessionID) {
            surfaceStore.invalidate(sessionID: splitSession.id)
            if registeredAgentSessionIDs.contains(splitSession.id) {
                agentSessionRegistry?.deregister(hostSessionID: splitSession.id)
                recordTerminalSessionEnded(splitSession.id)
                registeredAgentSessionIDs.remove(splitSession.id)
            }
        }
        splitLayoutsByPrimaryID.removeValue(forKey: primarySessionID)
        splitFractionsByPrimaryID.removeValue(forKey: primarySessionID)
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
