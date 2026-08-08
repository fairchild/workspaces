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
        /// True on best-effort follow-up entries appended when a response's delivery failed
        /// (peer disconnected or the write stalled); the marker carries that response's outcome
        /// (`allowed`/`errorCode`) so undelivered denials still read as denials.
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
        let outcome = Self.responseOutcome(from: responseBody)
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
            allowed: outcome.allowed,
            errorCode: outcome.errorCode,
            metadata: Self.routeMetadata(method: method, path: path, body: requestBody),
            surfaceID: surfaceRead?.surfaceID,
            requestedLines: surfaceRead?.requestedLines,
            returnedLines: surfaceRead?.returnedLines
        )
        var events = [event]
        // A completed archive teardown gets its own audit entry (distinct from the archive request's
        // event) so forced terminal teardown is independently visible and countable in the log.
        // Counts only — never session names or terminal content.
        if let teardown = archiveTeardownReport(method: method, path: path, responseBody: responseBody) {
            events.append(
                Event(
                    timestamp: timestampFormatter.string(from: Date()),
                    method: method,
                    path: "\(path)#teardown",
                    handlePresent: headers[AutomationAPI.handleHeader]?.isEmpty == false,
                    operatorHandle: operatorHandle,
                    allowed: true,
                    errorCode: nil,
                    metadata: [
                        "workspaceArchive.teardown.retiredSurfaceCount": "\(teardown.retiredSurfaceIDs.count)",
                        "workspaceArchive.teardown.killedTmuxSessionCount": "\(teardown.killedTmuxSessions.count)",
                    ]
                )
            )
        }

        for event in events {
            append(event)
        }
    }

    /// Derives the audit outcome (`allowed`/`errorCode`) from a response envelope body, the same
    /// classification `record` applies, so callers can carry an undelivered response's outcome.
    public nonisolated static func responseOutcome(
        from responseBody: Data
    ) -> (allowed: Bool, errorCode: AutomationErrorCode?) {
        let summary = try? AutomationJSON.decoder.decode(AuditEnvelopeSummary.self, from: responseBody)
        return (summary?.ok == true, summary?.error?.code)
    }

    /// Best-effort marker appended after any request whose response failed to deliver (peer
    /// disconnected or the write stalled). Carries that response's outcome verbatim so an agent
    /// that timed out can tell whether its request was allowed or denied before reconciling.
    public func recordResponseUndelivered(
        method: String,
        path: String,
        handlePresent: Bool,
        operatorHandle: Bool,
        allowed: Bool,
        errorCode: AutomationErrorCode?
    ) {
        let event = Event(
            timestamp: timestampFormatter.string(from: Date()),
            method: method,
            path: path,
            handlePresent: handlePresent,
            operatorHandle: operatorHandle,
            allowed: allowed,
            errorCode: errorCode,
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

    /// The archive response's teardown report, when this request was an archive whose forced
    /// teardown ran. Absent for non-archive routes, failed archives, and archives without teardown.
    private nonisolated func archiveTeardownReport(
        method: String,
        path: String,
        responseBody: Data
    ) -> AutomationWorkspaceArchiveTeardownReport? {
        guard method.uppercased() == "POST", path == "/v1/workspace/archive" else { return nil }
        let envelope = try? AutomationJSON.decoder.decode(
            AutomationResponseEnvelope<AutomationWorkspaceArchiveResult>.self,
            from: responseBody
        )
        return envelope?.result?.teardown
    }

    private nonisolated static func routeMetadata(method: String, path: String, body: Data) -> [String: String]? {
        guard method.uppercased() == "POST", !body.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return nil
        }

        var metadata: [String: String] = [:]
        if path == "/v1/workspace/create" {
            if object.keys.contains("select") {
                metadata["workspaceCreate.select"] = "provided"
            }
            if object.keys.contains("fromRef") {
                metadata["workspaceCreate.fromRef"] = "provided"
            }
        }
        if path == "/v1/workspace/archive", let teardown = object["teardownTerminals"] as? Bool {
            metadata["workspaceArchive.teardownTerminals"] = teardown ? "true" : "false"
        }
        // The wait condition is enum vocabulary, never content; the predicate (which can carry a
        // caller-authored pattern) is deliberately not recorded.
        if path == "/v1/wait", let condition = object["for"] as? String {
            metadata["wait.for"] = condition
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
