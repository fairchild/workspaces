//
//  GhosttyRuntimeConfigFactory.swift
//  WorkspaceManager
//

import Foundation
import GhosttyKit

enum GhosttyRuntimeConfigFactory {
    static func make(userdata: UnsafeMutableRawPointer?) -> ghostty_runtime_config_s {
        ghostty_runtime_config_s(
            userdata: userdata,
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                GhosttyAppManager.wakeup(userdata)
            },
            action_cb: { app, target, action in
                guard let app else { return false }
                return GhosttyAppManager.action(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyClipboardBridge.read(userdata: userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, _, state, _ in
                GhosttyClipboardBridge.confirmRead(userdata: userdata, state: state)
            },
            write_clipboard_cb: { userdata, location, content, len, _ in
                GhosttyClipboardBridge.write(userdata: userdata, location: location, content: content, len: len)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyAppManager.closeSurface(userdata, processAlive: processAlive)
            }
        )
    }
}
