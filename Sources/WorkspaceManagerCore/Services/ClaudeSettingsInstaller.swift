//
//  ClaudeSettingsInstaller.swift
//  WorkspaceManagerCore
//
//  Non-destructive contributor-based installer for `~/.claude/settings.json` and
//  `~/.claude.json`. PR #1 registers a single contribution: `workspaces.hooks`,
//  which adds HTTP hook routes pointing at our Unix socket. PRs #2 and #3 will
//  add status-line and notification-channel contributions through the same API.
//
//  Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 1 ("Configuration").
//

import Foundation

/// A single registered contribution that mutates one of the Claude settings files.
public struct ClaudeSettingsContribution: Sendable {
    public enum Target: Sendable {
        case userSettingsJSON  // ~/.claude/settings.json
        case userClaudeJSON  // ~/.claude.json
    }

    public let id: String
    public let target: Target
    public let merge: @Sendable ([String: AnyCodable]) -> [String: AnyCodable]
    public let preview: @Sendable ([String: AnyCodable]) -> String

    public init(
        id: String,
        target: Target,
        merge: @escaping @Sendable ([String: AnyCodable]) -> [String: AnyCodable],
        preview: @escaping @Sendable ([String: AnyCodable]) -> String
    ) {
        self.id = id
        self.target = target
        self.merge = merge
        self.preview = preview
    }
}

/// Read/write surface for the installer. Views and tests depend on this protocol so
/// the live actor can be stubbed without subclassing or mocking SwiftUI bindings.
public protocol ClaudeSettingsInstalling: Sendable {
    func renderPreview() async throws -> String
    func install() async throws
    func isInstalled() async -> Bool
    func userSettingsURL() async -> URL
    func mostRecentBackupPath() async -> String?
    func userSettingsModificationDate() async -> Date?
}

