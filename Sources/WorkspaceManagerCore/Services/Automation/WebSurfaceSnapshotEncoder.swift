//
//  WebSurfaceSnapshotEncoder.swift
//  WorkspaceManagerCore
//
//  Maps a web-surface snapshot attempt into the Automation API's
//  `AutomationWebSurfaceSnapshotResult` or a structured `AutomationServiceError`.
//  Pure and WKWebView-free: the MainActor capture reduces to a `WebSnapshotOutcome`,
//  and this type owns the byte-cap enforcement, base64 encoding, and error mapping —
//  so the failure contract (unknown source, not live, timeout, oversize) is
//  unit-testable without a live view.
//

import Foundation

/// Result of trying to snapshot one web source's live surface. Failure is encoded as
/// a case (rather than thrown) so the MainActor capture stays non-throwing and the
/// mapping to error codes lives in one pure place.
public enum WebSnapshotOutcome: Sendable, Equatable {
    /// No WorkSpaces web source has this id.
    case unknownSource
    /// The source exists but has no instantiated `WKWebView` to snapshot.
    case notLive
    /// The capture did not complete within the deadline.
    case timedOut
    /// The capture completed but produced no usable image (encode failure, etc.).
    case captureFailed(String)
    /// A PNG capture with its pixel dimensions.
    case captured(pngData: Data, width: Int, height: Int)
}

public enum WebSurfaceSnapshotEncoder {
    /// Produces the success envelope payload, or throws the mapped automation error.
    /// `capabilities` are echoed into the system descriptor for discovery, matching the
    /// other browser-read routes.
    public static func result(
        from outcome: WebSnapshotOutcome,
        sourceID: UUID,
        maxRawBytes: Int = AutomationAPI.webSnapshotMaxRawBytes,
        capabilities: [AutomationCapability]
    ) throws -> AutomationWebSurfaceSnapshotResult {
        switch outcome {
        case .unknownSource:
            throw AutomationServiceError(
                .invalidRequest,
                "No WorkSpaces web surface has id \(sourceID.uuidString)."
            )
        case .notLive:
            throw AutomationServiceError(
                .unsupported,
                "Web surface \(sourceID.uuidString) has no live view to snapshot; open it in WorkSpaces first."
            )
        case .timedOut:
            throw AutomationServiceError(
                .unsupported,
                "Snapshot of web surface \(sourceID.uuidString) timed out after \(AutomationAPI.webSnapshotTimeoutSeconds)s."
            )
        case .captureFailed(let reason):
            throw AutomationServiceError(
                .internalError,
                "Snapshot of web surface \(sourceID.uuidString) failed: \(reason)."
            )
        case .captured(let pngData, let width, let height):
            guard pngData.count <= maxRawBytes else {
                throw AutomationServiceError(
                    .unsupported,
                    "Snapshot of web surface \(sourceID.uuidString) is \(pngData.count) bytes, over the \(maxRawBytes)-byte cap."
                )
            }
            return AutomationWebSurfaceSnapshotResult(
                sourceID: sourceID,
                width: width,
                height: height,
                byteCount: pngData.count,
                data: pngData.base64EncodedString(),
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        }
    }
}
