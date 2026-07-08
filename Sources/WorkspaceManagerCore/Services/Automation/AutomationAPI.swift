import Foundation

public enum AutomationAPI {
    public static let version = 1
    public static let handleHeader = "x-workspaces-automation-handle"
    public static let socketEnvironmentKey = "WORKSPACES_AUTOMATION_SOCKET"
    public static let handleEnvironmentKey = "WORKSPACES_AUTOMATION_HANDLE"

    public static let v1Capabilities = [
        AutomationCapability.contextRead,
        .surfacesRead,
        .tileFocus,
        .tileSplit,
        .tileClose,
        .browserRead,
    ]

    /// V1 capabilities plus the experimental caller-scoped `input.write` grant.
    /// Kept separate from `v1Capabilities` so default handles never widen.
    public static let inputWriteCapabilities = v1Capabilities + [AutomationCapability.inputWrite]

    /// Capabilities granted to an opt-in operator handle. Capture and read (`window.read`,
    /// `window.snapshot` — composited PNGs; `workspace.read` — the repo/workspace inventory)
    /// plus operator mutation capabilities that drive real UI gestures, never data-layer writes.
    /// Operator handles still never carry tile mutation or `input.write`.
    public static let operatorCapabilities = [
        AutomationCapability.windowRead, .windowSnapshot, .workspaceRead, .workspaceSelect,
        .workspaceCreate, .surfaceRead,
    ]

    public static let inputWriteMaxUTF8Bytes = 32_768

    /// Bounds for `GET /v1/web-surfaces/{id}/snapshot` (`browser.read`). The snapshot
    /// captures the live view's currently-rendered viewport (WKWebView bounds), scaled
    /// to at most `webSnapshotMaxWidth`; a page taller than the viewport is not captured
    /// in full. The encoded PNG is rejected past `webSnapshotMaxRawBytes` rather than
    /// truncated, and the capture is abandoned past `webSnapshotTimeoutSeconds` so a hung
    /// page cannot wedge the automation server.
    public static let webSnapshotMaxWidth = 1600
    public static let webSnapshotMaxRawBytes = 8 * 1_024 * 1_024
    public static let webSnapshotTimeoutSeconds = 5.0

    /// Upper bound for `POST /v1/window/snapshot` (`window.snapshot`, operator scope). A full
    /// composited window at Retina scale is many times a web viewport's pixel count, so the cap is
    /// generous; an encoded PNG past it is rejected (`unsupported`) rather than truncated. There is
    /// no width bound — the snapshot is the window at its true composited resolution, since
    /// full-fidelity evidence is the whole point of the operator capture lane.
    public static let windowSnapshotMaxRawBytes = 64 * 1_024 * 1_024

    /// Bounds for `POST /v1/surface/read` (`surface.read`, operator scope). Requests asking for
    /// more than `surfaceReadMaxLines` are clamped, not rejected. Returned text is also clamped to
    /// `surfaceReadMaxUTF8Bytes` without splitting a UTF-8 scalar; if a single terminal line exceeds
    /// the cap, the returned line is the UTF-8-safe suffix of that line.
    public static let surfaceReadMaxLines = 500
    public static let surfaceReadMaxUTF8Bytes = 256 * 1_024
}

public enum AutomationCapability: String, Codable, Sendable, CaseIterable, Equatable {
    case contextRead = "context.read"
    case surfacesRead = "surfaces.read"
    case tileFocus = "tile.focus"
    case tileSplit = "tile.split"
    case tileClose = "tile.close"
    case inputWrite = "input.write"
    case browserRead = "browser.read"
    case windowRead = "window.read"
    case windowSnapshot = "window.snapshot"
    case workspaceRead = "workspace.read"
    case workspaceSelect = "workspace.select"
    case workspaceCreate = "workspace.create"
    case surfaceRead = "surface.read"
}

public enum AutomationSurfaceKind: String, Codable, Sendable, Equatable {
    case terminal
    case web
}

public enum AutomationTileFocusDirection: String, Codable, Sendable, CaseIterable, Equatable {
    case left
    case right
    case up
    case down
    case next
    case previous
}

public enum AutomationTileSplitDirection: String, Codable, Sendable, CaseIterable, Equatable {
    case left
    case right
    case up
    case down
}

public struct AutomationSystemDescriptor: Codable, Sendable, Equatable {
    public let capabilities: [AutomationCapability]

