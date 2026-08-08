import Foundation

struct AutomationHTTPResult: Sendable {
    let status: Int
    let body: Data
}

enum AutomationHTTPRouter {
    static func route(
        _ request: HTTPRequest,
        controller: any AutomationControlling,
        enabled: Bool,
        healthServer: AutomationServerDescriptor? = nil,
        encoder: JSONEncoder = AutomationJSON.encoder
    ) async -> AutomationHTTPResult {
        do {
            let result = try await routeResult(
                request,
                controller: controller,
                enabled: enabled,
                healthServer: healthServer
            )
            return try success(result, encoder: encoder)
        } catch let error as AutomationServiceError {
            return failure(error.response, status: httpStatus(for: error.response.code), encoder: encoder)
        } catch {
            return failure(
                AutomationErrorResponse(code: .internalError, message: "\(error)"),
                status: 500,
                encoder: encoder
            )
        }
    }

    private static func routeResult(
        _ request: HTTPRequest,
        controller: any AutomationControlling,
        enabled: Bool,
        healthServer: AutomationServerDescriptor?
    ) async throws -> any CodableSendableEquatable {
        let method = request.method.uppercased()
        switch (method, request.path) {
        case ("GET", "/v1/health"):
            return AutomationHealthResult(server: healthServer)

        case (_, "/v1/health"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/health.")

        default:
            break
        }

        guard enabled else {
            throw AutomationServiceError(
                .disabled,
                "The WorkSpaces Automation API is disabled. Enable the Automation API experiment and restart WorkSpaces."
            )
        }

        let handle = try scopedHandle(from: request)

        // Dynamic route: /v1/web-surfaces/{id}/snapshot. Checked before the static switch
        // since it shares the /v1/web-surfaces prefix but never collides with the exact path.
        if let segment = webSurfaceSnapshotSegment(inPath: request.path) {
            guard method == "GET" else {
                throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/web-surfaces/{id}/snapshot.")
            }
            guard let sourceID = UUID(uuidString: segment) else {
                throw AutomationServiceError(.invalidRequest, "Web surface id must be a UUID.")
            }
            return try await controller.automationWebSurfaceSnapshot(for: handle, sourceID: sourceID)
        }

        switch (method, request.path) {
        case ("GET", "/v1/context"):
            return try await controller.automationContext(for: handle)

        case ("GET", "/v1/surfaces"):
            return try await controller.automationSurfaces(for: handle)

        case ("GET", "/v1/web-surfaces"):
            return try await controller.automationWebSurfaces(for: handle)

        case ("GET", "/v1/windows"):
            return try await controller.automationWindows(for: handle)

        case ("GET", "/v1/workspaces"):
            return try await controller.automationWorkspaces(for: handle)

        case ("POST", "/v1/window/snapshot"):
            let windowID = try decodeWindowID(from: request.body)
            return try await controller.automationWindowSnapshot(for: handle, windowID: windowID)

        case ("POST", "/v1/workspace/select"):
            let workspaceID = try decodeWorkspaceID(from: request.body)
            return try await controller.automationSelectWorkspace(for: handle, workspaceID: workspaceID)

        case ("POST", "/v1/workspace/create"):
            let create = try decodeWorkspaceCreate(from: request.body)
            return try await controller.automationCreateWorkspace(for: handle, request: create)

        case ("POST", "/v1/surface/read"):
            let read = try decodeSurfaceRead(from: request.body)
            return try await controller.automationReadSurface(for: handle, request: read)

        case ("POST", "/v1/workspace/archive"):
            let archive = try decodeWorkspaceArchive(from: request.body)
            return try await controller.automationArchiveWorkspace(for: handle, request: archive)

        case ("POST", "/v1/tile/focus"):
            let direction = try decodeDirection(
                AutomationTileFocusDirection.self,
                from: request.body,
                allowEmptyBody: false
            )
            return try await controller.automationFocusTile(for: handle, direction: direction)

        case ("POST", "/v1/tile/split"):
            let direction = try decodeDirection(
                AutomationTileSplitDirection.self,
                from: request.body,
                allowEmptyBody: false
            )
            return try await controller.automationSplitTile(for: handle, direction: direction)

        case ("POST", "/v1/tile/close"):
            try rejectCallerSuppliedTargetIDs(in: request.body, allowEmptyBody: true)
            return try await controller.automationCloseTile(for: handle)

        case ("POST", "/v1/input/write"):
            let write = try decodeInputWrite(from: request.body)
            return try await controller.automationWriteInput(
                for: handle,
                text: write.text,
                submit: write.submit ?? false
            )

        case ("GET", "/v1/ui-state"):
            return try await controller.automationUIState(for: handle)

        case (_, "/v1/context"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/context.")
        case (_, "/v1/surfaces"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/surfaces.")
        case (_, "/v1/web-surfaces"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/web-surfaces.")
        case (_, "/v1/windows"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/windows.")
        case (_, "/v1/workspaces"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/workspaces.")
        case (_, "/v1/window/snapshot"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/window/snapshot.")
        case (_, "/v1/workspace/select"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/workspace/select.")
        case (_, "/v1/workspace/create"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/workspace/create.")
        case (_, "/v1/surface/read"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/surface/read.")
        case (_, "/v1/workspace/archive"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/workspace/archive.")
        case (_, "/v1/tile/focus"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/tile/focus.")
        case (_, "/v1/tile/split"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/tile/split.")
        case (_, "/v1/tile/close"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/tile/close.")
        case (_, "/v1/input/write"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/input/write.")
        case (_, "/v1/ui-state"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/ui-state.")
        default:
            throw AutomationServiceError(.routeNotFound, "Unsupported automation route: \(method) \(request.path)")
        }
    }

    /// The raw id segment of `/v1/web-surfaces/{segment}/snapshot`, or `nil` when `path`
    /// is not that shape. UUID validation is the caller's job so a well-shaped path with a
    /// bad id reports `invalid_request` rather than falling through to `route_not_found`.
    private static func webSurfaceSnapshotSegment(inPath path: String) -> String? {
        let prefix = "/v1/web-surfaces/"
        let suffix = "/snapshot"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        // start == end is the empty-id path (`/v1/web-surfaces//snapshot`): a well-shaped
        // snapshot route with a bad id, so surface it (UUID validation returns invalid_request)
        // rather than letting it fall through to route_not_found. start > end is the overlapping
        // case (`/v1/web-surfaces/snapshot`), which is genuinely not this route.
        guard start <= end else { return nil }
        let segment = String(path[start..<end])
        guard !segment.contains("/") else { return nil }
        return segment
    }

    private static func scopedHandle(from request: HTTPRequest) throws -> String {
        guard
            let handle = request.headers[AutomationAPI.handleHeader]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !handle.isEmpty
        else {
            throw AutomationServiceError(
                .missingHandle,
                "Missing \(AutomationAPI.handleHeader) header. Run this command from a WorkSpaces terminal tile."
            )
        }
        return handle
    }

    private static func decodeDirection<Direction>(
        _ type: Direction.Type,
        from body: Data,
        allowEmptyBody: Bool
    ) throws -> Direction where Direction: RawRepresentable, Direction.RawValue == String {
        try rejectCallerSuppliedTargetIDs(in: body, allowEmptyBody: allowEmptyBody)
        guard !body.isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request body must include a direction.")
        }
        guard
            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let rawDirection = object["direction"] as? String
        else {
            throw AutomationServiceError(.invalidRequest, "Request body must be JSON with a string direction.")
        }
        guard let direction = Direction(rawValue: rawDirection) else {
            throw AutomationServiceError(.invalidRequest, "Unsupported direction: \(rawDirection).")
        }
        return direction
    }

    /// The `windowID` from a snapshot request body. Unlike the tile routes, a window id is not a
    /// caller-supplied *tile* id to reject — it is a global window identity the caller obtained from
    /// `window.read`, the same way the web-surface snapshot names a source id in its path. So this
    /// route accepts it directly; the controller still confirms the id names a window the app owns.
    private static func decodeWindowID(from body: Data) throws -> String {
        guard !body.isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request body must include a windowID.")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw AutomationServiceError(.malformedJSON, "Request body is not valid JSON.")
        }
        guard let object = parsed as? [String: Any] else {
            throw AutomationServiceError(.invalidRequest, "Request body must be a JSON object.")
        }
        guard
            let windowID = object["windowID"] as? String,
            !windowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AutomationServiceError(.invalidRequest, "Request body must be JSON with a non-empty string windowID.")
        }
        return windowID
    }

    /// The `workspaceID` from a `workspace.select` body. Like the window id, this is a global stable
    /// identity the caller obtained from `workspace.read` (a SwiftData model id), not a caller-supplied
    /// *tile* id to reject — so the route accepts it directly and the controller confirms it names a
    /// workspace the app tracks. UUID-shape validation is the controller's job so a well-shaped body
    /// with a non-UUID id reports `invalid_request` rather than a decode failure.
    private static func decodeWorkspaceID(from body: Data) throws -> String {
        guard !body.isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request body must include a workspaceID.")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw AutomationServiceError(.malformedJSON, "Request body is not valid JSON.")
        }
        guard let object = parsed as? [String: Any] else {
            throw AutomationServiceError(.invalidRequest, "Request body must be a JSON object.")
        }
        guard
            let workspaceID = object["workspaceID"] as? String,
            !workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AutomationServiceError(
                .invalidRequest, "Request body must be JSON with a non-empty string workspaceID.")
        }
        return workspaceID
    }

    /// The archive body: the same global `workspaceID` contract as `workspace.select`, plus the
    /// optional `teardownTerminals` boolean. A present-but-non-boolean `teardownTerminals` is
    /// rejected rather than silently treated as false, so a caller cannot believe it requested
    /// teardown when the server ignored the field. `JSONSerialization` bridges JSON numbers to
    /// `Bool` (`1` casts to `true`), so the check is on the CoreFoundation boolean type — that
    /// matches the strictness `JSONDecoder` already applies to the `Codable` routes' booleans.
    private static func decodeWorkspaceArchive(from body: Data) throws -> AutomationWorkspaceArchiveRequest {
        let workspaceID = try decodeWorkspaceID(from: body)
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var teardownTerminals: Bool?
        if let raw = object["teardownTerminals"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw AutomationServiceError(
                    .invalidRequest, "Request 'teardownTerminals' must be a boolean when provided.")
            }
            teardownTerminals = number.boolValue
        }
        return AutomationWorkspaceArchiveRequest(workspaceID: workspaceID, teardownTerminals: teardownTerminals)
    }

    private static func decodeWorkspaceCreate(from body: Data) throws -> AutomationWorkspaceCreateRequest {
        try rejectCallerSuppliedTargetIDs(in: body, allowEmptyBody: false)
        let request: AutomationWorkspaceCreateRequest
        do {
            request = try AutomationJSON.decoder.decode(AutomationWorkspaceCreateRequest.self, from: body)
        } catch {
            throw AutomationServiceError(
                .invalidRequest,
                "Request body must be JSON with string 'repoID', string 'name', optional string 'providerID', optional 'guestOS', optional boolean 'select', and optional string 'fromRef'."
            )
        }
        guard !request.repoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request 'repoID' must be a non-empty string.")
        }
        guard !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request 'name' must be a non-empty string.")
        }
        if let providerID = request.providerID,
            providerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw AutomationServiceError(.invalidRequest, "Request 'providerID' must be non-empty when provided.")
        }
        if let fromRef = request.fromRef {
            switch WorkspaceCreationRefValidator.normalize(fromRef) {
            case .success:
                break
            case .failure(let error):
                throw AutomationServiceError(.invalidRequest, error.message)
            }
        }
        return request
    }

    private static func decodeInputWrite(from body: Data) throws -> AutomationInputWriteRequest {
        try rejectCallerSuppliedTargetIDs(in: body, allowEmptyBody: false)
        let request: AutomationInputWriteRequest
        do {
            request = try AutomationJSON.decoder.decode(AutomationInputWriteRequest.self, from: body)
        } catch {
            throw AutomationServiceError(
                .invalidRequest,
                "Request body must be JSON with a string 'text' and optional boolean 'submit'."
            )
        }
        guard !request.text.isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request 'text' must be a non-empty string.")
        }
        guard request.text.utf8.count <= AutomationAPI.inputWriteMaxUTF8Bytes else {
            throw AutomationServiceError(
                .invalidRequest,
                "Request 'text' exceeds the \(AutomationAPI.inputWriteMaxUTF8Bytes)-byte limit."
            )
        }
        return request
    }

    private static func decodeSurfaceRead(from body: Data) throws -> AutomationSurfaceReadRequest {
        guard !body.isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request body is required.")
        }
        let request: AutomationSurfaceReadRequest
        do {
            request = try AutomationJSON.decoder.decode(AutomationSurfaceReadRequest.self, from: body)
        } catch {
            throw AutomationServiceError(
                .invalidRequest,
                "Request body must be JSON with string 'surfaceID' and positive integer 'lines'."
            )
        }
        guard !request.surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationServiceError(.invalidRequest, "Request 'surfaceID' must be a non-empty string.")
        }
        guard request.lines > 0 else {
            throw AutomationServiceError(.invalidRequest, "Request 'lines' must be greater than zero.")
        }
        return request
    }

    private static func rejectCallerSuppliedTargetIDs(in body: Data, allowEmptyBody: Bool) throws {
        guard !body.isEmpty else {
            if allowEmptyBody { return }
            throw AutomationServiceError(.invalidRequest, "Request body is required.")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw AutomationServiceError(.malformedJSON, "Request body is not valid JSON.")
        }

        guard let dictionary = object as? [String: Any] else {
            throw AutomationServiceError(.invalidRequest, "Request body must be a JSON object.")
        }

        let forbiddenKeys = [
            "tileID",
            "tileId",
            "surfaceID",
            "surfaceId",
            "targetTileID",
            "targetTileId",
            "targetSurfaceID",
            "targetSurfaceId",
            "hostSessionID",
            "hostSessionId",
        ]
        if let forbidden = dictionary.keys.first(where: { forbiddenKeys.contains($0) }) {
            throw AutomationServiceError(
                .invalidRequest,
                "Scoped operations resolve the caller from \(AutomationAPI.handleEnvironmentKey); caller-supplied '\(forbidden)' is not accepted."
            )
        }
    }

    private static func success(
        _ result: any CodableSendableEquatable,
        encoder: JSONEncoder
    ) throws -> AutomationHTTPResult {
        let data = try result.encodeSuccessEnvelope(encoder: encoder)
        return AutomationHTTPResult(status: 200, body: data)
    }

    private static func failure(
        _ error: AutomationErrorResponse,
        status: Int,
        encoder: JSONEncoder
    ) -> AutomationHTTPResult {
        let envelope = AutomationResponseEnvelope<AutomationEmptyResult>(error: error)
        let data =
            (try? encoder.encode(envelope))
            ?? Data(
                "{\"v\":1,\"ok\":false,\"error\":{\"code\":\"internal_error\",\"message\":\"Encoding failed.\"}}".utf8)
        return AutomationHTTPResult(status: status, body: data)
    }

    private static func httpStatus(for code: AutomationErrorCode) -> Int {
        switch code {
        case .disabled, .capabilityDenied:
            return 403
        case .missingHandle, .staleHandle:
            return 401
        case .invalidRequest, .malformedJSON:
            return 400
        case .methodNotAllowed:
            return 405
        case .routeNotFound:
            return 404
        case .unsupported:
            return 409
        case .terminalActive, .closeBlockedByConfirmation:
            return 409
        case .internalError:
            return 500
        }
    }
}

protocol CodableSendableEquatable: Codable, Sendable, Equatable {
    func encodeSuccessEnvelope(encoder: JSONEncoder) throws -> Data
}

extension CodableSendableEquatable {
    func encodeSuccessEnvelope(encoder: JSONEncoder) throws -> Data {
        try encoder.encode(AutomationResponseEnvelope(result: self))
    }
}

extension AutomationHealthResult: CodableSendableEquatable {}
extension AutomationContextResult: CodableSendableEquatable {}
extension AutomationSurfacesResult: CodableSendableEquatable {}
extension AutomationWindowsResult: CodableSendableEquatable {}
extension AutomationWorkspacesResult: CodableSendableEquatable {}
extension AutomationWorkspaceSelectResult: CodableSendableEquatable {}
extension AutomationWorkspaceCreateResult: CodableSendableEquatable {}
extension AutomationWorkspaceArchiveResult: CodableSendableEquatable {}
extension AutomationWindowSnapshotResult: CodableSendableEquatable {}
extension AutomationSurfaceReadResult: CodableSendableEquatable {}
extension AutomationWebSurfacesResult: CodableSendableEquatable {}
extension AutomationWebSurfaceSnapshotResult: CodableSendableEquatable {}
extension AutomationMutationResult: CodableSendableEquatable {}
extension AutomationInputWriteResult: CodableSendableEquatable {}
extension AutomationEmptyResult: CodableSendableEquatable {}
extension AutomationUIStateResult: CodableSendableEquatable {}

enum AutomationJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static let decoder = JSONDecoder()
}
