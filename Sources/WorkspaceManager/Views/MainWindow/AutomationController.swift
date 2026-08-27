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
    /// The structural UI-state read (`ui.read`). `nil` when no window has installed it,
    /// which is the `unsupported` condition — like the gesture layer, the read never
    /// fabricates chrome state without a live window behind it.
    private var uiState: (@MainActor () -> AutomationUIStateCapture)?
    /// Per-surface prompt-readiness read for the `prompt_ready` wait condition. `nil` from the
    /// reader means the surface has no realized terminal view yet — reported as pending, never
    /// as "not ready", so absence of the signal is not mistaken for a negative signal.
    private let promptReadinessReader: @MainActor (TileTreeStore, UUID) -> Bool?
    /// The app-level focus read behind `GET /v1/focus`. Injectable so tests assert the route's
    /// projection without AppKit window state; production defaults to the live enumerator.
    private let focusStateProvider: @MainActor (TileTreeStore?) -> AutomationFocusState
    /// Time seam for `POST /v1/wait`, injectable so wait outcomes are tested with virtual time.
    private let waitTimeSource: AutomationWaitTimeSource
    /// Poll intervals for `POST /v1/wait`, split by what a tick costs: topology and selection
    /// ticks are a couple of lookups, content ticks are a terminal read plus a regex run.
    private let waitPollIntervalMS: Int
    private let waitContentPollIntervalMS: Int
    /// The gesture-verb layer — the single place workspace mutation verbs enter
    /// the real UI path. `nil` when no window is attached, which is exactly the `unsupported`
    /// condition: a mutation verb cannot run without a live window, and never falls back.
    private var gestureVerbs: AutomationGestureVerbs?
    /// Which window installed the window-bound layer above. Held so a teardown can be checked
    /// against it: windows are not exclusive and their lifecycles overlap, so "some window went
    /// away" is not the same question as "the window offering these verbs went away" (#1375).
    private var windowBoundOwner: UUID?

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
        windowBoundOwner: UUID? = nil,
        isInputWriteEnabled: @escaping @MainActor () -> Bool = {
            ExperimentalFeatures.isEnabled(.automationInputWrite)
        },
        uiState: (@MainActor () -> AutomationUIStateCapture)? = nil,
        promptReadinessReader: @escaping @MainActor (TileTreeStore, UUID) -> Bool? = { store, surfaceID in
            store.surfaceStore.terminal(for: surfaceID)?.hasObservedPromptReadySignal
        },
        focusStateProvider: @escaping @MainActor (TileTreeStore?) -> AutomationFocusState = { store in
            AutomationFocusEnumerator.state(tileTreeStore: store)
        },
        waitTimeSource: AutomationWaitTimeSource = .continuous(),
        waitPollIntervalMS: Int = AutomationAPI.waitPollIntervalMS,
        waitContentPollIntervalMS: Int = AutomationAPI.waitContentPollIntervalMS
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
        self.windowBoundOwner = windowBoundOwner
        self.isInputWriteEnabled = isInputWriteEnabled
        self.uiState = uiState
        self.promptReadinessReader = promptReadinessReader
        self.focusStateProvider = focusStateProvider
        self.waitTimeSource = waitTimeSource
        self.waitPollIntervalMS = waitPollIntervalMS
        self.waitContentPollIntervalMS = waitContentPollIntervalMS
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
        gestureVerbs: AutomationGestureVerbs? = nil,
        windowBoundOwner: UUID? = nil,
        uiState: (@MainActor () -> AutomationUIStateCapture)? = nil
    ) {
        self.tileTreeStore = tileTreeStore
        self.focusTerminal = focusTerminal
        self.requestCloseTerminal = requestCloseTerminal
        // Window-bound like `gestureVerbs`, and installed the same way: the window offering
        // them becomes the owner, so a later teardown can tell whether it is the one that
        // installed these. The remaining members below are app-scoped and keep their last
        // value when omitted.
        self.gestureVerbs = gestureVerbs
        self.windowBoundOwner = windowBoundOwner
        self.uiState = uiState
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
    ///
    /// `owner` is what keeps that from cutting a *live* window off. Window lifecycles overlap: a
    /// second window installs its own layer while the first is still up, and a replaced window's
    /// `onDisappear` lands after its successor's `configure`. Clearing unconditionally left the app
    /// with no verbs while a window was open and focused — every mutation verb answering
    /// `unsupported` until the app was restarted (#1375). A teardown from a window that no longer
    /// owns the layer is now a no-op.
    func detachGestureVerbs(owner: UUID) {
        guard windowBoundOwner == owner else { return }
        gestureVerbs = nil
        // The ui-state read is window-bound the same way: with no window there is no
        // rendered chrome to report, so a post-teardown read fails `unsupported` rather
        // than describing a window that no longer exists.
        uiState = nil
        windowBoundOwner = nil
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

    /// `workspace.note` — an operator mutation, gated on its own capability so a caller
    /// granted read cannot write the line the sidebar shows.
    func automationSetWorkspaceNote(
        for handle: String,
        request: AutomationWorkspaceNoteRequest
    ) async throws -> AutomationWorkspaceNoteResult {
        let entry = try resolveOperator(handle, requiring: .workspaceNote)
        guard let uuid = UUID(uuidString: request.workspaceID) else {
            throw AutomationServiceError(.invalidRequest, "workspaceID must be a UUID.")
        }
        guard let gestureVerbs else {
            throw AutomationServiceError(
                .unsupported,
                "No WorkSpaces window is attached; workspace.note requires a live window."
            )
        }
        switch gestureVerbs.setWorkspaceNote(uuid, note: request.note) {
        case .completed(let note, let changed, let workspaceName):
            return AutomationWorkspaceNoteResult(
                workspaceID: request.workspaceID,
                workspaceName: workspaceName,
                note: note,
                changed: changed,
                system: AutomationSystemDescriptor(capabilities: entry.capabilities)
            )
        case .unsupported(let message):
            throw AutomationServiceError(.unsupported, message)
        case .notFound:
            throw AutomationServiceError(
                .invalidRequest, "No workspace with id \(request.workspaceID) is tracked by the app.")
        }
    }

    /// `repo.terminal`: open a repo's own terminal, the surface a sidebar repo row opens. It was
    /// reachable by click but by no verb, so an agent that wanted a shell scoped to a repo had to
    /// create a workspace it did not want (#1375).
    func automationOpenRepoTerminal(
        for handle: String,
        request: AutomationRepoTerminalRequest
    ) async throws -> AutomationRepoTerminalResult {
        let entry = try resolveOperator(handle, requiring: .repoTerminal)
        let repoIDText = request.repoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let repoID = UUID(uuidString: repoIDText) else {
            throw AutomationServiceError(.invalidRequest, "repoID must be a UUID.")
        }
        guard let gestureVerbs else {
            throw AutomationServiceError(
                .unsupported,
                "No WorkSpaces window is attached; repo.terminal requires a live window."
            )
        }
        switch gestureVerbs.openRepoTerminal(repoID) {
        case .completed(let effect, let repoName):
            return AutomationRepoTerminalResult(
                outcome: .completed,
                repoID: repoID,
                repoName: repoName,
                attachedSurfaceID: effect.attachedSurfaceID,
                attachedTerminal: effect.attachedTerminal,
                directoryPath: effect.directoryPath,
                system: AutomationSystemDescriptor(capabilities: entry.capabilities)
            )
        case .unsupported(let message):
            throw AutomationServiceError(.unsupported, message)
        case .notFound:
            throw AutomationServiceError(
                .invalidRequest, "No repo with id \(repoIDText) is tracked by the app.")
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
        request: AutomationWorkspaceArchiveRequest
    ) async throws -> AutomationWorkspaceArchiveResult {
        let entry = try resolveOperator(handle, requiring: .workspaceArchive)
        let workspaceID = request.workspaceID
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
        let command = AutomationWorkspaceArchiveCommand(
            workspaceID: uuid,
            teardownTerminals: request.teardownTerminals ?? false
        )
        switch await gestureVerbs.archiveWorkspace(command) {
        case .completed(let effect):
            return AutomationWorkspaceArchiveResult(
                workspaceID: workspaceID,
                outcome: .completed,
                changed: true,
                archivedWorkspaceID: effect.workspaceID,
                selectedWorkspaceID: effect.selectedWorkspaceID,
                teardown: effect.teardown,
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
        case .terminalActive(let message):
            throw AutomationServiceError(.terminalActive, message, retryable: true)
        case .closeBlockedByConfirmation(let message):
            throw AutomationServiceError(.closeBlockedByConfirmation, message, retryable: false)
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
        // Any live terminal surface is readable by an operator handle: the read is read-only,
        // operator scope is opt-in per launch, and every call is audited with the surface id.
        // The creation-attribution registry serves audit lineage, not access control.
        let entry = try resolveOperator(handle, requiring: .surfaceRead)
        guard let surfaceID = UUID(uuidString: request.surfaceID) else {
            throw AutomationServiceError(.invalidRequest, "surfaceID must be a UUID.")
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

    func automationUIState(for handle: String) throws -> AutomationUIStateResult {
        // Operator scope, read-only: like the other operator reads, resolved without the
        // tile-liveness check. A tile handle lacks ui.read and fails capability_denied.
        let entry = try resolveOperator(handle, requiring: .uiRead)
        guard let uiState else {
            throw AutomationServiceError(
                .unsupported,
                "No WorkSpaces window is attached; ui.read requires a live window."
            )
        }
        let capture = uiState()
        return AutomationUIStateResult(
            state: capture.state,
            volatile: capture.volatile,
            system: AutomationSystemDescriptor(capabilities: entry.capabilities)
        )
    }

    func automationWait(
        for handle: String,
        plan: AutomationWaitPlan
    ) async throws -> AutomationWaitResult {
        // Operator scope. Read conditions gate on the capability whose data they observe:
        // topology/selection conditions on workspace.read, terminal-content conditions
        // (text match, prompt readiness) on surface.read.
        let capability: AutomationCapability
        let pollIntervalMS: Int
        switch plan.condition {
        case .surfaceAttached, .workspaceSelected:
            capability = .workspaceRead
            pollIntervalMS = waitPollIntervalMS
        case .surfaceTextMatches, .promptReady:
            capability = .surfaceRead
            pollIntervalMS = waitContentPollIntervalMS
        }
        let entry = try resolveOperator(handle, requiring: capability)
        let capabilities = entry.capabilities
        // The wait's own deadline, in the same time base the engine measures against. A tick
        // that does real work (the text-match regex) gets whatever is left of it as its budget,
        // so no single tick can outlive the wait the caller asked for.
        let deadlineMS = waitTimeSource.nowMS() + Int64(plan.effectiveTimeoutMS)
        let verdict = await AutomationWaitEngine.run(
            plan: plan,
            pollIntervalMS: pollIntervalMS,
            timeSource: waitTimeSource,
            probe: { [weak self] in
                // A controller torn down mid-wait has no state to observe; pending lets the
                // bounded timeout produce a truthful timed_out instead of fabricating a result.
                guard let self else { return .pending(AutomationWaitObservation(windowAttached: false)) }
                let remainingMS = Int(max(0, deadlineMS - self.waitTimeSource.nowMS()))
                return await self.evaluateWaitProbe(plan.condition, remainingMS: remainingMS)
            }
        )
        return AutomationWaitResult(
            condition: plan.condition.kind,
            outcome: verdict.outcome,
            waitedMS: verdict.waitedMS,
            requestedTimeoutMS: plan.requestedTimeoutMS,
            effectiveTimeoutMS: plan.effectiveTimeoutMS,
            observed: verdict.observed,
            system: AutomationSystemDescriptor(capabilities: capabilities)
        )
    }

    func automationFocus(for handle: String) throws -> AutomationFocusResult {
        // Operator scope, read-only: focus is key-window/first-responder state, the same
        // domain window.read lists, so it shares that capability rather than minting one.
        let entry = try resolveOperator(handle, requiring: .windowRead)
        return AutomationFocusResult(
            state: focusStateProvider(tileTreeStore),
            system: AutomationSystemDescriptor(capabilities: entry.capabilities)
        )
    }

    /// One evaluation tick for a wait condition, against live state only — no caching between
    /// ticks, so a condition that becomes true mid-wait is observed on the next poll.
    /// `remainingMS` is what is left of the caller's wait budget: the only tick that spends it
    /// is `surface_text_matches`, whose regex runs off this actor and aborts when it expires.
    private func evaluateWaitProbe(
        _ condition: AutomationWaitCondition,
        remainingMS: Int
    ) async -> AutomationWaitProbe {
        switch condition {
        case .surfaceAttached(let surfaceID):
            guard let tileTreeStore else {
                return .pending(AutomationWaitObservation(windowAttached: false, surfaceAttached: false))
            }
            if let surfaceID {
                let attached = tileTreeStore.primarySessionID(containing: surfaceID) != nil
                let observed = AutomationWaitObservation(
                    windowAttached: true,
                    surfaceAttached: attached,
                    attachedSurfaceID: attached ? surfaceID.uuidString : nil
                )
                return attached ? .satisfied(observed) : .pending(observed)
            }
            let activeSessionID = tileTreeStore.activeSessionID
            let attached =
                activeSessionID.map { tileTreeStore.primarySessionID(containing: $0) != nil } ?? false
            let observed = AutomationWaitObservation(
                windowAttached: true,
                surfaceAttached: attached,
                attachedSurfaceID: attached ? activeSessionID?.uuidString : nil
            )
            return attached ? .satisfied(observed) : .pending(observed)

        case .workspaceSelected(let workspaceID):
            let inventory = workspaceInventory()
            let selected = inventory.workspaces.first(where: \.isSelected)
            guard let workspaceID else {
                let observed = AutomationWaitObservation(
                    workspaceSelected: selected != nil,
                    selectedWorkspaceID: selected?.workspaceID
                )
                return selected != nil ? .satisfied(observed) : .pending(observed)
            }
            let target = inventory.workspaces.first { $0.workspaceID == workspaceID }
            if let target, target.isArchived {
                // Selecting an archived workspace navigates to its repo overview instead of
                // selecting it, so this wait is unsatisfiable while the archive state holds.
                return .notApplicable(
                    AutomationWaitObservation(
                        workspaceSelected: false,
                        selectedWorkspaceID: selected?.workspaceID,
                        targetWorkspaceArchived: true
                    )
                )
            }
            let satisfied = selected?.workspaceID == workspaceID
            let observed = AutomationWaitObservation(
                workspaceSelected: satisfied,
                selectedWorkspaceID: selected?.workspaceID,
                targetWorkspaceArchived: target == nil ? nil : false
            )
            return satisfied ? .satisfied(observed) : .pending(observed)

        case .surfaceTextMatches(let surfaceID, let pattern):
            guard let tileTreeStore else {
                return .pending(AutomationWaitObservation(windowAttached: false, surfaceLive: false))
            }
            guard tileTreeStore.primarySessionID(containing: surfaceID) != nil else {
                return .pending(AutomationWaitObservation(windowAttached: true, surfaceLive: false))
            }
            guard let fullText = surfaceTextReader(tileTreeStore, surfaceID) else {
                return .pending(AutomationWaitObservation(windowAttached: true, surfaceLive: true))
            }
            // A tail of the buffer, capped well under what surface.read returns: this tick
            // repeats for the life of the wait and backtracking cost scales with input length,
            // so the wait observes strictly less terminal content than the read route exposes.
            let bounded = Self.boundedSurfaceReadText(
                fullText,
                maxLines: AutomationAPI.surfaceReadMaxLines,
                maxUTF8Bytes: AutomationAPI.waitTextMatchMaxUTF8Bytes
            )
            // Off the MainActor and abortable at the wait's deadline: a pathological pattern
            // costs this wait its budget and nothing else. `nil` means the match did not
            // conclude in time — pending, not "did not match", so the outcome stays truthful.
            let matched = await pattern.firstMatchExists(in: bounded, budgetMS: remainingMS)
            let observed = AutomationWaitObservation(
                windowAttached: true,
                surfaceLive: true,
                textMatched: matched
            )
            return matched == true ? .satisfied(observed) : .pending(observed)

        case .promptReady(let surfaceID):
            guard let tileTreeStore else {
                return .pending(AutomationWaitObservation(windowAttached: false, surfaceLive: false))
            }
            guard tileTreeStore.primarySessionID(containing: surfaceID) != nil else {
                return .pending(AutomationWaitObservation(windowAttached: true, surfaceLive: false))
            }
            guard let ready = promptReadinessReader(tileTreeStore, surfaceID) else {
                // Live tile, no realized terminal view yet: the readiness signal is
                // unavailable, which is pending — not a claim the prompt is not ready.
                return .pending(AutomationWaitObservation(windowAttached: true, surfaceLive: true))
            }
            let observed = AutomationWaitObservation(
                windowAttached: true,
                surfaceLive: true,
                promptReady: ready
            )
            return ready ? .satisfied(observed) : .pending(observed)
        }
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
