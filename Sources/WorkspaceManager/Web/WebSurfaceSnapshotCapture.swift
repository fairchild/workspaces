//
//  WebSurfaceSnapshotCapture.swift
//  WorkspaceManager
//
//  Captures a bounded PNG of a live `WKWebView` for the Automation API's browser-read
//  snapshot. Runs on the MainActor (WebKit requirement), scales output to a max width,
//  and races `takeSnapshot` against a deadline so a hung page cannot wedge the automation
//  server. The pixel work stops here; the outcome is handed to the pure Core encoder.
//

import AppKit
import WebKit
import WorkspaceManagerCore

@MainActor
enum WebSurfaceSnapshotCapture {
    /// Snapshot `webView`'s currently-rendered viewport as PNG, scaled to at most
    /// `maxWidth` points. Returns `.timedOut` if `takeSnapshot` does not complete within
    /// `timeoutSeconds`, `.captureFailed` on an encode/WebKit error, else `.captured`.
    ///
    /// The timeout is a hard return, not a structured race: a single-resume settler wins
    /// on whichever of the deadline or the snapshot completion fires first, so a snapshot
    /// callback that never arrives cannot keep this call (or the automation server) blocked.
    static func capture(
        _ webView: WKWebView,
        maxWidth: Int = AutomationAPI.webSnapshotMaxWidth,
        timeoutSeconds: Double = AutomationAPI.webSnapshotTimeoutSeconds
    ) async -> WebSnapshotOutcome {
        let config = WKSnapshotConfiguration()
        // rect stays .null → the view's visible bounds (viewport), not the full scroll height.
        let boundsWidth = webView.bounds.width
        let targetWidth = boundsWidth > 0 ? min(boundsWidth, CGFloat(maxWidth)) : CGFloat(maxWidth)
        config.snapshotWidth = NSNumber(value: Double(targetWidth))

        let settler = SnapshotSettler()
        return await withCheckedContinuation { continuation in
            settler.attach(continuation)

            let deadline = DispatchWorkItem {
                // asyncAfter on .main runs on the main thread, so the MainActor is active.
                MainActor.assumeIsolated { settler.settle(.timedOut) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)

            webView.takeSnapshot(with: config) { image, error in
                // WebKit delivers this completion on the main thread.
                MainActor.assumeIsolated {
                    deadline.cancel()
                    settler.settle(outcome(image: image, error: error))
                }
            }
        }
    }

    private static func outcome(image: NSImage?, error: Error?) -> WebSnapshotOutcome {
        if let error {
            return .captureFailed("\(error)")
        }
        guard let image, let (png, width, height) = pngData(from: image) else {
            return .captureFailed("no image produced")
        }
        return .captured(pngData: png, width: width, height: height)
    }

    /// PNG bytes plus the bitmap's pixel dimensions, or `nil` when the image has no
    /// rasterizable representation.
    private static func pngData(from image: NSImage) -> (Data, Int, Int)? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            return nil
        }
        return (png, rep.pixelsWide, rep.pixelsHigh)
    }
}

/// Single-resume guard around the snapshot continuation. MainActor-isolated so the
/// deadline and the WebKit completion (both on the main thread) settle it without a
/// data race; the loser's `settle` is a no-op.
@MainActor
private final class SnapshotSettler {
    private var continuation: CheckedContinuation<WebSnapshotOutcome, Never>?

    func attach(_ continuation: CheckedContinuation<WebSnapshotOutcome, Never>) {
        self.continuation = continuation
    }

    func settle(_ outcome: WebSnapshotOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: outcome)
    }
}
