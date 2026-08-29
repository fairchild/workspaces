//
//  UIFixtureSelectedWorkspaceBootstrap.swift
//  WorkspaceManager
//
//  Names the workspace a fixture-mode launch selects, so a capture can stage the sidebar's
//  active card rather than depend on which seeded record happens to sort first. The
//  configuration type stays in every build because the launch wiring names it; only the
//  environment parser is debug-only, so no release binary can be steered by the environment.
//

import Foundation
import WorkspaceManagerCore

struct UIFixtureSelectedWorkspaceBootstrapConfiguration: Equatable, Sendable {
    /// The workspace name to select, as written in the environment.
    let workspaceName: String

    #if DEBUG
        static let workspaceNameKey = "WORKSPACES_UI_FIXTURE_SELECTED"

        static func from(environment: [String: String]) -> Self? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1" else { return nil }
            guard let rawValue = environment[workspaceNameKey] else { return nil }
            let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return Self(workspaceName: name)
        }
    #else
        static func from(environment: [String: String]) -> Self? { nil }
    #endif

    /// The seeded workspace this configuration names, matched case-insensitively the way the
    /// seeder resolves the names its own lists carry. Archived workspaces are skipped:
    /// selecting one lands on its repo overview, which is not the row a capture is after.
    func workspace(in repos: [Repo]) -> Workspace? {
        repos
            .flatMap(\.workspaces)
            .first {
                $0.status != .archived
                    && $0.name.caseInsensitiveCompare(workspaceName) == .orderedSame
            }
    }
}
