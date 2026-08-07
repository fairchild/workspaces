import Foundation
import WorkspaceManagerCore

@MainActor
final class AutomationController: AutomationControlling {
    private let handleRegistry: AutomationHandleRegistry
    private weak var tileTreeStore: TileTreeStore?
    private var focusTerminal: @MainActor (UUID) -> Void
    private var requestCloseTerminal: @MainActor (UUID) -> Void
    private let isInputWriteEnabled: @MainActor () -> Bool
    private var webSurfaces: @MainActor () -> [AutomationWebSurfaceDescriptor]
    private var webSnapshot: @MainActor (UUID) async -> WebSnapshotOutcome
    private var windows: @MainActor () -> [AutomationWindowDescriptor]
    private var windowSnapshot: @MainActor (String) async -> WindowSnapshotOutcome
    private var workspaceInventory: @MainActor () -> AutomationWorkspaceInventory
    private var surfaceTextReader: @MainActor (TileTreeStore, UUID) -> String?
    /// The gesture-verb layer — the single place workspace mutation verbs enter
    /// the real UI path. `nil` when no window is attached, which is exactly the `unsupported`
    /// condition: a mutation verb cannot run without a live window, and never falls back.
    private var gestureVerbs: AutomationGestureVerbs?

    init(
        handleRegistry: AutomationHandleRegistry,
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        webSurfaces: @escaping @MainActor () -> [AutomationWebSurfaceDescriptor] = { [] },
        webSnapshot: @escaping @MainActor (UUID) async -> WebSnapshotOutcome = { _ in .unknownSource },
        windows: @escaping @MainActor () -> [AutomationWindowDescriptor] = { [] },
        windowSnapshot: @escaping @MainActor (String) async -> WindowSnapshotOutcome = { _ in .unknownWindow },
        workspaceInventory: @escaping @MainActor () -> AutomationWorkspaceInventory = {
            AutomationWorkspaceInventory()
        },
        surfaceTextReader: @escaping @MainActor (TileTreeStore, UUID) -> String? = { store, surfaceID in
            store.surfaceStore.terminalPlainText(for: surfaceID)
        },
        gestureVerbs: AutomationGestureVerbs? = nil,
        isInputWriteEnabled: @escaping @MainActor () -> Bool = {
            ExperimentalFeatures.isEnabled(.automationInputWrite)
        }
    ) {
        self.handleRegistry = handleRegistry
        self.tileTreeStore = tileTreeStore
        self.focusTerminal = focusTerminal
        self.requestCloseTerminal = requestCloseTerminal
        self.webSurfaces = webSurfaces
        self.webSnapshot = webSnapshot
        self.windows = windows
        self.windowSnapshot = windowSnapshot
        self.workspaceInventory = workspaceInventory
        self.surfaceTextReader = surfaceTextReader
        self.gestureVerbs = gestureVerbs
        self.isInputWriteEnabled = isInputWriteEnabled
    }

    func update(
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        webSurfaces: (@MainActor () -> [AutomationWebSurfaceDescriptor])? = nil,
        webSnapshot: (@MainActor (UUID) async -> WebSnapshotOutcome)? = nil,
        windows: (@MainActor () -> [AutomationWindowDescriptor])? = nil,
        windowSnapshot: (@MainActor (String) async -> WindowSnapshotOutcome)? = nil,
        workspaceInventory: (@MainActor () -> AutomationWorkspaceInventory)? = nil,
        surfaceTextReader: (@MainActor (TileTreeStore, UUID) -> String?)? = nil,
        gestureVerbs: AutomationGestureVerbs? = nil
    ) {
        self.tileTreeStore = tileTreeStore
        self.focusTerminal = focusTerminal
        self.requestCloseTerminal = requestCloseTerminal
        self.gestureVerbs = gestureVerbs
        if let webSurfaces {
            self.webSurfaces = webSurfaces
        }
        if let webSnapshot {
            self.webSnapshot = webSnapshot
        }
        if let windows {
            self.windows = windows
        }
        if let windowSnapshot {
            self.windowSnapshot = windowSnapshot
        }
        if let workspaceInventory {
            self.workspaceInventory = workspaceInventory
        }
        if let surfaceTextReader {
            self.surfaceTextReader = surfaceTextReader
        }
    }

