//
//  ClaudeSettingsInstaller.swift
//  WorkspaceManagerCore
//
//  Concrete, non-destructive installer for WorkSpaces-owned Claude Code settings.
//  It patches two files:
//    - ~/.claude/settings.json: hook command forwarder and status-line command
//    - ~/.claude.json: preferred notification channel
//

import Foundation

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
    public static let defaultBundleIdentifier = "com.cloudcompute.workspaces"

    private enum Target: CaseIterable {
        case userSettingsJSON
        case userClaudeJSON
    }

    private static let hookEventNames: [String] = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "Stop",
        "StopFailure",
        "TaskCreated",
        "TaskCompleted",
    ]

    /// Events WorkSpaces used to subscribe to but no longer does. The installer
    /// scrubs its own forwarder from these on each pass; third-party handlers
    /// under the same event are left untouched. `PostToolBatch` duplicates
    /// `PostToolUse` (both settle the session on "thinking") and was 16% of
    /// bus traffic (#1347).
    private static let retiredHookEventNames: [String] = [
        "PostToolBatch"
    ]

    private let homeDirectory: URL
    private let eventForwarderScriptPath: String?
    private let statusLineForwarderPath: String?
    private let statusLineRefreshInterval: Int
    private let backupDirectory: URL
    private let preferredNotifChannel = "iterm2"
    private var lastBackupPath: String?

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        eventForwarderScriptPath: String? = nil,
        statusLineForwarderPath: String? = nil,
        statusLineRefreshInterval: Int = 5000,
        backupDirectory: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.eventForwarderScriptPath = eventForwarderScriptPath
        self.statusLineForwarderPath = statusLineForwarderPath
        self.statusLineRefreshInterval = statusLineRefreshInterval
        self.backupDirectory =
            backupDirectory
            ?? Self.defaultBackupDirectory(homeDirectory: homeDirectory)
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

    public func renderPreview() throws -> String {
        var lines: [String] = []

        let settingsURL = pathFor(target: .userSettingsJSON)
        let currentSettings = (try? readJSON(at: settingsURL)) ?? [:]
        let settingsPlan = planSettingsPatch(currentSettings)
        if !settingsPlan.lines.isEmpty {
            lines.append("# \(settingsURL.path)")
            lines.append(contentsOf: settingsPlan.lines.map { "- \($0)" })
            lines.append("")
        }

        let claudeURL = pathFor(target: .userClaudeJSON)
        let currentClaude = (try? readJSON(at: claudeURL)) ?? [:]
        let notifPlan = planNotificationPatch(currentClaude)
        lines.append("# \(claudeURL.path)")
        lines.append(contentsOf: notifPlan.lines.map { "- \($0)" })

        return lines.joined(separator: "\n")
    }

    /// Apply the concrete WorkSpaces patch. If a file is already byte-identical
    /// after merging, no write and no backup occurs.
    public func install() throws {
        for target in Target.allCases {
            let url = pathFor(target: target)
            try ensureParentExists(for: url)

            let current = (try? readJSON(at: url)) ?? [:]
            let originalData = try? Data(contentsOf: url)
            let next: [String: AnyCodable]
            switch target {
            case .userSettingsJSON:
                guard eventForwarderScriptPath != nil || statusLineForwarderPath != nil else {
                    continue
                }
                next = planSettingsPatch(current).merged
            case .userClaudeJSON:
                next = planNotificationPatch(current).merged
            }

            let mergedData = try JSONSerialization.data(
                withJSONObject: Self.lower(next),
                options: [.prettyPrinted, .sortedKeys]
            )

            if areJSONEqual(current, next) {
                continue
            }

            if let originalData, originalData == mergedData {
                continue
            }

            if let originalData {
                try FileManager.default.createDirectory(
                    at: backupDirectory,
                    withIntermediateDirectories: true
                )
                let backupURL = backupDirectory.appendingPathComponent(
                    "\(url.lastPathComponent).workspaces-backup-\(Self.iso8601Timestamp())"
                )
                try originalData.write(to: backupURL)
                if target == .userSettingsJSON {
                    lastBackupPath = backupURL.path
                }
                rotateBackups(forSettingsFile: url)
            }

            try mergedData.write(to: url)
        }
    }

    public func isInstalled() -> Bool {
        for target in Target.allCases {
            let url = pathFor(target: target)
            let current = (try? readJSON(at: url)) ?? [:]
            let merged: [String: AnyCodable]
            switch target {
            case .userSettingsJSON:
                guard eventForwarderScriptPath != nil || statusLineForwarderPath != nil else {
                    continue
                }
                merged = planSettingsPatch(current).merged
            case .userClaudeJSON:
                merged = planNotificationPatch(current).merged
            }
            if !areJSONEqual(current, merged) {
                return false
            }
        }
        return true
    }

    // MARK: - Patch planning

    private struct PatchPlan {
        var merged: [String: AnyCodable]
        var lines: [String]
    }

    private func planSettingsPatch(_ current: [String: AnyCodable]) -> PatchPlan {
        guard eventForwarderScriptPath != nil || statusLineForwarderPath != nil else {
            return PatchPlan(merged: current, lines: [])
        }

        var dict = current
        var lines: [String] = []
        var hooks = (current["hooks"]?.value as? [String: Any]) ?? [:]

        if let eventForwarderScriptPath {
            let eventForwarder = CommandContribution(
                rawPath: homeRelativeCommand(eventForwarderScriptPath)
            )
            var addedEvents: [String] = []
            var normalizedEvents: [String] = []
            var scrubbedLegacyEvents: [String] = []
            var scrubbedTitleEvents: [String] = []
            var scrubbedUnescapedForwarderEvents: [String] = []
            var scrubbedLegacyForwarderEvents: [String] = []

            for name in Self.hookEventNames {
                let rawEntries = (hooks[name] as? [Any]) ?? []
                if rawEntries.contains(where: {
                    guard let entry = $0 as? [String: Any] else { return false }
                    return entry["hooks"] == nil && isClaudeHookHandler(entry)
                }) {
                    normalizedEvents.append(name)
                }

                var groups = normalizedClaudeHookGroups(from: hooks[name])
                let legacyHTTPResult = scrubHandlers(in: groups, where: isWorkspacesLegacyHTTPUnixHook)
                groups = legacyHTTPResult.groups
                if legacyHTTPResult.removedCount > 0 { scrubbedLegacyEvents.append(name) }

                let titleEmitResult = scrubHandlers(in: groups, where: isWorkspacesTitleEmitHook)
                groups = titleEmitResult.groups
                if titleEmitResult.removedCount > 0 { scrubbedTitleEvents.append(name) }

                let unescapedForwarderResult = scrubHandlers(in: groups) { handler in
                    isUnescapedWorkspacesCommandHook(handler, contribution: eventForwarder)
                }
                groups = unescapedForwarderResult.groups
                if unescapedForwarderResult.removedCount > 0 {
                    scrubbedUnescapedForwarderEvents.append(name)
                }

                let legacyForwarderResult = scrubHandlers(in: groups) { handler in
                    isLegacyWorkspacesEventForwarderHook(handler, contribution: eventForwarder)
                }
                groups = legacyForwarderResult.groups
                if legacyForwarderResult.removedCount > 0 {
                    scrubbedLegacyForwarderEvents.append(name)
                }

                let eventForwarderPresent = groups.contains { group in
                    claudeGroupContainsHandler(group) { handler in
                        isCanonicalWorkspacesCommandHook(handler, contribution: eventForwarder)
                    }
                }

                if !eventForwarderPresent {
                    groups.append(["hooks": [[String: Any]]()])
                    let integrationGroupIndex = groups.index(before: groups.endIndex)
                    var integrationGroup = groups[integrationGroupIndex]
                    var integrationHandlers = claudeHookHandlers(in: integrationGroup)
                    integrationHandlers.append([
                        "type": "command",
                        "command": eventForwarder.command,
                        "async": true,
                    ])
                    integrationGroup["hooks"] = integrationHandlers
                    groups[integrationGroupIndex] = integrationGroup
                    addedEvents.append(name)
                }

                hooks[name] = groups
            }

            var scrubbedRetiredEvents: [String] = []
            for name in Self.retiredHookEventNames {
                guard hooks[name] != nil else { continue }
                let groups = normalizedClaudeHookGroups(from: hooks[name])
                let result = scrubHandlers(in: groups) { handler in
                    isWorkspacesLegacyHTTPUnixHook(handler)
                        || isWorkspacesTitleEmitHook(handler)
                        || isCanonicalWorkspacesCommandHook(handler, contribution: eventForwarder)
                        || isUnescapedWorkspacesCommandHook(handler, contribution: eventForwarder)
                        || isLegacyWorkspacesEventForwarderHook(handler, contribution: eventForwarder)
                }
                guard result.removedCount > 0 else { continue }
                scrubbedRetiredEvents.append(name)
                if result.groups.isEmpty {
                    hooks.removeValue(forKey: name)
                } else {
                    hooks[name] = result.groups
                }
            }

            if !scrubbedRetiredEvents.isEmpty {
                lines.append(
                    "unsubscribe WorkSpaces from retired events \(scrubbedRetiredEvents.joined(separator: ", "))"
                )
            }
            if !scrubbedLegacyEvents.isEmpty {
                lines.append(
                    "scrub legacy WorkSpaces http+unix hooks from \(scrubbedLegacyEvents.count) events"
                )
            }
            if !scrubbedTitleEvents.isEmpty {
                lines.append(
                    "remove deprecated title-emit hooks from \(scrubbedTitleEvents.count) events"
                )
            }
            if !scrubbedUnescapedForwarderEvents.isEmpty {
                lines.append(
                    "replace unescaped WorkSpaces event-forwarder command in \(scrubbedUnescapedForwarderEvents.count) events"
                )
            }
            if !scrubbedLegacyForwarderEvents.isEmpty {
                lines.append(
                    "replace machine-specific WorkSpaces event-forwarder path in \(scrubbedLegacyForwarderEvents.count) events"
                )
            }
            if !normalizedEvents.isEmpty {
                lines.append(
                    "normalize legacy hook group shape for \(normalizedEvents.joined(separator: ", "))"
                )
            }
            if !addedEvents.isEmpty {
                lines.append(
                    "add command hook for \(addedEvents.count) events using \(eventForwarder.command)"
                )
            }

        }

        if let statusLineForwarderPath {
            let statusLineCommand = CommandContribution(
                rawPath: homeRelativeCommand(statusLineForwarderPath)
            ).command
            var block = (current["statusLine"]?.value as? [String: Any]) ?? [:]
            let oldCommand = block["command"] as? String
            let oldInterval = block["refreshInterval"] as? Int
            block["type"] = "command"
            block["command"] = statusLineCommand
            block["refreshInterval"] = statusLineRefreshInterval
            dict["statusLine"] = AnyCodable(block)
            if oldCommand != statusLineCommand || oldInterval != statusLineRefreshInterval {
                lines.append(
                    "set statusLine command to \(statusLineCommand) every \(statusLineRefreshInterval)ms"
                )
            }
        }

        if eventForwarderScriptPath != nil {
            dict["hooks"] = AnyCodable(hooks)
        }

        if lines.isEmpty {
            lines.append("no settings.json changes")
        }
        return PatchPlan(merged: dict, lines: lines)
    }

    private func planNotificationPatch(_ current: [String: AnyCodable]) -> PatchPlan {
        var dict = current
        let existing = current["preferredNotifChannel"]?.value as? String
        dict["preferredNotifChannel"] = AnyCodable(preferredNotifChannel)
        if existing == preferredNotifChannel {
            return PatchPlan(merged: dict, lines: ["preferredNotifChannel already \(preferredNotifChannel)"])
        }
        if let existing {
            return PatchPlan(
                merged: dict,
                lines: ["change preferredNotifChannel from \(existing) to \(preferredNotifChannel)"]
            )
        }
        return PatchPlan(merged: dict, lines: ["set preferredNotifChannel to \(preferredNotifChannel)"])
    }

    // MARK: - Hook shape helpers

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

    private func countHandlers(
        in groups: [[String: Any]],
        where predicate: ([String: Any]) -> Bool
    ) -> Int {
        groups.reduce(0) { count, group in
            count + claudeHookHandlers(in: group).filter(predicate).count
        }
    }

    private func scrubHandlers(
        in groups: [[String: Any]],
        where shouldRemove: ([String: Any]) -> Bool
    ) -> (groups: [[String: Any]], removedCount: Int) {
        var removedCount = 0
        let scrubbedGroups = groups.compactMap { group -> [String: Any]? in
            var next = group
            let handlers = claudeHookHandlers(in: next)
            let kept = handlers.filter { !shouldRemove($0) }
            removedCount += handlers.count - kept.count
            if kept.isEmpty { return nil }
            next["hooks"] = kept
            return next
        }
        return (scrubbedGroups, removedCount)
    }

    private func isWorkspacesLegacyHTTPUnixHook(_ handler: [String: Any]) -> Bool {
        guard (handler["type"] as? String) == "http" else { return false }
        guard let raw = handler["url"] as? String, raw.hasPrefix("http+unix://") else { return false }
        let payload = String(raw.dropFirst("http+unix://".count))
        let decoded = payload.removingPercentEncoding ?? payload
        guard decoded.range(of: #"/hooks-\d+\.sock/event$"#, options: .regularExpression) != nil
        else {
            return false
        }
        return decoded.contains("/Application Support/")
    }

    private func isWorkspacesTitleEmitHook(_ handler: [String: Any]) -> Bool {
        guard (handler["type"] as? String) == "command" else { return false }
        guard let command = handler["command"] as? String else { return false }
        return command.hasSuffix("/HookForwarders/title-emit.sh")
            && command.contains("/Application Support/")
    }

    private func isCanonicalWorkspacesCommandHook(
        _ handler: [String: Any],
        contribution: CommandContribution
    ) -> Bool {
        guard (handler["type"] as? String) == "command" else { return false }
        guard let command = handler["command"] as? String else { return false }
        return command == contribution.command
    }

    private func isUnescapedWorkspacesCommandHook(
        _ handler: [String: Any],
        contribution: CommandContribution
    ) -> Bool {
        guard contribution.command != contribution.rawPath else { return false }
        guard (handler["type"] as? String) == "command" else { return false }
        guard let command = handler["command"] as? String else { return false }
        return command == contribution.rawPath
    }

    /// Recognizes a stale, machine-specific WorkSpaces event-forwarder command —
    /// any prior shape extracted to a `HookForwarders/` directory (an
    /// `Application Support` path, a `.build` bundle path, quoted or unquoted) —
    /// so it can be replaced with the canonical machine-agnostic tilde command.
    /// The canonical command is excluded so an already-installed entry is kept.
    private func isLegacyWorkspacesEventForwarderHook(
        _ handler: [String: Any],
        contribution: CommandContribution
    ) -> Bool {
        guard (handler["type"] as? String) == "command" else { return false }
        guard let command = handler["command"] as? String else { return false }
        guard command != contribution.command else { return false }
        let unquoted = unquoteSingleQuotedCommand(command)
        return unquoted.hasSuffix("/HookForwarders/event-forwarder.sh")
    }

    /// Strip a single layer of POSIX single quotes (and `'\''` escapes) so a
    /// quoted command path can be suffix-matched. Returns the input unchanged when
    /// it is not single-quoted.
    private func unquoteSingleQuotedCommand(_ command: String) -> String {
        guard command.count >= 2, command.hasPrefix("'"), command.hasSuffix("'") else {
            return command
        }
        let inner = command.dropFirst().dropLast()
        return inner.replacingOccurrences(of: "'\\''", with: "'")
    }

    /// Rewrite an absolute path under the installer's home directory to a
    /// `~/...` tilde path so the command written to `settings.json` is identical
    /// on every machine. Tilde expansion is not subject to field splitting, so the
    /// result stays unquoted even when the home directory contains a space. Paths
    /// outside the home directory are returned unchanged.
    private func homeRelativeCommand(_ absolutePath: String) -> String {
        let home = homeDirectory.standardizedFileURL.path
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        if absolutePath == normalizedHome { return "~" }
        let prefix = normalizedHome + "/"
        guard absolutePath.hasPrefix(prefix) else { return absolutePath }
        return "~/" + absolutePath.dropFirst(prefix.count)
    }

    private struct CommandContribution {
        let rawPath: String
        let command: String

        init(rawPath: String) {
            self.rawPath = rawPath
            command = ClaudeSettingsInstaller.shellEscapedCommand(rawPath)
        }
    }

    private static func shellEscapedCommand(_ raw: String) -> String {
        // `~` is in the safe set so a clean home-relative path
        // (`~/.local/share/workspaces/hook-forwarders/event-forwarder.sh`) stays
        // unquoted — quoting would defeat tilde expansion. A tilde path that also
        // contains a space or other unsafe scalar still falls through to quoting;
        // it cannot occur for the controlled extraction dir, but the guard holds.
        let safeScalars = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-~"
        )
        if raw.unicodeScalars.allSatisfy({ safeScalars.contains($0) }) {
            return raw
        }
        return "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Filesystem helpers

    private func pathFor(target: Target) -> URL {
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

    public nonisolated static func defaultBackupDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(defaultBundleIdentifier, isDirectory: true)
            .appendingPathComponent("ClaudeSettingsBackups", isDirectory: true)
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

    private func rotateBackups(forSettingsFile url: URL) {
        let baseName = url.lastPathComponent
        let prefix = "\(baseName).workspaces-backup-"
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: backupDirectory,
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
            .sorted { $0.1 > $1.1 }

        guard backups.count > Self.maxBackupsPerFile else { return }
        for (oldBackup, _) in backups.dropFirst(Self.maxBackupsPerFile) {
            try? FileManager.default.removeItem(at: oldBackup)
        }
    }

    private static func iso8601Timestamp() -> String {
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
