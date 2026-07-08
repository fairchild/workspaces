//
//  WindowSnapshotService.swift
//  WorkspaceManager
//
//  Captures a composited PNG of one of the app's own windows for the operator-scope
//  `POST /v1/window/snapshot` route. The mechanism is `CGWindowListCreateImage` scoped to the
//  window's own AppKit window number — chosen by the #915 spike: TCC-free for own windows, full
//  composited fidelity (sidebar chrome *and* the GhosttyKit IOSurface terminal surface), captured
//  with the app backgrounded and no activation. The pixel work stops here; the outcome is handed to
//  the pure Core `WindowSnapshotEncoder`.
//
//  `CGWindowListCreateImage` is deprecated in macOS 14 but fully functional; ScreenCaptureKit is the
//  eventual migration target (it needs a Screen Recording grant even for own windows, so there is no
//  reason to pay that cost while this path works). The swap stays behind this service's interface.
//

import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import WorkspaceManagerCore

@MainActor
enum WindowSnapshotService {
    /// Snapshot the app-owned window named by `windowID` (the AppKit window number a caller listed
    /// via `window.read`). Resolving against `NSApp.windows` is the security boundary: the operator
    /// can only capture windows the app owns, never an arbitrary system window. Never activates the
    /// app or reorders the window — a backgrounded, occluded window still yields its real
    /// last-composited content because WindowServer retains each window's IOSurface regardless of
    /// z-order.
    static func snapshot(windowID: String, windows: [NSWindow]? = nil) -> WindowSnapshotOutcome {
        guard let windowNumber = Int(windowID), windowNumber > 0 else {
            return .unknownWindow
        }
        // Own-window only: the requested id must belong to one of the app's visible, addressable
        // windows — the same set `window.read` lists. A window we don't own is `unknownWindow`, not
        // a capture we quietly attempt against a stranger's surface.
        guard
            (windows ?? NSApp.windows).contains(where: {
                $0.windowNumber == windowNumber && $0.isVisible
            })
        else {
            return .unknownWindow
        }

        guard let image = capture(windowNumber: CGWindowID(windowNumber)) else {
            // A nil image from a window we *do* own means it is not compositing right now:
            // off the active Space, minimized after listing, or a locked screen.
            return .notCapturable
        }
        guard image.width > 0, image.height > 0 else {
            return .notCapturable
        }
        guard let pngData = pngData(from: image) else {
            return .captureFailed("PNG encoding failed")
        }
        return .captured(pngData: pngData, width: image.width, height: image.height)
    }

    /// The single deprecated call, isolated so the ScreenCaptureKit migration touches one function.
    /// `boundsIgnoreFraming` trims the window's drop shadow to the real content bounds;
    /// `bestResolution` captures at the backing (Retina) scale rather than down-sampling.
    private static func capture(windowNumber: CGWindowID) -> CGImage? {
        CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowNumber,
            [.boundsIgnoreFraming, .bestResolution]
        )
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