public actor ClaudeSettingsInstaller: ClaudeSettingsInstalling {
    /// Maximum number of `*.workspaces-backup-*` files to retain per settings file.
    /// Older backups beyond this count are deleted on each `install()` call.
    public static let maxBackupsPerFile: Int = 5

    private let homeDirectory: URL
    private var contributions: [ClaudeSettingsContribution] = []
    private var lastBackupPath: String?

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public func register(_ contribution: ClaudeSettingsContribution) {
        contributions.append(contribution)
    }

    public func registeredIDs() -> [String] {
        contributions.map(\.id)
    }

    public func userSettingsURL() -> URL {
        pathFor(target: .userSettingsJSON)
    }

    public func mostRecentBackupPath() -> String? {
        lastBackupPath
    }

    public func userSettingsModificationDate() -> Date? {
        let url = pathFor(target: .userSettingsJSON)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Render a multi-line preview describing what `install()` would do per file.
    public func renderPreview() throws -> String {
        var lines: [String] = []
        for target in [ClaudeSettingsContribution.Target.userSettingsJSON, .userClaudeJSON] {
            let scopedContributions = contributions.filter { $0.target == target }
            guard !scopedContributions.isEmpty else { continue }
            let url = pathFor(target: target)
            let current = (try? readJSON(at: url)) ?? [:]
            lines.append("# \(url.path)")
            for c in scopedContributions {
                lines.append("- \(c.id): \(c.preview(current))")
            }
            lines.append("")
        }
        if lines.isEmpty { lines.append("(no contributions registered)") }
        return lines.joined(separator: "\n")
    }

    /// Apply all registered contributions. Backs up each settings file once before
    /// writing, and writes pretty-printed JSON. Non-destructive: untouched keys
    /// survive byte-for-byte at the JSON-value level.
    public func install() throws {
        for target in [ClaudeSettingsContribution.Target.userSettingsJSON, .userClaudeJSON] {
            let scopedContributions = contributions.filter { $0.target == target }
            guard !scopedContributions.isEmpty else { continue }

            let url = pathFor(target: target)
            try ensureParentExists(for: url)

            var current = (try? readJSON(at: url)) ?? [:]
            let originalDataIfPresent = try? Data(contentsOf: url)

            for c in scopedContributions {
                current = c.merge(current)
            }

            if let originalDataIfPresent {
                let backupURL = url.appendingPathExtension(
                    "workspaces-backup-\(Self.iso8601Timestamp())"
                )
                try originalDataIfPresent.write(to: backupURL)
                if target == .userSettingsJSON {
                    lastBackupPath = backupURL.path
                }
                rotateBackups(forSettingsFile: url)
            }

            try writeJSON(current, to: url)
        }
    }

    /// Trim the per-file backup set to `maxBackupsPerFile`, keeping the newest
    /// entries by mtime. Lives at the file-IO layer (the merge algorithm is
    /// untouched). Errors here are non-fatal — a missing parent or permission
    /// failure just leaves stale backups in place.
    private func rotateBackups(forSettingsFile url: URL) {
        let parent = url.deletingLastPathComponent()
        let baseName = url.lastPathComponent
        let prefix = "\(baseName).workspaces-backup-"
        // Don't skip hidden files: backups for `~/.claude.json` (note the dot)
        // are themselves dot-prefixed, so `.skipsHiddenFiles` would exclude them
        // and rotation would silently no-op for that file.
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )) ?? []
        let backups =
            entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .map { url -> (URL, Date) in
                let date =
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }  // newest first

        guard backups.count > Self.maxBackupsPerFile else { return }
        for (oldBackup, _) in backups.dropFirst(Self.maxBackupsPerFile) {
            try? FileManager.default.removeItem(at: oldBackup)
        }
    }

    public func isInstalled() -> Bool {
        // Approximate: declare installed if every userSettingsJSON contribution's
        // diff text is empty for the current state. The contributor is the source
        // of truth for "matches expected".
        for c in contributions {
            let url = pathFor(target: c.target)
            let current = (try? readJSON(at: url)) ?? [:]
            let merged = c.merge(current)
            if !areJSONEqual(current, merged) { return false }
        }
        return !contributions.isEmpty
    }

    // MARK: - Filesystem helpers

    private func pathFor(target: ClaudeSettingsContribution.Target) -> URL {
        switch target {
        case .userSettingsJSON:
            return
                homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json")
        case .userClaudeJSON:
            return homeDirectory.appendingPathComponent(".claude.json")
        }
    }

    private func ensureParentExists(for url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
    }

    private func readJSON(at url: URL) throws -> [String: AnyCodable] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Self.lift(json)
    }

    private func writeJSON(_ dict: [String: AnyCodable], to url: URL) throws {
        let raw = Self.lower(dict)
        let data = try JSONSerialization.data(
            withJSONObject: raw,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
    }

    private static func iso8601Timestamp() -> String {
        // Millisecond resolution so back-to-back installs produce distinct
        // backup filenames; the rotation logic then sorts by mtime.
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime, .withColonSeparatorInTime, .withFractionalSeconds,
        ]
        return formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    static func lift(_ raw: [String: Any]) -> [String: AnyCodable] {
        var out: [String: AnyCodable] = [:]
        for (k, v) in raw { out[k] = AnyCodable(v) }
        return out
    }

    static func lower(_ dict: [String: AnyCodable]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out[k] = v.value }
        return out
    }

    private func areJSONEqual(_ lhs: [String: AnyCodable], _ rhs: [String: AnyCodable]) -> Bool {
        let a =
            (try? JSONSerialization.data(
                withJSONObject: Self.lower(lhs), options: [.sortedKeys])) ?? Data()
        let b =
            (try? JSONSerialization.data(
                withJSONObject: Self.lower(rhs), options: [.sortedKeys])) ?? Data()
        return a == b
    }
}

// MARK: - PR #1 contribution: workspaces.hooks

