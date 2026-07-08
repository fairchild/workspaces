//
//  WindowSnapshotEncoder.swift
//  WorkspaceManagerCore
//
//  Maps a window-snapshot attempt into the Automation API's `AutomationWindowSnapshotResult`
//  or a structured `AutomationServiceError`. Pure and AppKit-free: the MainActor capture
//  (a deprecated-but-functional `CGWindowList` call today, ScreenCaptureKit tomorrow) reduces
//  to a `WindowSnapshotOutcome`, and this type owns the byte-cap enforcement, base64 encoding,
//  and error mapping — so the failure contract (unknown window, not capturable, oversize) is
//  unit-testable without a live window or capture mechanism.
//

import Foundation

/// Result of trying to snapshot one of the app's windows. Failure is encoded as a case (rather
/// than thrown) so the MainActor capture stays non-throwing and the mapping to error codes lives
/// in one pure place — the same shape `WebSnapshotOutcome` uses for the browser-read lane.
public enum WindowSnapshotOutcome: Sendable, Equatable {
    /// No window the app owns has this id (unparseable id, or not one of `NSApp`'s windows).
    case unknownWindow
    /// The window exists but produced no capturable image — minimized, off the active Space, or
    /// a locked screen where WindowServer stops compositing a capturable framebuffer.
    case notCapturable
    /// The capture ran but produced no usable image (nil `CGImage`, encode failure, etc.).
    case captureFailed(String)
    /// A PNG capture with its pixel dimensions.
    case captured(pngData: Data, width: Int, height: Int)
}

public enum WindowSnapshotEncoder {
    /// Produces the success envelope payload, or throws the mapped automation error. `capabilities`
    /// are echoed into the system descriptor for discovery, matching the other operator routes.
    public static func result(
        from outcome: WindowSnapshotOutcome,
        windowID: String,
        maxRawBytes: Int = AutomationAPI.windowSnapshotMaxRawBytes,
        capabilities: [AutomationCapability]
    ) throws -> AutomationWindowSnapshotResult {
        switch outcome {
        case .unknownWindow:
            throw AutomationServiceError(
                .invalidRequest,
                "No WorkSpaces window has id \(windowID). List capturable windows with `window.read` first."
            )
        case .notCapturable:
            throw AutomationServiceError(
                .unsupported,
                "Window \(windowID) is not capturable right now; it must be realized on the active Space "
                    + "(minimized, hidden, or locked-screen windows do not composite)."
            )
        case .captureFailed(let reason):
            throw AutomationServiceError(
                .internalError,
                "Snapshot of window \(windowID) failed: \(reason)."
            )
        case .captured(let pngData, let width, let height):
            guard pngData.count <= maxRawBytes else {
                throw AutomationServiceError(
                    .unsupported,
                    "Snapshot of window \(windowID) is \(pngData.count) bytes, over the \(maxRawBytes)-byte cap."
                )
            }
            return AutomationWindowSnapshotResult(
                windowID: windowID,
                width: width,
                height: height,
                byteCount: pngData.count,
                data: pngData.base64EncodedString(),
                system: AutomationSystemDescriptor(capabilities: capabilities)
            )
        }
    }
}
