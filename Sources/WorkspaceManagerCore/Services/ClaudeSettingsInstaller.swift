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
            }

            try writeJSON(current, to: url)
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
            return homeDirectory
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
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
        let a = (try? JSONSerialization.data(
            withJSONObject: Self.lower(lhs), options: [.sortedKeys])) ?? Data()
        let b = (try? JSONSerialization.data(
            withJSONObject: Self.lower(rhs), options: [.sortedKeys])) ?? Data()
        return a == b
    }
}

// MARK: - PR #1 contribution: workspaces.hooks

/// Build the contribution that registers our HTTP hook routes in `~/.claude/settings.json`.
/// `socketPath` is the Unix socket the running app is listening on.
public func workspacesHooksContribution(
    socketPath: String
) -> ClaudeSettingsContribution {
    // Per spec § Channel 1, point each interesting event at our /event route.
    // `http+unix://<encoded-socket>/event` is the de-facto convention used by Claude Code.
    let encodedSocket = socketPath.addingPercentEncoding(
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
                hooks[name] = arr
            }
            dict["hooks"] = AnyCodable(hooks)
            return dict
        },
        preview: { current in
            let hooks = (current["hooks"]?.value as? [String: Any]) ?? [:]
            var added: [String] = []
            for name in eventNames {
                let entries = (hooks[name] as? [[String: Any]]) ?? []
                let present = entries.contains { entry in
                    (entry["type"] as? String) == "http"
                        && (entry["url"] as? String) == endpoint
                }
                if !present { added.append(name) }
            }
            if added.isEmpty {
                return "no changes (already wired for \(eventNames.count) events → \(endpoint))"
            }
            return "add \(added.count) hook(s) → \(endpoint): \(added.joined(separator: ", "))"
        }
    )
}
