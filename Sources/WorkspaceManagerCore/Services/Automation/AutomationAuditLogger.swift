import Foundation

public actor AutomationAuditLogger {
    public struct Event: Codable, Sendable, Equatable {
        public let timestamp: String
        public let method: String
        public let path: String
        public let handlePresent: Bool
        /// True when the request's handle resolved to a live operator entry, so operator calls are
        /// distinguishable from tile calls in the audit log (`[A1]`).
        public let operatorHandle: Bool
        public let allowed: Bool
        public let errorCode: AutomationErrorCode?
        public let metadata: [String: String]?

        public init(
            timestamp: String,
            method: String,
            path: String,
            handlePresent: Bool,
            operatorHandle: Bool = false,
            allowed: Bool,
            errorCode: AutomationErrorCode?,
            metadata: [String: String]? = nil
        ) {
            self.timestamp = timestamp
            self.method = method
            self.path = path
            self.handlePresent = handlePresent
            self.operatorHandle = operatorHandle
            self.allowed = allowed
            self.errorCode = errorCode
            self.metadata = metadata
        }
    }

    private let auditURL: URL
    private let encoder = JSONEncoder()
    private let timestampFormatter = ISO8601DateFormatter()

    public init(auditURL: URL) {
        self.auditURL = auditURL
        encoder.outputFormatting = [.sortedKeys]
    }

    public nonisolated static func defaultAuditURL(bundleIdentifier: String) -> URL {
        let appSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        return dir.appendingPathComponent("automation-audit.jsonl", isDirectory: false)
    }

    public func record(
        method: String,
        path: String,
        headers: [String: String],
        requestBody: Data = Data(),
        responseBody: Data,
        operatorHandle: Bool = false
    ) {
        let summary = (try? AutomationJSON.decoder.decode(AuditEnvelopeSummary.self, from: responseBody))
        let event = Event(
            timestamp: timestampFormatter.string(from: Date()),
            method: method,
            path: path,
            handlePresent: headers[AutomationAPI.handleHeader]?.isEmpty == false,
            operatorHandle: operatorHandle,
            allowed: summary?.ok == true,
            errorCode: summary?.error?.code,
            metadata: Self.routeMetadata(method: method, path: path, body: requestBody)
        )
        guard let data = try? encoder.encode(event) else { return }

        do {
            try FileManager.default.createDirectory(
                at: auditURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: auditURL.path) {
                try Data().write(to: auditURL)
            }
            let handle = try FileHandle(forWritingTo: auditURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            NSLog("[AutomationAudit] append failed: %@", "\(error)")
        }
    }

    private nonisolated static func routeMetadata(method: String, path: String, body: Data) -> [String: String]? {
        guard method.uppercased() == "POST", path == "/v1/workspace/create", !body.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return nil
        }

        var metadata: [String: String] = [:]
        if object.keys.contains("select") {
            metadata["workspaceCreate.select"] = "provided"
        }
        if object.keys.contains("fromRef") {
            metadata["workspaceCreate.fromRef"] = "provided"
        }
        return metadata.isEmpty ? nil : metadata
    }
}

private struct AuditEnvelopeSummary: Decodable {
    let ok: Bool
    let error: AutomationErrorResponse?
}
