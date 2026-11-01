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
import WorkspaceManagerCore

enum RestoreLaunchCommand {
    /// `claude --resume <id>` — run as the restored surface's initial command. Claude brings
    /// back the conversation's model and permission mode on its own, but not its effort.
    static func claudeResume(sessionID: String, effort: String? = nil) -> String {
        guard let effort, AgentLaunchCommand.isKnownEffort(effort) else {
            return "claude --resume \(sessionID)"
        }
        return "claude --resume \(sessionID) --effort \(effort)"
    }

    /// The effort a conversation's last turn ran at, read from its transcript.
    static func lastEffort(agentSessionID: String, directory: URL) -> String? {
        ClaudeTranscriptResumability()
            .existingTranscriptURL(agentSessionID: agentSessionID, launchDirectory: directory.path)
            .flatMap { ClaudeTranscriptTurn.last(in: $0)?.effort }
    }
}
