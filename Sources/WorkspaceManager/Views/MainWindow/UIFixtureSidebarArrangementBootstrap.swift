//
//  UIFixtureSidebarArrangementBootstrap.swift
//  WorkspaceManager
//
//  Pins the sidebar arrangement for a fixture-mode capture, overriding whatever the
//  stored preference holds. Debug-only, so no release build can be steered by the
//  environment.
//

import Foundation

enum UIFixtureSidebarArrangement {
    #if DEBUG
        static let arrangementEnvKey = "WORKSPACES_UI_FIXTURE_SIDEBAR_ARRANGEMENT"

        /// The forced arrangement, or nil outside fixture mode and for an unknown value
        /// (which leaves the stored preference in charge rather than failing the launch).
        static func mode(from environment: [String: String]) -> SidebarRepoSortMode? {
            guard environment["WORKSPACES_UI_FIXTURE"] == "1",
                let rawValue = environment[arrangementEnvKey]
            else { return nil }

            return SidebarRepoSortMode(rawValue: rawValue)
        }
    #else
        static func mode(from environment: [String: String]) -> SidebarRepoSortMode? { nil }
    #endif
}