/// Build the contribution that registers our HTTP hook routes in `~/.claude/settings.json`.
/// `socketPath` is the Unix socket the running app is listening on. When
/// `titleEmitScriptPath` is non-nil the contribution also registers a
/// `UserPromptSubmit`/`Stop` command hook that emits OSC 2 — the Channel 3 path
/// that updates the embedded terminal's tab title without app-side polling.
public func workspacesHooksContribution(
    socketPath: String,
    titleEmitScriptPath: String? = nil
) -> ClaudeSettingsContribution {
    // Per spec § Channel 1, point each interesting event at our /event route.
    // `http+unix://<encoded-socket>/event` is the de-facto convention used by Claude Code.
    let encodedSocket =
        socketPath.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) ?? socketPath
    let endpoint = "http+unix://\(encodedSocket)/event"

    let eventNames: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolBatch",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "Stop",
        "StopFailure",
        "WorktreeCreate",
        "WorktreeRemove",
        "TaskCreated",
        "TaskCompleted",
    ]

    // Channel 3: a small set of events also gets a `command` hook that runs the
    // bundled `title-emit.sh` so the embedded terminal's tab title tracks the
    // agent's lifecycle (prompt submitted → "thinking", stop → "ready").
    let titleEmitEvents: Set<String> = ["UserPromptSubmit", "Stop"]

    return ClaudeSettingsContribution(
        id: "workspaces.hooks",
        target: .userSettingsJSON,
        merge: { current in
            var dict = current
            // Settings layout:
            //   { "hooks": { "<EventName>": [ { "type": "http", "url": "...", "async": true } ] } }
            // We deep-merge: existing handlers stay; ours are appended only if not already there.
            var hooks: [String: Any] =
                (current["hooks"]?.value as? [String: Any]) ?? [:]
            for name in eventNames {
                var arr = (hooks[name] as? [[String: Any]]) ?? []
                let alreadyPresent = arr.contains { entry in
                    (entry["type"] as? String) == "http"
                        && (entry["url"] as? String) == endpoint
                }
                if !alreadyPresent {
                    arr.append([
                        "type": "http",
                        "url": endpoint,
                        "async": true,
                    ])
                }
                if let scriptPath = titleEmitScriptPath, titleEmitEvents.contains(name) {
                    let cmdAlreadyPresent = arr.contains { entry in
                        (entry["type"] as? String) == "command"
                            && (entry["command"] as? String) == scriptPath
                    }
                    if !cmdAlreadyPresent {
                        arr.append([
                            "type": "command",
                            "command": scriptPath,
                            "async": true,
                        ])
                    }
                }
                hooks[name] = arr
            }
            dict["hooks"] = AnyCodable(hooks)
            return dict
        },
        preview: { current in
            let hooks = (current["hooks"]?.value as? [String: Any]) ?? [:]
            var addedHTTP: [String] = []
            var addedCommand: [String] = []
            for name in eventNames {
                let entries = (hooks[name] as? [[String: Any]]) ?? []
                let httpPresent = entries.contains { entry in
                    (entry["type"] as? String) == "http"
                        && (entry["url"] as? String) == endpoint
                }
                if !httpPresent { addedHTTP.append(name) }

                if let scriptPath = titleEmitScriptPath, titleEmitEvents.contains(name) {
                    let cmdPresent = entries.contains { entry in
                        (entry["type"] as? String) == "command"
                            && (entry["command"] as? String) == scriptPath
                    }
                    if !cmdPresent { addedCommand.append(name) }
                }
            }
            if addedHTTP.isEmpty && addedCommand.isEmpty {
                return "no changes (already wired for \(eventNames.count) events → \(endpoint))"
            }
            var parts: [String] = []
            if !addedHTTP.isEmpty {
                parts.append(
                    "add \(addedHTTP.count) http hook(s) → \(endpoint): \(addedHTTP.joined(separator: ", "))"
                )
            }
            if !addedCommand.isEmpty, let scriptPath = titleEmitScriptPath {
                parts.append(
                    "add \(addedCommand.count) command hook(s) → \(scriptPath): \(addedCommand.joined(separator: ", "))"
                )
            }
            return parts.joined(separator: "; ")
        }
    )
}

// MARK: - PR #3 contribution: workspaces.notifChannel

/// Pin Claude Code's notification channel to `iterm2` (OSC 9). The Ghostty
/// channel still has reliability bugs through 2026, so we route notifications
/// via the universally-supported OSC 9 path that libghostty already surfaces
/// as `GHOSTTY_ACTION_DESKTOP_NOTIFICATION`. Lives in `~/.claude.json` (the
/// per-user CLI preferences file), separate from `~/.claude/settings.json`.
public func workspacesNotifChannelContribution() -> ClaudeSettingsContribution {
    let preferredChannel = "iterm2"
    return ClaudeSettingsContribution(
        id: "workspaces.notifChannel",
        target: .userClaudeJSON,
        merge: { current in
            var dict = current
            dict["preferredNotifChannel"] = AnyCodable(preferredChannel)
            return dict
        },
        preview: { current in
            let existing = current["preferredNotifChannel"]?.value as? String
            if existing == preferredChannel {
                return "no changes (preferredNotifChannel already \"\(preferredChannel)\")"
            }
            if let existing {
                return "change preferredNotifChannel: \"\(existing)\" → \"\(preferredChannel)\""
            }
            return "set preferredNotifChannel: \"\(preferredChannel)\""
        }
    )
}
