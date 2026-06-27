import Foundation

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
}
