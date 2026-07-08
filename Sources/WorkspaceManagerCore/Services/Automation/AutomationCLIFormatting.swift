import Foundation

public enum AutomationCLIResponseError: Error, Equatable, LocalizedError {
    case protocolVersionMismatch(cliVersion: Int, appVersion: Int, bundledCLIPath: String)
    case undecodableResponse(rawBody: String)

    public var errorDescription: String? {
        switch self {
        case .protocolVersionMismatch(let cliVersion, let appVersion, let bundledCLIPath):
            return "CLI v\(cliVersion) vs app v\(appVersion) — use the bundled CLI at \(bundledCLIPath)"
        case .undecodableResponse(let rawBody):
            return "Could not parse automation health response. Raw response:\n\(rawBody)"
        }
    }
}

public enum AutomationCLIResultPrinter {
    public static func resultJSON<Result: Encodable>(_ result: Result) throws -> String {
        let data = try AutomationJSON.prettyEncoder.encode(result)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func decodeEnvelope<Result: Codable & Sendable & Equatable>(
        _ type: Result.Type,
        from response: AutomationSocketClient.Response
    ) throws -> Result {
        let envelope = try AutomationJSON.decoder.decode(AutomationResponseEnvelope<Result>.self, from: response.body)
        if envelope.ok, let result = envelope.result {
            return result
        }
        let error =
            envelope.error
            ?? AutomationErrorResponse(code: .internalError, message: "Automation response did not include an error.")
        throw AutomationServiceError(response: error)
    }

    public static func decodeHealthEnvelope(
        from response: AutomationSocketClient.Response,
        bundledCLIPath: String
    ) throws -> AutomationHealthResult {
        if let protocolVersion = healthProtocolVersion(in: response.body),
            protocolVersion != AutomationAPI.version
        {
            throw AutomationCLIResponseError.protocolVersionMismatch(
                cliVersion: AutomationAPI.version,
                appVersion: protocolVersion,
                bundledCLIPath: bundledCLIPath
            )
        }
        do {
            return try decodeEnvelope(AutomationHealthResult.self, from: response)
        } catch let error as AutomationServiceError {
            throw error
        } catch {
            throw AutomationCLIResponseError.undecodableResponse(rawBody: rawBody(response.body))
        }
    }

    private static func healthProtocolVersion(in body: Data) -> Int? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let result = object["result"] as? [String: Any],
            let server = result["server"] as? [String: Any]
        else {
            return nil
        }
        return server["protocolVersion"] as? Int
    }

    private static func rawBody(_ body: Data) -> String {
        String(data: body, encoding: .utf8) ?? body.base64EncodedString()
    }
}
