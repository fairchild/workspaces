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
    ]
}

public enum AutomationCapability: String, Codable, Sendable, CaseIterable, Equatable {
    case contextRead = "context.read"
    case surfacesRead = "surfaces.read"
    case tileFocus = "tile.focus"
    case tileSplit = "tile.split"
    case tileClose = "tile.close"
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

public struct AutomationContextResult: Codable, Sendable, Equatable {
    public let handle: String
    public let surface: AutomationSurfaceDescriptor
    public let scope: AutomationScopeDescriptor
    public let system: AutomationSystemDescriptor

    public init(
        handle: String,
        surface: AutomationSurfaceDescriptor,
        scope: AutomationScopeDescriptor,
        system: AutomationSystemDescriptor = AutomationSystemDescriptor()
    ) {
        self.handle = handle
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

public struct AutomationTerminalEnvironment: Sendable, Equatable {
    public let socketPath: String
    public let handle: String

    public init(socketPath: String, handle: String) {
        self.socketPath = socketPath
        self.handle = handle
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
    func automationFocusTile(
        for handle: String,
        direction: AutomationTileFocusDirection
    ) throws -> AutomationMutationResult
    func automationSplitTile(
        for handle: String,
        direction: AutomationTileSplitDirection
    ) throws -> AutomationMutationResult
    func automationCloseTile(for handle: String) throws -> AutomationMutationResult
}
