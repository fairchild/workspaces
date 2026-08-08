//
//  ArchivedWorkspaceSettings.swift
//  WorkspaceManager
//
//  Shared keys/defaults for the archived-workspace purge sweep, used by both the
//  Settings UI (`SettingsView`) and the startup purge pass (`ContentView`).
//

import Foundation
import WorkspaceManagerCore

enum ArchivedWorkspaceSettings {
    /// `UserDefaults`/`@AppStorage` key for the purge delay, in days.
    static let purgeDaysKey = "archivedWorkspacePurgeDays"

    /// Days an archived workspace is retained before the purge sweep deletes it.
    static let defaultPurgeDays = 30

    /// Resolves the configured delay, falling back to the default when unset (`0`).
    static func purgeDays(from defaults: UserDefaults = LaunchPreferences.defaults) -> Int {
        let stored = defaults.integer(forKey: purgeDaysKey)
        return stored > 0 ? stored : defaultPurgeDays
    }
}