    public init(capabilities: [AutomationCapability] = AutomationAPI.v1Capabilities) {
        self.capabilities = capabilities
    }
}

public struct AutomationHealthResult: Codable, Sendable, Equatable {
    public let status: String
    public let system: AutomationSystemDescriptor

    public init(status: String = "ok", system: AutomationSystemDescriptor = AutomationSystemDescriptor()) {
        self.status = status
        self.system = system
    }
}

public struct AutomationScopeDescriptor: Codable, Sendable, Equatable {
    public let app: String
    public let window: String
    public let scopeKey: String?
    public let primaryHostSessionID: UUID?

    public init(
        app: String,
        window: String,
        scopeKey: String?,
        primaryHostSessionID: UUID?
    ) {
        self.app = app
        self.window = window
        self.scopeKey = scopeKey
        self.primaryHostSessionID = primaryHostSessionID
    }
}

public struct AutomationSurfaceDescriptor: Codable, Sendable, Equatable {
    public let surfaceID: String
    public let tileID: String?
    public let kind: AutomationSurfaceKind
    public let hostSessionID: UUID?
    public let title: String
    public let cwd: String?
    public let isCaller: Bool
    public let isActive: Bool
    public let isVisible: Bool
    public let capabilities: [AutomationCapability]

    public init(
        surfaceID: String,
        tileID: String?,
        kind: AutomationSurfaceKind,
        hostSessionID: UUID?,
        title: String,
        cwd: String?,
        isCaller: Bool,
        isActive: Bool,
        isVisible: Bool,
        capabilities: [AutomationCapability] = AutomationAPI.v1Capabilities
    ) {
        self.surfaceID = surfaceID
        self.tileID = tileID
        self.kind = kind
        self.hostSessionID = hostSessionID
        self.title = title
        self.cwd = cwd
        self.isCaller = isCaller
        self.isActive = isActive
        self.isVisible = isVisible
        self.capabilities = capabilities
    }
}

public enum AutomationWebSurfaceScope: String, Codable, Sendable, Equatable {
    case global
    case repo
    case workspace
}

/// Read-only descriptor for a WorkSpaces-owned embedded web surface (`browser.read`).
/// Live fields (`liveURL`, `title`, `isLoading`) are populated only when an
/// instantiated `WKWebView` backs the source; when none is live they are `nil` and
/// `isLive` is `false` — the surface is never given a fabricated URL or title.
/// `configuredURL` is the source's declared home, not a claim about the live page.
public struct AutomationWebSurfaceDescriptor: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let scope: AutomationWebSurfaceScope
    public let ownerID: UUID?
    public let displayName: String
    public let configuredURL: String
    public let liveURL: String?
    public let title: String?
    public let isLive: Bool
    public let isLoading: Bool?

    public init(
        sourceID: UUID,
        scope: AutomationWebSurfaceScope,
        ownerID: UUID?,
        displayName: String,
        configuredURL: String,
        liveURL: String?,
        title: String?,
        isLive: Bool,
        isLoading: Bool?
    ) {
        self.sourceID = sourceID
        self.scope = scope
        self.ownerID = ownerID
        self.displayName = displayName
        self.configuredURL = configuredURL
        self.liveURL = liveURL
        self.title = title
        self.isLive = isLive
        self.isLoading = isLoading
    }
}

public struct AutomationWebSurfacesResult: Codable, Sendable, Equatable {
    public let webSurfaces: [AutomationWebSurfaceDescriptor]
    public let system: AutomationSystemDescriptor

    public init(
        webSurfaces: [AutomationWebSurfaceDescriptor],
        system: AutomationSystemDescriptor = AutomationSystemDescriptor()
    ) {
        self.webSurfaces = webSurfaces
        self.system = system
    }
}

/// Bounded PNG snapshot of a live WorkSpaces-owned web surface (`browser.read`).
/// `data` is the base64-encoded PNG; `byteCount` is the raw (pre-base64) PNG size,
/// bounded by `AutomationAPI.webSnapshotMaxRawBytes`. `width`/`height` are the PNG's
/// pixel dimensions. Produced only when a `WKWebView` is live for the source — a
/// non-live source fails with `unsupported` rather than returning a fabricated image.
public struct AutomationWebSurfaceSnapshotResult: Codable, Sendable, Equatable {
    public let sourceID: UUID
    public let encoding: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let data: String
    public let system: AutomationSystemDescriptor

