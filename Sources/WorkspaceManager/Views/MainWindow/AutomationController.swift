import Foundation
import WorkspaceManagerCore

@MainActor
final class AutomationController: AutomationControlling {
    private let handleRegistry: AutomationHandleRegistry
    private weak var hostTerminalState: HostTerminalStateStore?
    private var focusTerminal: @MainActor (UUID) -> Void
    private var requestCloseTerminal: @MainActor (UUID) -> Void
    private let isInputWriteEnabled: @MainActor () -> Bool

    init(
        handleRegistry: AutomationHandleRegistry,
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        isInputWriteEnabled: @escaping @MainActor () -> Bool = {
            ExperimentalFeatures.isEnabled(.automationInputWrite)
        }
    ) {
        self.handleRegistry = handleRegistry
        self.hostTerminalState = hostTerminalState
        self.focusTerminal = focusTerminal
        self.requestCloseTerminal = requestCloseTerminal
        self.isInputWriteEnabled = isInputWriteEnabled
    }

    func update(
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void
    ) {
        self.hostTerminalState = hostTerminalState
        self.focusTerminal = focusTerminal
        self.requestCloseTerminal = requestCloseTerminal
    }

    func automationContext(for handle: String) throws -> AutomationContextResult {
        let resolved = try resolve(handle, requiring: .contextRead)
        return try context(for: resolved)
    }

    func automationSurfaces(for handle: String) throws -> AutomationSurfacesResult {
        let resolved = try resolve(handle, requiring: .surfacesRead)
        return AutomationSurfacesResult(
            surfaces: surfaceDescriptors(for: resolved),
            system: AutomationSystemDescriptor(capabilities: resolved.entry.capabilities)
        )
    }

