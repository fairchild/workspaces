//
//  WorkspaceClaudeActions.swift
//  WorkspaceManagerCore
//
//  Project-defined "quick actions" — one-shot `claude -p` runs invoked from
//  the sidebar context menu. Channel 5 of the agent integration spec.
//
//  Important: every quick action gets a fresh synthetic `hostSessionID`. We
//  do NOT share registry entries with the workspace's interactive Claude
//  session. The user's expectation is "this is a side errand"; mixing the
//  two would conflate the interactive session's run state with the action's.
//

import Foundation
import os.log

private let log = Logger(
    subsystem: "com.cloudcompute.workspaces",
    category: "WorkspaceClaudeActions"
)

/// Schema for `.workspaces/claude-actions.json`. Loaded lazily when the user
/// opens the workspace context menu, so changes are picked up without
/// restarting the app.
public struct ClaudeActionsConfig: Codable, Sendable, Equatable {
    public let actions: [ClaudeAction]
    public init(actions: [ClaudeAction]) { self.actions = actions }
}

public struct ClaudeAction: Codable, Sendable, Equatable, Identifiable {
    /// Stable identifier for the action; used as the `Identifiable` key. Falls
    /// back to a slug derived from `name` when not supplied.
    public var id: String { explicitID ?? slug(name) }
    public let name: String
    public let prompt: String
    public let allowedTools: [String]?
    public let resume: Bool?

    private let explicitID: String?

    public init(
        id: String? = nil,
        name: String,
        prompt: String,
        allowedTools: [String]? = nil,
        resume: Bool? = nil
    ) {
        self.explicitID = id
        self.name = name
        self.prompt = prompt
        self.allowedTools = allowedTools
        self.resume = resume
    }

    private enum CodingKeys: String, CodingKey {
        case explicitID = "id"
        case name
        case prompt
        case allowedTools
        case resume
    }
}

private func slug(_ name: String) -> String {
    let lowered = name.lowercased()
    let allowed = lowered.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
        return "-"
    }
    return String(allowed)
}

public enum WorkspaceClaudeActions {
    /// Load the action list for a given workspace. Returns `[]` when no
    /// `.workspaces/claude-actions.json` exists or the file is malformed
    /// (we log + skip).
    public static func loadActions(for workspaceDir: URL) -> [ClaudeAction] {
        let url =
            workspaceDir
            .appendingPathComponent(".workspaces", isDirectory: true)
            .appendingPathComponent("claude-actions.json")
        guard FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url)
        else {
            return []
        }
        do {
            return try JSONDecoder().decode(ClaudeActionsConfig.self, from: data).actions
        } catch {
            log.warning(
                "ignoring malformed claude-actions.json at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }
}
