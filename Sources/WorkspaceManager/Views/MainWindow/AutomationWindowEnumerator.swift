//
//  AutomationWindowEnumerator.swift
//  WorkspaceManager
//
//  Projects the app's live AppKit windows into the read-only descriptors the operator-scope
//  `GET /v1/windows` route returns. Lists on-screen, addressable windows only, keyed by the AppKit
//  window number — the stable identity `CGWindowList`/ScreenCaptureKit share, so the follow-on
//  `window.snapshot` slice can target the same window a caller listed here.
//

import AppKit
import WorkspaceManagerCore

enum AutomationWindowEnumerator {
    @MainActor
    static func descriptors(windows: [NSWindow]? = nil) -> [AutomationWindowDescriptor] {
        (windows ?? NSApp.windows).compactMap { window in
            // On-screen, real windows only. `windowNumber <= 0` is an off-screen/deferred window
            // with no capturable identity; an invisible window is not a listable surface.
            guard window.isVisible, window.windowNumber > 0 else { return nil }
            let frame = window.frame
            return AutomationWindowDescriptor(
                windowID: String(window.windowNumber),
                title: window.title,
                subtitle: window.subtitle.isEmpty ? nil : window.subtitle,
                isMain: window.isMainWindow,
                isKey: window.isKeyWindow,
                isVisible: window.isVisible,
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )
        }
    }
}
