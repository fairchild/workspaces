//
//  GhosttyThemePersistence.swift
//  WorkspaceManager
//

import Foundation
import WorkspaceManagerCore

/// UserDefaults-backed storage of the selected light/dark Terminal Theme pair.
///
/// Pure read/write helpers so `GhosttyThemeStore` (the observable both entry
/// points bind to) and `GhosttyAppManager` (which builds the initial config at
/// startup) share one source of truth without a dependency cycle. An empty
/// string means "no selection" for that slot.
enum GhosttyThemePersistence {
    static let lightThemeKey = "terminalThemeLight"
    static let darkThemeKey = "terminalThemeDark"
    static let recentsKey = "terminalThemeRecents"

    struct Pair: Equatable, Sendable {
        var lightTheme: String
        var darkTheme: String

        static let empty = Pair(lightTheme: "", darkTheme: "")

        var hasSelection: Bool { !lightTheme.isEmpty || !darkTheme.isEmpty }
    }

    static func load(from defaults: UserDefaults = LaunchPreferences.defaults) -> Pair {
        Pair(
            lightTheme: defaults.string(forKey: lightThemeKey) ?? "",
            darkTheme: defaults.string(forKey: darkThemeKey) ?? ""
        )
    }

    static func save(_ pair: Pair, to defaults: UserDefaults = LaunchPreferences.defaults) {
        defaults.set(pair.lightTheme, forKey: lightThemeKey)
        defaults.set(pair.darkTheme, forKey: darkThemeKey)
    }

    /// Recently committed theme names, most-recent-first.
    static func loadRecents(from defaults: UserDefaults = LaunchPreferences.defaults) -> [String] {
        defaults.stringArray(forKey: recentsKey) ?? []
    }

    static func saveRecents(_ recents: [String], to defaults: UserDefaults = LaunchPreferences.defaults) {
        defaults.set(recents, forKey: recentsKey)
    }
}
