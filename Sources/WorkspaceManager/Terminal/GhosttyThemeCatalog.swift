//
//  GhosttyThemeCatalog.swift
//  WorkspaceManager
//

import Foundation

/// A bundled Ghostty color theme. The file name *is* the value Ghostty accepts
/// for its `theme = ` config key, so `name` doubles as the stable identifier.
struct GhosttyTheme: Identifiable, Hashable, Sendable {
    let name: String
    var id: String { name }
}

/// Enumerates the iTerm2-derived themes Ghostty bundles under
/// `<resources>/ghostty/themes/`, with a curated **Featured** set pinned on top.
///
/// Pure and directory-injectable: enumeration takes an explicit directory so it
/// can be tested against a fixture without the app bundle. Ranking mirrors the
/// session switcher ranking philosophy (prefix > substring > other)
/// but sorts alphabetically within a tier, which reads better for a name list.
enum GhosttyThemeCatalog {
    /// Curated, ordered short list surfaced first in pickers. Only entries that
    /// exist on disk are shown, so this may name themes liberally — a missing
    /// name is silently skipped rather than rendered as a dead row.
    static let featuredNames: [String] = [
        "Catppuccin Mocha",
        "Catppuccin Latte",
        "Nord",
        "Dracula",
        "Gruvbox Dark",
        "Gruvbox Light",
        "tokyonight",
        "Solarized Dark Higher Contrast",
        "GitHub Dark",
        "Kanagawa Wave",
        "Nightfox",
        "Dayfox",
        "Ayu Light",
        "Snazzy",
    ]

    /// Built-in fallback used to fill an unspecified slot so the dual
    /// `light:…,dark:…` form stays valid (Ghostty rejects a single-sided pair).
    static let defaultLightName = "Builtin Light"
    static let defaultDarkName = "Builtin Dark"

    /// All themes found in `themesDirectory`, de-duplicated and sorted
    /// case-insensitively by name. Hidden/dot files are ignored.
    static func themes(
        in themesDirectory: URL,
        fileManager: FileManager = .default
    ) -> [GhosttyTheme] {
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: themesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let names = Set(
            entries
                .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
                .map { $0.lastPathComponent }
                .filter { !$0.isEmpty && !$0.hasPrefix(".") }
        )

        return
            names
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map(GhosttyTheme.init(name:))
    }

    /// The featured subset of `all`, in curated order, omitting any that are
    /// not actually present.
    static func featured(in all: [GhosttyTheme]) -> [GhosttyTheme] {
        let present = Set(all.map(\.name))
        return
            featuredNames
            .filter { present.contains($0) }
            .map(GhosttyTheme.init(name:))
    }

    /// Case-insensitive substring match against the theme name.
    static func matches(_ theme: GhosttyTheme, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return theme.name.localizedCaseInsensitiveContains(trimmed)
    }

    /// Filter `themes` by `query` and rank: title-prefix matches first, then
    /// substring matches, then any remaining matches; alphabetical within each
    /// tier. An empty query returns every theme alphabetically.
    static func rank(_ themes: [GhosttyTheme], query: String) -> [GhosttyTheme] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return themes }

        let lowerQuery = trimmed.lowercased()
        let scored: [(theme: GhosttyTheme, tier: Int)] = themes.compactMap { theme in
            let lowerName = theme.name.lowercased()
            guard lowerName.contains(lowerQuery) else { return nil }
            if lowerName.hasPrefix(lowerQuery) {
                return (theme, 0)
            }
            return (theme, 1)
        }

        return
            scored
            .sorted { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return lhs.theme.name.localizedCaseInsensitiveCompare(rhs.theme.name) == .orderedAscending
            }
            .map(\.theme)
    }

    /// Resolve `<resources>/ghostty/themes` using the same locator that feeds
    /// terminfo, so dev (env var) and release (bundled) share one resolution.
    static func resolvedThemesDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        GhosttyResourcesLocator.resolvedResourcesDirectory(
            existingEnvironmentValue: environment[GhosttyResourcesLocator.environmentVariableName],
            resourcesURL: bundle.resourceURL,
            fileManager: fileManager
        )?
        .appendingPathComponent("themes", isDirectory: true)
    }

    /// Convenience: all bundled themes resolved via `resolvedThemesDirectory`.
    /// Returns an empty list when resources are unavailable (e.g. a dev build
    /// launched without `GHOSTTY_RESOURCES_DIR`).
    static func bundledThemes(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> [GhosttyTheme] {
        guard
            let directory = resolvedThemesDirectory(
                environment: environment,
                bundle: bundle,
                fileManager: fileManager
            )
        else {
            return []
        }
        return themes(in: directory, fileManager: fileManager)
    }
}
