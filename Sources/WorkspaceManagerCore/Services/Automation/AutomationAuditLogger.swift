import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "AutomationAuditLogger")

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
        public let surfaceID: String?
        public let requestedLines: Int?
        public let returnedLines: Int?
        /// True on follow-up entries appended when a completed mutation's response could not be
        /// written back (peer disconnected mid-request); the caller reconciles via a read verb.
        public let responseUndelivered: Bool?

        public init(
            timestamp: String,
            method: String,
            path: String,
            handlePresent: Bool,
            operatorHandle: Bool = false,
            allowed: Bool,
            errorCode: AutomationErrorCode?,
            metadata: [String: String]? = nil,
            surfaceID: String? = nil,
            requestedLines: Int? = nil,
            returnedLines: Int? = nil,
            responseUndelivered: Bool? = nil
        ) {
            self.timestamp = timestamp
            self.method = method
            self.path = path
            self.handlePresent = handlePresent
            self.operatorHandle = operatorHandle
            self.allowed = allowed
            self.errorCode = errorCode
            self.metadata = metadata
            self.surfaceID = surfaceID
            self.requestedLines = requestedLines
            self.returnedLines = returnedLines
            self.responseUndelivered = responseUndelivered
        }
    }

    private let auditURL: URL
    private let maxFileBytes: Int
    private let maxRotatedFiles: Int
    private let encoder = JSONEncoder()
    private let timestampFormatter = ISO8601DateFormatter()

    public init(auditURL: URL, maxFileBytes: Int = 5_242_880, maxRotatedFiles: Int = 2) {
        self.auditURL = auditURL
        self.maxFileBytes = maxFileBytes
        self.maxRotatedFiles = maxRotatedFiles
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
        let surfaceRead = surfaceReadAuditMetadata(
            path: path,
            requestBody: requestBody,
            responseBody: responseBody
        )
        let event = Event(
            timestamp: timestampFormatter.string(from: Date()),
            method: method,
            path: path,
            handlePresent: headers[AutomationAPI.handleHeader]?.isEmpty == false,
            operatorHandle: operatorHandle,
            allowed: summary?.ok == true,
            errorCode: summary?.error?.code,
            metadata: Self.routeMetadata(method: method, path: path, body: requestBody),
            surfaceID: surfaceRead?.surfaceID,
            requestedLines: surfaceRead?.requestedLines,
            returnedLines: surfaceRead?.returnedLines
        )
        append(event)
    }

    /// Appends a marker entry after a completed request whose response never reached the peer,
    /// so an agent that timed out or disconnected can tell its mutation landed.
    public func recordResponseUndelivered(
        method: String,
        path: String,
        handlePresent: Bool,
        operatorHandle: Bool
    ) {
        let event = Event(
            timestamp: timestampFormatter.string(from: Date()),
            method: method,
            path: path,
            handlePresent: handlePresent,
            operatorHandle: operatorHandle,
            allowed: true,
            errorCode: nil,
            responseUndelivered: true
        )
        append(event)
    }

    private func append(_ event: Event) {
        guard let data = try? encoder.encode(event) else { return }

        do {
            try FileManager.default.createDirectory(
                at: auditURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: auditURL.path) {
                try Data().write(to: auditURL)
            }
            let handle = try FileHandle(forWritingTo: auditURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
        } catch {
            log.error("[AutomationAudit] append failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Size-based rotation: once the active file reaches `maxFileBytes`, shift it to `.1`
    /// (existing `.N` files move up, the oldest beyond `maxRotatedFiles` is deleted) so the
    /// audit log cannot grow without bound.
    private func rotateIfNeeded() {
        guard
            let size = try? FileManager.default.attributesOfItem(atPath: auditURL.path)[.size] as? Int,
            size >= maxFileBytes
        else { return }

        let manager = FileManager.default
        try? manager.removeItem(atPath: rotatedPath(index: maxRotatedFiles))
        if maxRotatedFiles > 1 {
            for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
                let source = rotatedPath(index: index)
                guard manager.fileExists(atPath: source) else { continue }
                try? manager.moveItem(atPath: source, toPath: rotatedPath(index: index + 1))
            }
        }
        do {
            try manager.moveItem(atPath: auditURL.path, toPath: rotatedPath(index: 1))
        } catch {
            log.error("[AutomationAudit] rotation failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func rotatedPath(index: Int) -> String {
        "\(auditURL.path).\(index)"
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

    private nonisolated func surfaceReadAuditMetadata(
        path: String,
        requestBody: Data,
        responseBody: Data
    ) -> SurfaceReadAuditMetadata? {
        guard path == "/v1/surface/read" else { return nil }
        let request = try? AutomationJSON.decoder.decode(AutomationSurfaceReadRequest.self, from: requestBody)
        let response =
            try? AutomationJSON.decoder.decode(
                AutomationResponseEnvelope<AutomationSurfaceReadResult>.self,
                from: responseBody
            )
        return SurfaceReadAuditMetadata(
            surfaceID: response?.result?.surfaceID ?? request?.surfaceID,
            requestedLines: response?.result?.requestedLines ?? request?.lines,
            returnedLines: response?.result?.returnedLines
        )
    }
}

private struct AuditEnvelopeSummary: Decodable {
    let ok: Bool
    let error: AutomationErrorResponse?
}

private struct SurfaceReadAuditMetadata: Sendable, Equatable {
    let surfaceID: String?
    let requestedLines: Int?
    let returnedLines: Int?
}
