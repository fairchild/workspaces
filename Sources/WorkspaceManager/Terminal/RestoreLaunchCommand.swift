//
//  RestoreLaunchCommand.swift
//  WorkspaceManager
//
//  The agent command a restored surface runs as its initial process during
//  cold-start restore. It is intentionally bare: the directory-backed launch
//  path (GhosttyTerminalConfig) wraps it in the user's login shell — and, in
//  tmux mode, in a deterministic `-L workspaces` `new-session -A` — so `claude`
//  resolves on the login PATH and the session reattaches like any other surface
//  on a later restore.
//

import Foundation

enum RestoreLaunchCommand {
    /// `claude --resume <id>` — run as the restored surface's initial command.
    static func claudeResume(sessionID: String) -> String {
        "claude --resume \(sessionID)"
    }
}
