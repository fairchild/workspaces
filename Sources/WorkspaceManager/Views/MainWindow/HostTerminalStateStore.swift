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
    @Published private(set) var sessionPresentation = HostTerminalSessionPresentation()

    let surfaceStore = HostTerminalSurfaceStore()
    private var coordinator = HostTerminalSessionCoordinator()

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
    }

    private func removeSplitState(forPrimarySessionID primarySessionID: UUID) {
        if let splitSession = splitSessionsByPrimaryID.removeValue(forKey: primarySessionID) {
            surfaceStore.invalidate(sessionID: splitSession.id)
        }
        splitLayoutsByPrimaryID.removeValue(forKey: primarySessionID)
        splitFractionsByPrimaryID.removeValue(forKey: primarySessionID)
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
