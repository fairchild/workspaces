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
    ///
    /// Routine-launch protection: if the merged result is byte-identical to the
    /// existing file, install() skips the write AND skips the backup. Without
    /// this, every silent reinstall on every app launch would churn the backup
    /// chain and rotate away the last meaningful pre-integration backup, even
    /// though nothing actually changed.
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

            // Serialize once — same options as writeJSON — so we can compare
            // the merged result against the file on disk without a second read.
            let mergedData = try JSONSerialization.data(
                withJSONObject: Self.lower(current),
                options: [.prettyPrinted, .sortedKeys]
            )

            if let originalDataIfPresent, originalDataIfPresent == mergedData {
                // Nothing to do; preserve the backup chain.
                continue
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

            try mergedData.write(to: url)
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

private func isClaudeHookHandler(_ entry: [String: Any]) -> Bool {
    entry["type"] is String
}

private func claudeHookHandlers(in group: [String: Any]) -> [[String: Any]] {
    if let nested = group["hooks"] as? [Any] {
        return nested.compactMap { $0 as? [String: Any] }
    }
    if isClaudeHookHandler(group) {
        return [group]
    }
    return []
}

private func normalizedClaudeHookGroups(from raw: Any?) -> [[String: Any]] {
    guard let entries = raw as? [Any] else { return [] }
    return entries.compactMap { item in
        guard let dict = item as? [String: Any] else { return nil }
        if dict["hooks"] != nil {
            var group = dict
            group["hooks"] = claudeHookHandlers(in: dict)
            return group
        }
        if isClaudeHookHandler(dict) {
            return ["hooks": [dict]]
        }
        return dict
    }
}

private func claudeGroupContainsHandler(
    _ group: [String: Any],
    matching predicate: ([String: Any]) -> Bool
) -> Bool {
    claudeHookHandlers(in: group).contains(where: predicate)
}

/// Build the contribution that registers our hook routes in `~/.claude/settings.json`.
/// `eventForwarderScriptPath` is the absolute path to the bundled `event-forwarder.sh`
/// shell. When `titleEmitScriptPath` is non-nil the contribution also registers a
/// `UserPromptSubmit`/`Stop` command hook that emits OSC 2 — the Channel 3 path
/// that updates the embedded terminal's tab title without app-side polling.
///
/// History: PR #443 wrote `type: "http"` handlers with `http+unix://<socket>/event`
/// URLs. Real Claude Code does not speak the `http+unix://` URL scheme; every hook
/// errored with `Unsupported protocol http+unix:`. This contribution replaces that
/// path with `type: "command"` handlers running a tiny shell forwarder that pipes
/// stdin through `curl --unix-socket`. Same pattern as `statusline.sh`. Legacy
/// `http+unix://` handlers are scrubbed from the user's settings on every install
/// so opted-in users self-heal.
public func workspacesHooksContribution(
    eventForwarderScriptPath: String,
    titleEmitScriptPath: String? = nil
) -> ClaudeSettingsContribution {
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

    /// Drop legacy `type: "http"` handlers whose URL points at *our* old
    /// pid-scoped socket path. PR #443's installer wrote these and they are
    /// non-functional in real Claude Code (which does not speak `http+unix://`),
    /// so we scrub them on every install. Crucially we do NOT scrub arbitrary
    /// `http+unix://` URLs — a user with their own Unix-socket Claude hook must
    /// keep it. The match is precise: percent-decoded URL must end in
    /// `hooks-<digits>.sock/event` AND contain `/Application Support/` (our
    /// install path under `~/Library/Application Support/<bundle-id>/`).
    @Sendable
    func looksLikeWorkspacesLegacyHookURL(_ raw: String?) -> Bool {
        guard let raw, raw.hasPrefix("http+unix://") else { return false }
        let payload = String(raw.dropFirst("http+unix://".count))
        let decoded = payload.removingPercentEncoding ?? payload
        guard decoded.range(of: #"/hooks-\d+\.sock/event$"#, options: .regularExpression) != nil
        else {
            return false
        }
        return decoded.contains("/Application Support/")
    }

    @Sendable
    func scrubLegacyHTTPUnix(in groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var g = group
            let kept = claudeHookHandlers(in: g).filter { handler in
                let isLegacy =
                    (handler["type"] as? String) == "http"
                    && looksLikeWorkspacesLegacyHookURL(handler["url"] as? String)
                return !isLegacy
            }
            if kept.isEmpty { return nil }
            g["hooks"] = kept
            return g
        }
    }

    return ClaudeSettingsContribution(
        id: "workspaces.hooks",
        target: .userSettingsJSON,
        merge: { current in
            var dict = current
            // Settings layout:
            //   { "hooks": { "<EventName>": [ { "matcher": "...", "hooks": [ ...handlers... ] } ] } }
            // We deep-merge matcher groups: existing groups stay; ours are added to a
            // matcherless group, and older raw top-level handler entries are normalized
            // into the current Claude Code shape on reinstall.
            var hooks: [String: Any] =
                (current["hooks"]?.value as? [String: Any]) ?? [:]
            for name in eventNames {
                var groups = normalizedClaudeHookGroups(from: hooks[name])

                // Self-heal: remove any non-functional `http+unix://` entries
                // left behind by PR #443's installer.
                groups = scrubLegacyHTTPUnix(in: groups)

                let eventForwarderPresent = groups.contains { group in
                    claudeGroupContainsHandler(group) { handler in
                        (handler["type"] as? String) == "command"
                            && (handler["command"] as? String) == eventForwarderScriptPath
                    }
                }

                let titleEmitPresent = groups.contains { group in
                    guard let scriptPath = titleEmitScriptPath else { return false }
                    return claudeGroupContainsHandler(group) { handler in
                        (handler["type"] as? String) == "command"
                            && (handler["command"] as? String) == scriptPath
                    }
                }

                let integrationGroupIndex =
                    groups.firstIndex { group in
                        claudeGroupContainsHandler(group) { handler in
                            (handler["type"] as? String) == "command"
                                && ((handler["command"] as? String) == eventForwarderScriptPath
                                    || (handler["command"] as? String) == titleEmitScriptPath)
                        }
                    }
                    ?? {
                        groups.append(["hooks": [[String: Any]]()])
                        return groups.index(before: groups.endIndex)
                    }()

                var integrationGroup = groups[integrationGroupIndex]
                var integrationHandlers = claudeHookHandlers(in: integrationGroup)

                if !eventForwarderPresent {
                    integrationHandlers.append([
                        "type": "command",
                        "command": eventForwarderScriptPath,
                        "async": true,
                    ])
                }
                if let scriptPath = titleEmitScriptPath,
                    titleEmitEvents.contains(name),
                    !titleEmitPresent
                {
                    integrationHandlers.append([
                        "type": "command",
                        "command": scriptPath,
                        "async": true,
                    ])
                }

                integrationGroup["hooks"] = integrationHandlers
                groups[integrationGroupIndex] = integrationGroup
                hooks[name] = groups
            }
            dict["hooks"] = AnyCodable(hooks)
            return dict
        },
        preview: { current in
            let hooks = (current["hooks"]?.value as? [String: Any]) ?? [:]
            var addedEventForwarder: [String] = []
            var addedTitleEmit: [String] = []
            var normalizedShape: [String] = []
            var legacyHTTPUnixToScrub: [String] = []
            for name in eventNames {
                let rawEntries = (hooks[name] as? [Any]) ?? []
                if rawEntries.contains(where: {
                    guard let entry = $0 as? [String: Any] else { return false }
                    return entry["hooks"] == nil && isClaudeHookHandler(entry)
                }) {
                    normalizedShape.append(name)
                }

                let groups = normalizedClaudeHookGroups(from: hooks[name])

                let legacyPresent = groups.contains { group in
                    claudeGroupContainsHandler(group) { handler in
                        (handler["type"] as? String) == "http"
                            && looksLikeWorkspacesLegacyHookURL(handler["url"] as? String)
                    }
                }
                if legacyPresent { legacyHTTPUnixToScrub.append(name) }

                let eventForwarderPresent = groups.contains { group in
                    claudeGroupContainsHandler(group) { handler in
                        (handler["type"] as? String) == "command"
                            && (handler["command"] as? String) == eventForwarderScriptPath
                    }
                }
                if !eventForwarderPresent { addedEventForwarder.append(name) }

                if let scriptPath = titleEmitScriptPath, titleEmitEvents.contains(name) {
                    let cmdPresent = groups.contains { group in
                        claudeGroupContainsHandler(group) { handler in
                            (handler["type"] as? String) == "command"
                                && (handler["command"] as? String) == scriptPath
                        }
                    }
                    if !cmdPresent { addedTitleEmit.append(name) }
                }
            }
            if addedEventForwarder.isEmpty && addedTitleEmit.isEmpty
                && normalizedShape.isEmpty && legacyHTTPUnixToScrub.isEmpty
            {
                return
                    "no changes (already wired for \(eventNames.count) events → \(eventForwarderScriptPath))"
            }
            var parts: [String] = []
            if !legacyHTTPUnixToScrub.isEmpty {
                parts.append(
                    "scrub \(legacyHTTPUnixToScrub.count) legacy http+unix:// hook(s): \(legacyHTTPUnixToScrub.joined(separator: ", "))"
                )
            }
            if !normalizedShape.isEmpty {
                parts.append(
                    "normalize legacy hook group shape for \(normalizedShape.joined(separator: ", "))"
                )
            }
            if !addedEventForwarder.isEmpty {
                parts.append(
                    "add \(addedEventForwarder.count) command hook(s) → \(eventForwarderScriptPath): \(addedEventForwarder.joined(separator: ", "))"
                )
            }
            if !addedTitleEmit.isEmpty, let scriptPath = titleEmitScriptPath {
                parts.append(
                    "add \(addedTitleEmit.count) title-emit command hook(s) → \(scriptPath): \(addedTitleEmit.joined(separator: ", "))"
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

// MARK: - PR #2 contribution: workspaces.statusLine

/// Build the contribution that registers the status-line forwarder in
/// `~/.claude/settings.json`. `forwarderPath` is the absolute path to the
/// `statusline.sh` script bundled with the running app. `refreshInterval` is in
/// milliseconds — Claude Code triggers an update on every conversation change
/// anyway, so this only governs the idle tick rate.
///
/// Spec: pasted_text_2026-05-03_22-18-10.txt § Channel 2.
public func workspacesStatusLineContribution(
    forwarderPath: String,
    refreshInterval: Int = 5000
) -> ClaudeSettingsContribution {
    return ClaudeSettingsContribution(
        id: "workspaces.statusLine",
        target: .userSettingsJSON,
        merge: { current in
            var dict = current
            // Settings layout:
            //   { "statusLine": { "type": "command", "command": "...", "refreshInterval": 5000 } }
            // We replace our own block in place but never remove pre-existing keys
            // we don't recognize on the same object (defensive: future Claude Code
            // versions may add fields to statusLine).
            var block: [String: Any] =
                (current["statusLine"]?.value as? [String: Any]) ?? [:]
            block["type"] = "command"
            block["command"] = forwarderPath
            block["refreshInterval"] = refreshInterval
            dict["statusLine"] = AnyCodable(block)
            return dict
        },
        preview: { current in
            let block = (current["statusLine"]?.value as? [String: Any]) ?? [:]
            let presentCommand = block["command"] as? String
            let presentInterval = block["refreshInterval"] as? Int
            if presentCommand == forwarderPath && presentInterval == refreshInterval {
                return "no changes (statusLine already wired → \(forwarderPath))"
            }
            return "set statusLine → command=\(forwarderPath), refreshInterval=\(refreshInterval)ms"
        }
    )
}
