import Foundation

public actor AutomationAuditLogger {
    public struct Event: Codable, Sendable, Equatable {
        public let timestamp: String
        public let method: String
        public let path: String
        public let handlePresent: Bool
        public let allowed: Bool
        public let errorCode: AutomationErrorCode?

        public init(
            timestamp: String,
            method: String,
            path: String,
            handlePresent: Bool,
            allowed: Bool,
            errorCode: AutomationErrorCode?
        ) {
            self.timestamp = timestamp
            self.method = method
            self.path = path
            self.handlePresent = handlePresent
            self.allowed = allowed
            self.errorCode = errorCode
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

    public func record(method: String, path: String, headers: [String: String], responseBody: Data) {
        let summary = (try? AutomationJSON.decoder.decode(AuditEnvelopeSummary.self, from: responseBody))
        let event = Event(
            timestamp: timestampFormatter.string(from: Date()),
            method: method,
            path: path,
            handlePresent: headers[AutomationAPI.handleHeader]?.isEmpty == false,
            allowed: summary?.ok == true,
            errorCode: summary?.error?.code
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
}

private struct AuditEnvelopeSummary: Decodable {
    let ok: Bool
    let error: AutomationErrorResponse?
}