    /// Drops the gesture-verb layer when the window that installed it goes away. The app stays alive
    /// as an accessory after its last window closes, so without this an escaped `performSelection`
    /// closure would keep `workspace.select` "working" against a window that no longer exists. Clearing
    /// it here is what makes a post-teardown select correctly return `unsupported` (no live window)
    /// rather than driving a stale gesture. A window reappearing reinstalls it via `configure`.
    func detachGestureVerbs() {
        gestureVerbs = nil
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

    func automationWindows(for handle: String) throws -> AutomationWindowsResult {
        // Operator scope: capture-only listing of the app's windows. The caller need not own a
        // terminal tile, so this resolves the handle without the tile-liveness check — only the
        // window.read capability and operator-scope guard apply. A tile handle lacks window.read
        // and fails capability_denied.
        let entry = try resolveOperator(handle, requiring: .windowRead)
        return AutomationWindowsResult(
            windows: windows(),
            system: AutomationSystemDescriptor(capabilities: entry.capabilities)
        )
    }

    func automationWorkspaces(for handle: String) throws -> AutomationWorkspacesResult {
        // Operator scope, read-only: like the window list, the caller need not own a terminal tile,
        // so this resolves without the tile-liveness check — only the workspace.read capability and
        // operator-scope guard apply. A tile handle lacks workspace.read and fails capability_denied.
        let entry = try resolveOperator(handle, requiring: .workspaceRead)
        let inventory = workspaceInventory()
        return AutomationWorkspacesResult(
            repos: inventory.repos,
            workspaces: inventory.workspaces,
            system: AutomationSystemDescriptor(capabilities: entry.capabilities)
        )
    }

    func automationSelectWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceSelectResult {
        // Operator scope mutation: gated on workspace.select (distinct from the
        // read-only workspace.read), and — like the other operator routes — resolved without the
        // tile-liveness check. A tile handle lacks workspace.select and fails capability_denied.
        let entry = try resolveOperator(handle, requiring: .workspaceSelect)
        guard let uuid = UUID(uuidString: workspaceID) else {
            throw AutomationServiceError(.invalidRequest, "workspaceID must be a UUID.")
        }
        // No gesture layer means no live window is bound to the API. That is precisely the
        // `unsupported` case: the verb cannot run without a window, and never falls back to a
        // data-layer write.
        guard let gestureVerbs else {
            throw AutomationServiceError(
                .unsupported,
                "No WorkSpaces window is attached; workspace.select requires a live window."
            )
        }
        let capabilities = entry.capabilities
        switch gestureVerbs.selectWorkspace(uuid) {
        case .completed(let effect):
            return AutomationWorkspaceSelectResult(
                workspaceID: workspaceID,
                outcome: .completed,
                changed: true,
                selectedWorkspaceID: effect.selectedWorkspaceID,
                attachedTerminal: effect.attachedTerminal,
                attachedSurfaceID: effect.attachedSurfaceID?.uuidString,
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        case .confirmationRequired(let message):
            return AutomationWorkspaceSelectResult(
                workspaceID: workspaceID,
                outcome: .confirmationRequired,
                changed: false,
                message: message,
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        case .unsupported(let message):
            throw AutomationServiceError(.unsupported, message)
        case .notFound:
            throw AutomationServiceError(
                .invalidRequest, "No workspace with id \(workspaceID) is tracked by the app.")
        }
    }

    func automationCreateWorkspace(
        for handle: String,
        request: AutomationWorkspaceCreateRequest
    ) async throws -> AutomationWorkspaceCreateResult {
        let entry = try resolveOperator(handle, requiring: .workspaceCreate)
        let repoIDText = request.repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repoID = UUID(uuidString: repoIDText) else {
            throw AutomationServiceError(.invalidRequest, "repoID must be a UUID.")
        }
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Workspace name must be non-empty.")
        }
        let providerID =
            request.providerID?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? LocalWorkspaceProvider.identifier
        guard !providerID.isEmpty else {
            throw AutomationServiceError(.invalidRequest, "providerID must be non-empty when provided.")
        }
        let fromRef: String?
        switch WorkspaceCreationRefValidator.normalize(request.fromRef) {
        case .success(let normalized):
            fromRef = normalized
        case .failure(let error):
            throw AutomationServiceError(.invalidRequest, error.message)
        }

        guard let gestureVerbs else {
            throw AutomationServiceError(
                .unsupported,
                "No WorkSpaces window is attached; workspace.create requires a live window."
            )
        }

        let command = AutomationWorkspaceCreateCommand(
            repoID: repoID,
            name: name,
            providerID: providerID,
            guestOS: request.guestOS,
            shouldSelect: request.select ?? true,
            fromRef: fromRef
        )
        let capabilities = entry.capabilities
        switch await gestureVerbs.createWorkspace(command) {
        case .completed(let effect):
            if effect.attachedTerminal, let attachedSurfaceID = effect.attachedSurfaceID {
                handleRegistry.recordWorkspaceCreation(
                    operatorHandle: entry.handle,
                    hostSessionID: attachedSurfaceID
                )
            }
            return AutomationWorkspaceCreateResult(
                repoID: repoIDText,
                workspaceID: effect.workspaceID,
                workspaceName: effect.workspaceName,
                workspacePath: effect.workspacePath,
                outcome: .completed,
                changed: true,
                selectedWorkspaceID: effect.selectedWorkspaceID,
                attachedTerminal: effect.attachedTerminal,
                attachedSurfaceID: effect.attachedSurfaceID?.uuidString,
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        case .confirmationRequired(let confirmation):
            return AutomationWorkspaceCreateResult(
                repoID: repoIDText,
                workspaceName: name,
                outcome: .confirmationRequired,
                changed: false,
                confirmation: confirmation,
                message: confirmation.message,
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        case .unsupported(let message):
            throw AutomationServiceError(.unsupported, message)
        case .notFound:
            throw AutomationServiceError(
                .invalidRequest, "No repo with id \(repoIDText) is tracked by the app.")
        case .invalidRequest(let message):
            throw AutomationServiceError(.invalidRequest, message)
        }
    }

    func automationArchiveWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceArchiveResult {
        let entry = try resolveOperator(handle, requiring: .workspaceArchive)
        guard let uuid = UUID(uuidString: workspaceID) else {
            throw AutomationServiceError(.invalidRequest, "workspaceID must be a UUID.")
        }

        guard let gestureVerbs else {
            throw AutomationServiceError(
                .unsupported,
                "No WorkSpaces window is attached; workspace.archive requires a live window."
            )
        }

        let capabilities = entry.capabilities
        switch await gestureVerbs.archiveWorkspace(uuid) {
        case .completed(let effect):
            return AutomationWorkspaceArchiveResult(
                workspaceID: workspaceID,
                outcome: .completed,
                changed: true,
                archivedWorkspaceID: effect.workspaceID,
                selectedWorkspaceID: effect.selectedWorkspaceID,
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        case .confirmationRequired(let confirmation):
            return AutomationWorkspaceArchiveResult(
                workspaceID: workspaceID,
                outcome: .confirmationRequired,
                changed: false,
                confirmation: confirmation,
                message: confirmation.message,
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        case .unsupported(let message):
            throw AutomationServiceError(.unsupported, message)
        case .notFound:
            throw AutomationServiceError(
                .invalidRequest, "No workspace with id \(workspaceID) is tracked by the app.")
        }
    }

    func automationWindowSnapshot(
        for handle: String,
        windowID: String
    ) async throws -> AutomationWindowSnapshotResult {
        // Operator scope, capture-only: like the window list, this resolves without the tile-liveness
        // check — the caller need not own a terminal tile. window.snapshot is gated here; a tile
        // handle lacks it and fails capability_denied before any capture runs.
        let entry = try resolveOperator(handle, requiring: .windowSnapshot)
        let outcome = await windowSnapshot(windowID)
        return try WindowSnapshotEncoder.result(
            from: outcome,
            windowID: windowID,
            capabilities: entry.capabilities
        )
    }

    func automationReadSurface(
        for handle: String,
        request: AutomationSurfaceReadRequest
    ) throws -> AutomationSurfaceReadResult {
        let entry = try resolveOperator(handle, requiring: .surfaceRead)
        guard let surfaceID = UUID(uuidString: request.surfaceID) else {
            throw AutomationServiceError(.invalidRequest, "surfaceID must be a UUID.")
        }
        guard handleRegistry.operatorHandle(entry.handle, createdHostSessionID: surfaceID) else {
            throw AutomationServiceError(
                .capabilityDenied,
                "This operator handle did not create the requested terminal surface this launch."
            )
        }
        guard let tileTreeStore else {
            throw AutomationServiceError(
                .unsupported, "No WorkSpaces window is currently attached to the Automation API.")
        }
        guard tileTreeStore.primarySessionID(containing: surfaceID) != nil else {
            throw AutomationServiceError(.staleHandle, "The requested terminal surface is no longer live.")
        }
        guard let fullText = surfaceTextReader(tileTreeStore, surfaceID) else {
            throw AutomationServiceError(.staleHandle, "The requested terminal surface is not ready to read.")
        }

        let lineLimit = min(request.lines, AutomationAPI.surfaceReadMaxLines)
        let bounded = Self.boundedSurfaceReadText(
            fullText,
            maxLines: lineLimit,
            maxUTF8Bytes: AutomationAPI.surfaceReadMaxUTF8Bytes
        )
        return AutomationSurfaceReadResult(
            surfaceID: surfaceID.uuidString,
            requestedLines: request.lines,
            lines: lineLimit,
            returnedLines: Self.lineCount(in: bounded),
            byteCount: bounded.utf8.count,
            text: bounded,
            system: AutomationSystemDescriptor(capabilities: entry.capabilities)
        )
    }

    func automationHandleIsOperator(_ handle: String) -> Bool {
        handleRegistry.resolve(handle)?.isOperator ?? false
    }

    func automationWebSurfaces(for handle: String) throws -> AutomationWebSurfacesResult {
        // The caller is a terminal tile (resolve enforces that); browser.read lets it
        // read the app's web surfaces, which are separate entities addressed by stable
        // WebSource id, never the caller's own tile.
        let resolved = try resolve(handle, requiring: .browserRead)
        return AutomationWebSurfacesResult(
            webSurfaces: webSurfaces(),
            system: AutomationSystemDescriptor(capabilities: resolved.entry.capabilities)
        )
    }

    func automationWebSurfaceSnapshot(
        for handle: String,
        sourceID: UUID
    ) async throws -> AutomationWebSurfaceSnapshotResult {
        // Same trust level as the web-surface list: read-only pixels of an already-visible
        // surface, gated on browser.read. The caller is a terminal tile; the snapshot targets
        // an app-owned web surface addressed by stable WebSource id, never the caller's tile.
        let resolved = try resolve(handle, requiring: .browserRead)
        let outcome = await webSnapshot(sourceID)
        return try WebSurfaceSnapshotEncoder.result(
            from: outcome,
            sourceID: sourceID,
            capabilities: resolved.entry.capabilities
        )
    }

    func automationFocusTile(
        for handle: String,
        direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult {
        let resolved = try resolve(handle, requiring: .tileFocus)
        let focusDirection = GhosttyAppManager.SplitFocusDirection(automationDirection: direction)
        guard
            let targetSessionID = resolved.tileTreeStore.splitFocusTarget(
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
            let primarySessionID = resolved.tileTreeStore.activatePrimarySession(
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

        let layout = TileTreeStore.SplitPaneLayout(automationDirection: direction)
        guard
            let splitSession = resolved.tileTreeStore.splitFocusedTile(
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
        // Close is fire-and-forget into the app's close-confirmation path — Ghostty may still
        // prompt — so the result reports the request as `requested` without claiming the tile
        // closed. `closedSurfaceID` names the surface the request targeted.
        return AutomationMutationResult(
            changed: false,
            outcome: .requested,
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
            let terminal = resolved.tileTreeStore.surfaceStore.terminal(
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
        let tileTreeStore: TileTreeStore
    }

    /// Resolves an operator handle for a capture-only route. Unlike `resolve`, it does not require a
    /// live terminal tile — operator scope exists outside any tile. It still fails closed: a
    /// missing/stale handle is `stale_handle`, an under-capable handle is `capability_denied`, and a
    /// tile handle that somehow reaches here (it lacks the operator capabilities by construction) is
    /// `capability_denied` on the operator-scope guard.
    private func resolveOperator(
        _ handle: String,
        requiring capability: AutomationCapability
    ) throws -> AutomationHandleRegistry.Entry {
        guard let entry = handleRegistry.resolve(handle) else {
            throw AutomationServiceError(.staleHandle, "The automation handle is missing or stale.")
        }
        guard entry.capabilities.contains(capability) else {
            throw AutomationServiceError(
                .capabilityDenied,
                "The automation handle does not include \(capability.rawValue)."
            )
        }
        guard entry.isOperator else {
            throw AutomationServiceError(
                .capabilityDenied,
                "This route requires an operator handle."
            )
        }
        return entry
    }

    private func resolve(
        _ handle: String,
        requiring capability: AutomationCapability
    ) throws -> ResolvedHandle {
        guard let tileTreeStore else {
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
        guard tileTreeStore.primarySessionID(containing: entry.hostSessionID) != nil else {
            handleRegistry.remove(hostSessionID: entry.hostSessionID)
            throw AutomationServiceError(.staleHandle, "The automation handle no longer maps to a live terminal tile.")
        }
        return ResolvedHandle(entry: entry, tileTreeStore: tileTreeStore)
    }

    private func context(
        for resolved: ResolvedHandle
    ) throws -> AutomationContextResult {
        let surface = try surfaceDescriptor(
            hostSessionID: resolved.entry.hostSessionID,
            callerHostSessionID: resolved.entry.hostSessionID,
            tileTreeStore: resolved.tileTreeStore,
            capabilities: resolved.entry.capabilities
        )
        let primaryID = resolved.tileTreeStore.primarySessionID(containing: resolved.entry.hostSessionID)
        let primarySession = primaryID.flatMap { id in
            resolved.tileTreeStore.sessions.first { $0.id == id }
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
            let primaryID = resolved.tileTreeStore.primarySessionID(containing: resolved.entry.hostSessionID),
            let primarySession = resolved.tileTreeStore.sessions.first(where: { $0.id == primaryID })
        else {
            return []
        }

        var sessions = resolved.tileTreeStore.sessions(inScope: primarySession.key)
        sessions.append(contentsOf: resolved.tileTreeStore.splitSessions(forPrimarySessionID: primaryID))

        return sessions.compactMap { session in
            try? surfaceDescriptor(
                hostSessionID: session.id,
                callerHostSessionID: resolved.entry.hostSessionID,
                tileTreeStore: resolved.tileTreeStore,
                capabilities: resolved.entry.capabilities
            )
        }
    }

    private func surfaceDescriptor(
        hostSessionID: UUID,
        callerHostSessionID: UUID,
        tileTreeStore: TileTreeStore,
        capabilities: [AutomationCapability]
    ) throws -> AutomationSurfaceDescriptor {
        let session: HostTerminalSession?
        if let primaryID = tileTreeStore.primarySessionID(containing: hostSessionID),
            primaryID == hostSessionID
        {
            session = tileTreeStore.sessions.first { $0.id == hostSessionID }
        } else if let primaryID = tileTreeStore.primarySessionID(containing: hostSessionID),
            let split = tileTreeStore.splitSessions(forPrimarySessionID: primaryID).first(where: {
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

        let tileID = tileTreeStore.automationTileIDString(for: session.id)
        let primaryID = tileTreeStore.primarySessionID(containing: session.id)
        let isVisible = primaryID == tileTreeStore.activeSessionID
        return AutomationSurfaceDescriptor(
            surfaceID: session.id.uuidString,
            tileID: tileID,
            kind: .terminal,
            hostSessionID: session.id,
            title: tileTreeStore.tabTitleOverride(for: session.id)
                ?? tileTreeStore.surfaceStore.displayTitle(for: session),
            cwd: session.directoryPath,
            isCaller: session.id == callerHostSessionID,
            isActive: session.id == tileTreeStore.activeSessionID,
            isVisible: isVisible,
            capabilities: capabilities
        )
    }

    private static func boundedSurfaceReadText(
        _ text: String,
        maxLines: Int,
        maxUTF8Bytes: Int
    ) -> String {
        guard maxLines > 0, maxUTF8Bytes > 0, !text.isEmpty else { return "" }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline {
            lines.removeLast()
        }

        var selected = Array(lines.suffix(maxLines))
        while !selected.isEmpty {
            let candidate = selected.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
            if candidate.utf8.count <= maxUTF8Bytes {
                return candidate
            }
            if selected.count == 1 {
                return utf8SafeSuffix(candidate, maxBytes: maxUTF8Bytes)
            }
            selected.removeFirst()
        }
        return ""
    }

    private static func utf8SafeSuffix(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let suffix = text.utf8.suffix(maxBytes)
        guard var start = suffix.indices.first else { return "" }
        while start < suffix.endIndex, (suffix[start] & 0b1100_0000) == 0b1000_0000 {
            start = suffix.index(after: start)
        }
        return String(decoding: suffix[start..<suffix.endIndex], as: UTF8.self)
    }

    private static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        if text.hasSuffix("\n") {
            lines -= 1
        }
        return max(lines, 0)
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

extension TileTreeStore.SplitPaneLayout {
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
