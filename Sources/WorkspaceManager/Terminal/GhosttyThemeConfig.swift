//
//  GhosttyThemeConfig.swift
//  WorkspaceManager
//

import Foundation

/// Generates and writes the app-owned Ghostty config file for embedded terminal
/// behavior. The file is isolated from the user's `~/.config/ghostty` and holds
/// only WorkSpaces-managed defaults such as terminal theme and scroll behavior.
///
/// String generation is pure so it can be unit-tested; file placement follows
/// the `WORKSPACES_DATA_DIR` convention, falling back to the app support dir.
enum GhosttyThemeConfig {
    static let configFileName = "workspaces.config"
    static let mouseScrollMultiplier = "precision:0.7,discrete:1"

    /// The value for Ghostty's `theme` key, or nil when neither slot is set.
    ///
    /// An unset slot is filled with the built-in fallback so the dual
    /// `light:…,dark:…` form stays valid — Ghostty rejects a single-sided pair
    /// such as `light:foo` with `error.InvalidValue`.
    static func themeValue(lightTheme: String, darkTheme: String) -> String? {
        let light = lightTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let dark = darkTheme.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(light.isEmpty && dark.isEmpty) else { return nil }
        let resolvedLight = light.isEmpty ? GhosttyThemeCatalog.defaultLightName : light
        let resolvedDark = dark.isEmpty ? GhosttyThemeCatalog.defaultDarkName : dark
        return "light:\(resolvedLight),dark:\(resolvedDark)"
    }

    /// The full contents of the app-owned config file.
    static func configContents(lightTheme: String, darkTheme: String) -> String {
        var lines = [
            "scrollbar = system",
            "mouse-scroll-multiplier = \(mouseScrollMultiplier)",
        ]
        if let value = themeValue(lightTheme: lightTheme, darkTheme: darkTheme) {
            lines.append("theme = \(value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `<dataDir>/ghostty/<configFileName>` — app-owned and isolated.
    static func configFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        try resolveDataDirectory(environment: environment, fileManager: fileManager)
            .appendingPathComponent("ghostty", isDirectory: true)
            .appendingPathComponent(configFileName, isDirectory: false)
    }

    /// Write the app-owned config file for the given pair.
    @discardableResult
    static func writeConfigFile(
        lightTheme: String,
        darkTheme: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = try configFileURL(environment: environment, fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = configContents(lightTheme: lightTheme, darkTheme: darkTheme)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func resolveDataDirectory(
        environment: [String: String],
        fileManager: FileManager
    ) throws -> URL {
        if let raw = environment["WORKSPACES_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        {
            let expanded = (raw as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }

        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("WorkspaceManager", isDirectory: true)
    }
}