    public init(
        sourceID: UUID,
        encoding: String = "png",
        width: Int,
        height: Int,
        byteCount: Int,
        data: String,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor()
    ) {
        self.sourceID = sourceID
        self.encoding = encoding
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.data = data
        self.system = system
    }
}

public struct AutomationContextResult: Codable, Sendable, Equatable {
    public let surface: AutomationSurfaceDescriptor
    public let scope: AutomationScopeDescriptor
    public let system: AutomationSystemDescriptor

    public init(
        surface: AutomationSurfaceDescriptor,
        scope: AutomationScopeDescriptor,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor()
    ) {
        self.surface = surface
        self.scope = scope
        self.system = system
    }
}

public struct AutomationSurfacesResult: Codable, Sendable, Equatable {
    public let surfaces: [AutomationSurfaceDescriptor]
    public let system: AutomationSystemDescriptor

    public init(
        surfaces: [AutomationSurfaceDescriptor],
        system: AutomationSystemDescriptor = AutomationSystemDescriptor()
    ) {
        self.surfaces = surfaces
        self.system = system
    }
}

/// Read-only descriptor for one of the app's on-screen windows (`window.read`, operator scope).
/// `windowID` is the AppKit window number as a string — stable for the window's lifetime and the
/// same identity `CGWindowList`/ScreenCaptureKit address, so the follow-on `window.snapshot` slice
/// can target it. Geometry is in AppKit points (bottom-left origin, the global display space).
public struct AutomationWindowDescriptor: Codable, Sendable, Equatable {
    public let windowID: String
    public let title: String
    public let subtitle: String?
    public let isMain: Bool
    public let isKey: Bool
    public let isVisible: Bool
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(
        windowID: String,
        title: String,
        subtitle: String?,
        isMain: Bool,
        isKey: Bool,
        isVisible: Bool,
        x: Double,
        y: Double,
        width: Double,
        height: Double
    ) {
        self.windowID = windowID
        self.title = title
        self.subtitle = subtitle
        self.isMain = isMain
        self.isKey = isKey
        self.isVisible = isVisible
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct AutomationWindowsResult: Codable, Sendable, Equatable {
    public let windows: [AutomationWindowDescriptor]
    public let system: AutomationSystemDescriptor

    public init(
        windows: [AutomationWindowDescriptor],
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.windows = windows
        self.system = system
    }
}

/// A composited PNG snapshot of one of the app's on-screen windows (`window.snapshot`, operator
/// scope). `windowID` is the AppKit window number the caller listed via `window.read`; `data` is the
/// base64-encoded PNG and `byteCount` its raw (pre-base64) size, bounded by
/// `AutomationAPI.windowSnapshotMaxRawBytes`. `width`/`height` are the PNG's true pixel dimensions
/// (Retina-scaled, not down-sampled). Produced only for a window the app owns and that is realized
/// on the active Space; an unknown or non-capturable window fails with a structured error rather
/// than a fabricated image. The capture is composited (sidebar chrome + the GhosttyKit terminal
/// surface) and needs no app activation.
public struct AutomationWindowSnapshotResult: Codable, Sendable, Equatable {
    public let windowID: String
    public let encoding: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let data: String
    public let system: AutomationSystemDescriptor

    public init(
        windowID: String,
        encoding: String = "png",
        width: Int,
        height: Int,
        byteCount: Int,
        data: String,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.windowID = windowID
        self.encoding = encoding
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.data = data
        self.system = system
    }
}

/// Read-only descriptor for one of the app's tracked repos (`workspace.read`, operator scope).
/// `repoID` is the SwiftData model id — stable across launches, the identity later orchestration
/// verbs target. `isSelected` reflects whether the repo is the one currently selected for its
/// landing view in the sidebar.
public struct AutomationRepoDescriptor: Codable, Sendable, Equatable {
    public let repoID: UUID
    public let name: String
    public let path: String
    public let isSelected: Bool

    public init(repoID: UUID, name: String, path: String, isSelected: Bool) {
        self.repoID = repoID
        self.name = name
        self.path = path
        self.isSelected = isSelected
    }
}

/// Read-only descriptor for one of the app's workspaces (`workspace.read`, operator scope).
/// `workspaceID` is the SwiftData model id — the stable identity later verbs target. `repoID` ties
/// it back to its source repo. Enough state rides along to target it: `status` (raw
/// `WorkspaceStatus`), `isArchived`, and `backend` (the backend identifier, e.g. `local`/`lume`).
/// `isSelected` reflects whether this is the workspace currently selected in the app.
public struct AutomationWorkspaceDescriptor: Codable, Sendable, Equatable {
    public let workspaceID: UUID
    public let repoID: UUID?
    public let name: String
    public let path: String
    public let branch: String?
    public let status: String
    public let isArchived: Bool
    public let backend: String
    public let isSelected: Bool

    public init(
        workspaceID: UUID,
        repoID: UUID?,
        name: String,
        path: String,
        branch: String?,
        status: String,
        isArchived: Bool,
        backend: String,
        isSelected: Bool
    ) {
        self.workspaceID = workspaceID
        self.repoID = repoID
        self.name = name
        self.path = path
        self.branch = branch
        self.status = status
        self.isArchived = isArchived
        self.backend = backend
        self.isSelected = isSelected
    }
}

/// The projected repo + workspace lists an operator handle reads via `GET /v1/workspaces`. A plain
/// value the app produces on the MainActor (reading the live SwiftData models and selection state)
/// and the controller wraps into `AutomationWorkspacesResult` with the resolved handle's
/// capabilities — the same split the window list uses between its enumerator and result.
public struct AutomationWorkspaceInventory: Sendable, Equatable {
    public let repos: [AutomationRepoDescriptor]
    public let workspaces: [AutomationWorkspaceDescriptor]

    public init(
        repos: [AutomationRepoDescriptor] = [],
        workspaces: [AutomationWorkspaceDescriptor] = []
    ) {
        self.repos = repos
        self.workspaces = workspaces
    }
}

/// Response for `GET /v1/workspaces` (`workspace.read`, operator scope): the app's repos and
/// workspaces with stable model ids, names, and enough state to target. Read-only — mutation verbs
/// use these stable ids when they enter the real UI path.
public struct AutomationWorkspacesResult: Codable, Sendable, Equatable {
    public let repos: [AutomationRepoDescriptor]
    public let workspaces: [AutomationWorkspaceDescriptor]
    public let system: AutomationSystemDescriptor

    public init(
        repos: [AutomationRepoDescriptor],
        workspaces: [AutomationWorkspaceDescriptor],
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.repos = repos
        self.workspaces = workspaces
        self.system = system
    }
}

/// The structured outcome shared by every gesture verb. A verb either `completed` (the
/// gesture ran through the real UI path), needs `confirmationRequired` (a modal the user would see,
/// surfaced as data instead of blocking on UI), or is `unsupported` (it cannot run — most often no
/// live window). `notFound` is the id-does-not-resolve case, mapped to `invalid_request` at the wire.
/// The gesture-verb layer (`AutomationGestureVerbs`) is the single place that produces these, so the
/// verbs-=-clicks rule has one enforcement point. See the layer's doc for why a verb never falls back
/// to a data-layer write.
public enum AutomationGestureOutcomeKind: String, Codable, Sendable, Equatable {
    case completed
    case confirmationRequired = "confirmation_required"
}

/// Structured payload for a gesture that reached UI requiring explicit user confirmation. The
/// payload names the action and the visible confirmation surface so automation callers can report
/// or retry intentionally instead of hanging on a modal.
public struct AutomationConfirmationRequirement: Codable, Sendable, Equatable {
    public let action: String
    public let title: String
    public let message: String
    public let providerID: String?
    public let providerDisplayName: String?
    public let primaryButtonTitle: String?

    public init(
        action: String,
        title: String,
        message: String,
        providerID: String? = nil,
        providerDisplayName: String? = nil,
        primaryButtonTitle: String? = nil
    ) {
        self.action = action
        self.title = title
        self.message = message
        self.providerID = providerID
        self.providerDisplayName = providerDisplayName
        self.primaryButtonTitle = primaryButtonTitle
    }
}

/// What driving the real selection gesture produced. `attachedTerminal` is the observable proof the
/// verb behaved like a click: selecting a live local workspace attaches (and focuses) its terminal
/// surface, so `attachedSurfaceID` is the session a subsequent input would land in — the wrong-PTY
/// guard. Selecting an archived workspace navigates to its repo overview instead, so it completes
/// with `attachedTerminal == false` and no surface.
public struct AutomationWorkspaceSelectEffect: Sendable, Equatable {
    public let selectedWorkspaceID: UUID?
    public let attachedSurfaceID: UUID?
    public let attachedTerminal: Bool

    public init(
        selectedWorkspaceID: UUID?,
        attachedSurfaceID: UUID?,
        attachedTerminal: Bool
    ) {
        self.selectedWorkspaceID = selectedWorkspaceID
        self.attachedSurfaceID = attachedSurfaceID
        self.attachedTerminal = attachedTerminal
    }
}

/// Response for `POST /v1/workspace/select` (`workspace.select`, operator scope). `outcome` is the
/// structured gesture outcome (`completed` or `confirmation_required`); the `unsupported` and bad-id
/// cases fail closed with the stable error codes instead. On `completed`, `attachedTerminal` and
/// `attachedSurfaceID` report what the real selection gesture did — the same terminal attach a
/// sidebar click produces.
public struct AutomationWorkspaceSelectResult: Codable, Sendable, Equatable {
    public let workspaceID: String
    public let outcome: AutomationGestureOutcomeKind
    public let changed: Bool
    public let selectedWorkspaceID: UUID?
    public let attachedTerminal: Bool
    public let attachedSurfaceID: String?
    public let message: String?
    public let system: AutomationSystemDescriptor

    public init(
        workspaceID: String,
        outcome: AutomationGestureOutcomeKind,
        changed: Bool,
        selectedWorkspaceID: UUID? = nil,
        attachedTerminal: Bool = false,
        attachedSurfaceID: String? = nil,
        message: String? = nil,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.workspaceID = workspaceID
        self.outcome = outcome
        self.changed = changed
        self.selectedWorkspaceID = selectedWorkspaceID
        self.attachedTerminal = attachedTerminal
        self.attachedSurfaceID = attachedSurfaceID
        self.message = message
        self.system = system
    }
}

public struct AutomationWorkspaceCreateRequest: Codable, Sendable, Equatable {
    public let repoID: String
    public let name: String
    public let providerID: String?
    public let guestOS: WorkspaceGuestOS?
    public let select: Bool?
    public let fromRef: String?

    public init(
        repoID: String,
        name: String,
        providerID: String? = nil,
        guestOS: WorkspaceGuestOS? = nil,
        select: Bool? = nil,
        fromRef: String? = nil
    ) {
        self.repoID = repoID
        self.name = name
        self.providerID = providerID
        self.guestOS = guestOS
        self.select = select
        self.fromRef = fromRef
    }
}

public struct AutomationWorkspaceCreateCommand: Sendable, Equatable {
    public let repoID: UUID
    public let name: String
    public let providerID: String
    public let guestOS: WorkspaceGuestOS?
    public let shouldSelect: Bool
    public let fromRef: String?

    public init(
        repoID: UUID,
        name: String,
        providerID: String,
        guestOS: WorkspaceGuestOS? = nil,
        shouldSelect: Bool = true,
        fromRef: String? = nil
    ) {
        self.repoID = repoID
        self.name = name
        self.providerID = providerID
        self.guestOS = guestOS
        self.shouldSelect = shouldSelect
        self.fromRef = fromRef
    }
}

/// What driving the real workspace-create gesture produced. When `shouldSelect` is true, a completed
/// create reports the selected workspace and attached terminal surface so callers can prove the next
/// input will land in the newly created PTY. With `shouldSelect` false, creation still runs through
/// the sidebar helper but intentionally preserves the current selection and active surface.
public struct AutomationWorkspaceCreateEffect: Sendable, Equatable {
    public let repoID: UUID
    public let workspaceID: UUID
    public let workspaceName: String
    public let workspacePath: String
    public let selectedWorkspaceID: UUID?
    public let attachedSurfaceID: UUID?
    public let attachedTerminal: Bool

    public init(
        repoID: UUID,
        workspaceID: UUID,
        workspaceName: String,
        workspacePath: String,
        selectedWorkspaceID: UUID?,
        attachedSurfaceID: UUID?,
        attachedTerminal: Bool
    ) {
        self.repoID = repoID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspacePath = workspacePath
        self.selectedWorkspaceID = selectedWorkspaceID
        self.attachedSurfaceID = attachedSurfaceID
        self.attachedTerminal = attachedTerminal
    }
}

/// Response for `POST /v1/workspace/create` (`workspace.create`, operator scope). On completion the
/// result mirrors the sidebar create path: the new workspace is selected and its terminal is attached.
/// If the path reaches a setup sheet or other modal UI, the success envelope reports
/// `confirmation_required` with a structured payload naming what needs user confirmation.
public struct AutomationWorkspaceCreateResult: Codable, Sendable, Equatable {
    public let repoID: String
    public let workspaceID: UUID?
    public let workspaceName: String
    public let workspacePath: String?
    public let outcome: AutomationGestureOutcomeKind
    public let changed: Bool
    public let selectedWorkspaceID: UUID?
    public let attachedTerminal: Bool
    public let attachedSurfaceID: String?
    public let confirmation: AutomationConfirmationRequirement?
    public let message: String?
    public let system: AutomationSystemDescriptor

    public init(
        repoID: String,
        workspaceID: UUID? = nil,
        workspaceName: String,
        workspacePath: String? = nil,
        outcome: AutomationGestureOutcomeKind,
        changed: Bool,
        selectedWorkspaceID: UUID? = nil,
        attachedTerminal: Bool = false,
        attachedSurfaceID: String? = nil,
        confirmation: AutomationConfirmationRequirement? = nil,
        message: String? = nil,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.repoID = repoID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspacePath = workspacePath
        self.outcome = outcome
        self.changed = changed
        self.selectedWorkspaceID = selectedWorkspaceID
        self.attachedTerminal = attachedTerminal
        self.attachedSurfaceID = attachedSurfaceID
        self.confirmation = confirmation
        self.message = message
        self.system = system
    }
}

public struct AutomationSurfaceReadRequest: Codable, Sendable, Equatable {
    public let surfaceID: String
    public let lines: Int

    public init(surfaceID: String, lines: Int) {
        self.surfaceID = surfaceID
        self.lines = lines
    }
}

/// Plain-text read-back for an operator-created terminal surface (`surface.read`). `text` is the
/// bounded, style-free terminal dump suffix. `requestedLines` is the caller's original request;
/// `lines` is the effective line cap after clamping to `AutomationAPI.surfaceReadMaxLines`;
/// `returnedLines` and `byteCount` describe the bounded payload actually returned.
public struct AutomationSurfaceReadResult: Codable, Sendable, Equatable {
    public let surfaceID: String
    public let requestedLines: Int
    public let lines: Int
    public let returnedLines: Int
    public let byteCount: Int
    public let text: String
    public let system: AutomationSystemDescriptor

    public init(
        surfaceID: String,
        requestedLines: Int,
        lines: Int,
        returnedLines: Int,
        byteCount: Int,
        text: String,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor(
            capabilities: AutomationAPI.operatorCapabilities
        )
    ) {
        self.surfaceID = surfaceID
        self.requestedLines = requestedLines
        self.lines = lines
        self.returnedLines = returnedLines
        self.byteCount = byteCount
        self.text = text
        self.system = system
    }
}

public struct AutomationMutationResult: Codable, Sendable, Equatable {
    public let changed: Bool
    public let focusedSurfaceID: String?
    public let createdSurfaceID: String?
    public let closedSurfaceID: String?
    public let reason: String?
    public let system: AutomationSystemDescriptor

    public init(
        changed: Bool,
        focusedSurfaceID: String? = nil,
        createdSurfaceID: String? = nil,
        closedSurfaceID: String? = nil,
        reason: String? = nil,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor()
    ) {
        self.changed = changed
        self.focusedSurfaceID = focusedSurfaceID
        self.createdSurfaceID = createdSurfaceID
        self.closedSurfaceID = closedSurfaceID
        self.reason = reason
        self.system = system
    }
}

public struct AutomationInputWriteRequest: Codable, Sendable, Equatable {
    public let text: String
    public let submit: Bool?

    public init(text: String, submit: Bool? = nil) {
        self.text = text
        self.submit = submit
    }
}

public struct AutomationInputWriteResult: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let byteCount: Int
    public let surfaceID: String
    public let system: AutomationSystemDescriptor

    public init(
        accepted: Bool,
        byteCount: Int,
        surfaceID: String,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor()
    ) {
        self.accepted = accepted
        self.byteCount = byteCount
        self.surfaceID = surfaceID
        self.system = system
    }
}

public struct AutomationTerminalEnvironment: Sendable, Equatable {
    public let socketPath: String
    public let handle: String

