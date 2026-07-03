//
//  RestoreLaunchCommand.swift
//  WorkspaceManager
//
//  Builds the launch command that resumes a Claude Code conversation during
//  cold-start restore. It wraps `claude --resume <id>` in a `-L workspaces`
//  tmux session named deterministically from the cwd — matching how the app
//  launches every other terminal — so the resumed session reattaches like the
//  rest and survives a later app restart.
//

import Foundation
import WorkspaceManagerCore

enum RestoreLaunchCommand {
    /// `tmux -L <socket> new-session -A -s <name> -c <cwd> 'claude --resume <id>'`,
    /// with the same deterministic session name a normal launch would use for
    /// this directory, so `new-session -A` reattaches on a subsequent restore.
    static func claudeResume(
        cwd: URL,
        sessionID: String,
        socketLabel: String = TmuxSessionProbe.socketLabel
    ) -> String {
        let name = GhosttyTerminalConfig.tmuxSessionName(for: cwd)
        let inner = "claude --resume \(sessionID)"
        return "tmux -L \(quoted(socketLabel)) new-session -A -s \(quoted(name)) "
            + "-c \(quoted(cwd.path)) \(quoted(inner))"
    }

    private static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
