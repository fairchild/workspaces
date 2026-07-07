//
//  RestoreLaunchCommand.swift
//  WorkspaceManager
//
//  The agent command a restored surface runs during cold-start restore. It is
//  intentionally bare: SurfaceStore types it into the surface's normal login
//  shell over the automation text bridge (see
//  `SurfaceStore.deliverInitialCommandIfNeeded` for why it is not embedded in
//  the launch command), so `claude` resolves on the login PATH and, in tmux
//  mode, runs inside the deterministic session.
//

import Foundation

enum RestoreLaunchCommand {
    /// `claude --resume <id>` — run as the restored surface's initial command.
    static func claudeResume(sessionID: String) -> String {
        "claude --resume \(sessionID)"
    }
}
