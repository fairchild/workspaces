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
        encoder: JSONEncoder = AutomationJSON.encoder
    ) async -> AutomationHTTPResult {
        do {
            let result = try await routeResult(request, controller: controller, enabled: enabled)
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
        enabled: Bool
    ) async throws -> any CodableSendableEquatable {
        let method = request.method.uppercased()
        switch (method, request.path) {
        case ("GET", "/v1/health"):
            return AutomationHealthResult()

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

        switch (method, request.path) {
        case ("GET", "/v1/context"):
            return try await controller.automationContext(for: handle)

        case ("GET", "/v1/surfaces"):
            return try await controller.automationSurfaces(for: handle)

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

        case (_, "/v1/context"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/context.")
        case (_, "/v1/surfaces"):
            throw AutomationServiceError(.methodNotAllowed, "Use GET /v1/surfaces.")
        case (_, "/v1/tile/focus"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/tile/focus.")
        case (_, "/v1/tile/split"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/tile/split.")
        case (_, "/v1/tile/close"):
            throw AutomationServiceError(.methodNotAllowed, "Use POST /v1/tile/close.")
        default:
            throw AutomationServiceError(.routeNotFound, "Unsupported automation route: \(method) \(request.path)")
        }
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
        case .disabled:
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
extension AutomationMutationResult: CodableSendableEquatable {}
extension AutomationEmptyResult: CodableSendableEquatable {}

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