    public init(socketPath: String, handle: String) {
        self.socketPath = socketPath
        self.handle = handle
    }
}

/// The per-launch operator credential (`[A1]`). An opt-in launch mints this and writes it to a
/// user-private file next to `automation.sock`; any same-user process (a dev shell, `evidence.sh`,
/// CI) reads it to call operator-scoped routes without living inside a terminal tile. The `handle`
/// registers in the live handle registry and dies with the launch, so a credential left behind by a
/// crashed launch fails closed (`stale_handle`) against the fresh registry. Normal launches mint no
/// credential; the file's absence is the fail-closed signal.
public struct AutomationOperatorCredential: Codable, Sendable, Equatable {
    public let v: Int
    public let socketPath: String
    public let handle: String
    public let capabilities: [AutomationCapability]

    public init(
        socketPath: String,
        handle: String,
        capabilities: [AutomationCapability] = AutomationAPI.operatorCapabilities
    ) {
        self.v = AutomationAPI.version
        self.socketPath = socketPath
        self.handle = handle
        self.capabilities = capabilities
    }
}

public struct AutomationResponseEnvelope<Result: Codable & Sendable>: Codable, Sendable, Equatable
where Result: Equatable {
    public let v: Int
    public let ok: Bool
    public let result: Result?
    public let error: AutomationErrorResponse?

    public init(result: Result) {
        self.v = AutomationAPI.version
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(error: AutomationErrorResponse) {
        self.v = AutomationAPI.version
        self.ok = false
        self.result = nil
        self.error = error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(ok, forKey: .ok)
        if let result {
            try container.encode(result, forKey: .result)
        }
        if let error {
            try container.encode(error, forKey: .error)
        }
    }
}

public struct AutomationEmptyResult: Codable, Sendable, Equatable {
    public init() {}
}

public enum AutomationErrorCode: String, Codable, Sendable, Equatable {
    case disabled
    case capabilityDenied = "capability_denied"
    case missingHandle = "missing_handle"
    case staleHandle = "stale_handle"
    case invalidRequest = "invalid_request"
    case malformedJSON = "malformed_json"
    case routeNotFound = "route_not_found"
    case methodNotAllowed = "method_not_allowed"
    case unsupported
    case internalError = "internal_error"
}

public struct AutomationErrorResponse: Codable, Sendable, Equatable, LocalizedError {
    public let code: AutomationErrorCode
    public let message: String

    public init(code: AutomationErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        "\(code.rawValue): \(message)"
    }
}

public struct AutomationServiceError: Error, Sendable, Equatable {
    public let response: AutomationErrorResponse

    public init(_ code: AutomationErrorCode, _ message: String) {
        self.response = AutomationErrorResponse(code: code, message: message)
    }

    public init(response: AutomationErrorResponse) {
        self.response = response
    }
}

@MainActor
public protocol AutomationControlling: AnyObject, Sendable {
    func automationContext(for handle: String) throws -> AutomationContextResult
    func automationSurfaces(for handle: String) throws -> AutomationSurfacesResult
    func automationWindows(for handle: String) throws -> AutomationWindowsResult
    func automationWorkspaces(for handle: String) throws -> AutomationWorkspacesResult
    func automationSelectWorkspace(
        for handle: String,
        workspaceID: String
    ) async throws -> AutomationWorkspaceSelectResult
    func automationCreateWorkspace(
        for handle: String,
        request: AutomationWorkspaceCreateRequest
    ) async throws -> AutomationWorkspaceCreateResult
    func automationWindowSnapshot(
        for handle: String,
        windowID: String
    ) async throws -> AutomationWindowSnapshotResult
    func automationReadSurface(
        for handle: String,
        request: AutomationSurfaceReadRequest
    ) throws -> AutomationSurfaceReadResult
    func automationWebSurfaces(for handle: String) throws -> AutomationWebSurfacesResult
    func automationWebSurfaceSnapshot(
        for handle: String,
        sourceID: UUID
    ) async throws -> AutomationWebSurfaceSnapshotResult
    func automationFocusTile(
        for handle: String,
        direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult
    func automationSplitTile(
        for handle: String,
        direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult
    func automationCloseTile(for handle: String) throws -> AutomationMutationResult
    func automationWriteInput(
        for handle: String,
        text: String,
        submit: Bool
    ) throws -> AutomationInputWriteResult

    /// Whether `handle` resolves to a live operator entry. The listener consults this to tag audit
    /// events, so operator calls are distinguishable in `automation-audit.jsonl` without the audit
    /// logger seeing the opaque handle's scope. A missing/stale handle is not an operator handle.
    func automationHandleIsOperator(_ handle: String) -> Bool
}