    func automationFocusTile(
        for handle: String,
        direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult {
        let resolved = try resolve(handle, requiring: .tileFocus)
        let focusDirection = GhosttyAppManager.SplitFocusDirection(automationDirection: direction)
        guard
            let targetSessionID = resolved.hostTerminalState.splitFocusTarget(
                from: resolved.entry.hostSessionID,
                direction: focusDirection
            )
        else {
            return AutomationMutationResult(changed: false, reason: "no_neighbor")
        }

        focusTerminal(targetSessionID)
        return AutomationMutationResult(
            changed: true,
            focusedSurfaceID: targetSessionID.uuidString
        )
    }

    func automationSplitTile(
        for handle: String,
        direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult {
        let resolved = try resolve(handle, requiring: .tileSplit)
        guard
            let primarySessionID = resolved.hostTerminalState.activatePrimarySession(
                containing: resolved.entry.hostSessionID
            )
        else {
            throw AutomationServiceError(.staleHandle, "The automation handle no longer maps to a live terminal tile.")
        }
        guard primarySessionID == resolved.entry.hostSessionID else {
            throw AutomationServiceError(
                .unsupported,
                "Splitting from a secondary split tile is not supported by Automation API V1."
            )
        }

        let layout = HostTerminalStateStore.SplitPaneLayout(automationDirection: direction)
        guard
            let splitSession = resolved.hostTerminalState.splitFocusedTile(
                inTabContaining: primarySessionID,
                preferredLayout: layout
            )
        else {
            throw AutomationServiceError(.unsupported, "No active terminal tile is available to split.")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + GhosttyTerminalIntentRouter.splitFocusDelay) {
            self.focusTerminal(splitSession.id)
        }
        return AutomationMutationResult(
            changed: true,
            focusedSurfaceID: splitSession.id.uuidString,
            createdSurfaceID: splitSession.id.uuidString
        )
    }

    func automationCloseTile(for handle: String) throws -> AutomationMutationResult {
        let resolved = try resolve(handle, requiring: .tileClose)
        requestCloseTerminal(resolved.entry.hostSessionID)
        return AutomationMutationResult(
            changed: true,
            closedSurfaceID: resolved.entry.hostSessionID.uuidString
        )
    }

    func automationWriteInput(
        for handle: String,
        text: String,
        submit: Bool
    ) throws -> AutomationInputWriteResult {
        let resolved = try resolve(handle, requiring: .inputWrite)
        // Handles outlive settings changes, so the grant-time gate is re-checked per request.
        guard isInputWriteEnabled() else {
            throw AutomationServiceError(
                .capabilityDenied,
                "The Automation Input Write experiment is disabled."
            )
        }
        guard
            let terminal = resolved.hostTerminalState.surfaceStore.terminal(
                for: resolved.entry.hostSessionID
            )
        else {
            throw AutomationServiceError(
                .staleHandle,
                "The automation handle no longer maps to a live terminal surface."
            )
        }
        guard GhosttySurfaceTextInputBridge.writeAutomationText(into: terminal, text: text) else {
            throw AutomationServiceError(.staleHandle, "The terminal surface is not ready to receive input.")
        }
        // Submit goes through the key-event path, not an appended "\r": the text path is a paste,
        // and bracketed paste turns an embedded CR into a literal newline instead of accept-line.
        if submit, !GhosttySurfaceTextInputBridge.sendAutomationReturn(into: terminal) {
            throw AutomationServiceError(.staleHandle, "The terminal surface dropped before the submit key.")
        }
        return AutomationInputWriteResult(
            accepted: true,
            byteCount: text.utf8.count,
            surfaceID: resolved.entry.hostSessionID.uuidString,
            system: AutomationSystemDescriptor(capabilities: resolved.entry.capabilities)
        )
    }

    private struct ResolvedHandle {
        let entry: AutomationHandleRegistry.Entry
        let hostTerminalState: HostTerminalStateStore
    }

    private func resolve(
        _ handle: String,
        requiring capability: AutomationCapability
    ) throws -> ResolvedHandle {
        guard let hostTerminalState else {
            throw AutomationServiceError(
                .unsupported, "No WorkSpaces window is currently attached to the Automation API.")
        }
        guard let entry = handleRegistry.resolve(handle) else {
            throw AutomationServiceError(.staleHandle, "The automation handle is missing or stale.")
        }
        guard entry.capabilities.contains(capability) else {
            throw AutomationServiceError(
                .capabilityDenied,
                "The automation handle does not include \(capability.rawValue)."
            )
        }
        // Before the terminal-session liveness check: a web entry's host-session id can never
        // resolve to a terminal tab, so checking liveness first would misreport `.staleHandle`.
        guard entry.surfaceKind == .terminal else {
            throw AutomationServiceError(
                .unsupported,
                "Automation v1 drives terminal tiles only; this handle targets a \(entry.surfaceKind.rawValue) surface."
            )
        }
        guard hostTerminalState.primarySessionID(containing: entry.hostSessionID) != nil else {
            handleRegistry.remove(hostSessionID: entry.hostSessionID)
            throw AutomationServiceError(.staleHandle, "The automation handle no longer maps to a live terminal tile.")
        }
        return ResolvedHandle(entry: entry, hostTerminalState: hostTerminalState)
    }

    private func context(
        for resolved: ResolvedHandle
    ) throws -> AutomationContextResult {
        let surface = try surfaceDescriptor(
            hostSessionID: resolved.entry.hostSessionID,
            callerHostSessionID: resolved.entry.hostSessionID,
            hostTerminalState: resolved.hostTerminalState,
            capabilities: resolved.entry.capabilities
        )
        let primaryID = resolved.hostTerminalState.primarySessionID(containing: resolved.entry.hostSessionID)
        let primarySession = primaryID.flatMap { id in
            resolved.hostTerminalState.sessions.first { $0.id == id }
        }
        let scope = AutomationScopeDescriptor(
            app: resolved.entry.appScopeID,
            window: resolved.entry.windowScopeID,
            scopeKey: primarySession?.key.debugDescription,
            primaryHostSessionID: primaryID
        )
        return AutomationContextResult(
            surface: surface,
            scope: scope,
            system: AutomationSystemDescriptor(capabilities: resolved.entry.capabilities)
        )
    }

    private func surfaceDescriptors(for resolved: ResolvedHandle) -> [AutomationSurfaceDescriptor] {
        guard
            let primaryID = resolved.hostTerminalState.primarySessionID(containing: resolved.entry.hostSessionID),
            let primarySession = resolved.hostTerminalState.sessions.first(where: { $0.id == primaryID })
        else {
            return []
        }

        var sessions = resolved.hostTerminalState.sessions(inScope: primarySession.key)
        sessions.append(contentsOf: resolved.hostTerminalState.splitSessions(forPrimarySessionID: primaryID))

        return sessions.compactMap { session in
            try? surfaceDescriptor(
                hostSessionID: session.id,
                callerHostSessionID: resolved.entry.hostSessionID,
                hostTerminalState: resolved.hostTerminalState,
                capabilities: resolved.entry.capabilities
            )
        }
    }

    private func surfaceDescriptor(
        hostSessionID: UUID,
        callerHostSessionID: UUID,
        hostTerminalState: HostTerminalStateStore,
        capabilities: [AutomationCapability]
    ) throws -> AutomationSurfaceDescriptor {
        let session: HostTerminalSession?
        if let primaryID = hostTerminalState.primarySessionID(containing: hostSessionID),
            primaryID == hostSessionID
        {
            session = hostTerminalState.sessions.first { $0.id == hostSessionID }
        } else if let primaryID = hostTerminalState.primarySessionID(containing: hostSessionID),
            let split = hostTerminalState.splitSessions(forPrimarySessionID: primaryID).first(where: {
                $0.id == hostSessionID
            })
        {
            session = split
        } else {
            session = nil
        }

        guard let session else {
            throw AutomationServiceError(.staleHandle, "The terminal surface no longer exists.")
        }

        let tileID = hostTerminalState.automationTileIDString(for: session.id)
        let primaryID = hostTerminalState.primarySessionID(containing: session.id)
        let isVisible = primaryID == hostTerminalState.activeSessionID
        return AutomationSurfaceDescriptor(
            surfaceID: session.id.uuidString,
            tileID: tileID,
            kind: .terminal,
            hostSessionID: session.id,
            title: hostTerminalState.tabTitleOverride(for: session.id)
                ?? hostTerminalState.surfaceStore.displayTitle(for: session),
            cwd: session.directoryPath,
            isCaller: session.id == callerHostSessionID,
            isActive: session.id == hostTerminalState.activeSessionID,
            isVisible: isVisible,
            capabilities: capabilities
        )
    }
}

extension GhosttyAppManager.SplitFocusDirection {
    fileprivate init(automationDirection: AutomationTileFocusDirection) {
        switch automationDirection {
        case .left:
            self = .left
        case .right:
            self = .right
        case .up:
            self = .up
        case .down:
            self = .down
        case .next:
            self = .next
        case .previous:
            self = .previous
        }
    }
}

extension HostTerminalStateStore.SplitPaneLayout {
    fileprivate init(automationDirection: AutomationTileSplitDirection) {
        switch automationDirection {
        case .left:
            self.init(axis: .leadingTrailing, splitBeforePrimary: true)
        case .right:
            self = .defaultTrailing
        case .up:
            self.init(axis: .topBottom, splitBeforePrimary: true)
        case .down:
            self.init(axis: .topBottom, splitBeforePrimary: false)
        }
    }
}
