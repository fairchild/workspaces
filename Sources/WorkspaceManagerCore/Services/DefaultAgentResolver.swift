//
//  DefaultAgentResolver.swift
//  WorkspaceManagerCore
//
//  Resolves the agent command a workspace should auto-spawn after provision,
//  walking the precedence chain: workspace override → repo default → global
//  default. Centralized so callers (provisioners, terminal launchers, UI hints)
//  don't reimplement the walk.
//

import Foundation

public struct DefaultAgentResolver: Sendable {
    public init() {}

    /// Resolve the agent command for a workspace, walking the precedence chain:
    /// workspace override → repo default → global default → `nil`.
    ///
    /// Empty and whitespace-only strings are treated as unset at every tier, so
    /// a workspace can't accidentally suppress its repo/global default by
    /// holding an empty string. Non-empty values are trimmed before being
    /// returned.
    public func resolve(
        workspaceCommand: String?,
        repoCommand: String?,
        globalCommand: String?
    ) -> String? {
        Self.normalize(workspaceCommand)
            ?? Self.normalize(repoCommand)
            ?? Self.normalize(globalCommand)
    }

    private static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
