//
//  ClaudeSettingsInstallerTests.swift
//  WorkspaceManagerTests
//
//  Verifies the contributor-based installer is non-destructive: existing keys in
//  ~/.claude/settings.json survive byte-for-byte and a backup is created.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeSettingsInstaller")
struct ClaudeSettingsInstallerTests {

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-installer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Non-destructive merge preserves unrelated existing keys")
    func nonDestructiveMerge() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        let existing: [String: Any] = [
            "theme": "dark",
            "model": "claude-opus-4",
            "hooks": [
                "PreToolUse": [["type": "command", "command": "/usr/local/bin/myhook"]]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try data.write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(socketPath: "/tmp/hooks.sock"))
        try await installer.install()

        let updatedData = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: updatedData) as? [String: Any] ?? [:]

        #expect(updated["theme"] as? String == "dark")
        #expect(updated["model"] as? String == "claude-opus-4")

        let hooks = updated["hooks"] as? [String: Any] ?? [:]
        let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        // Original command hook plus our http hook.
        #expect(preToolUse.count == 2)
        #expect(preToolUse.contains { ($0["type"] as? String) == "command" })
        #expect(preToolUse.contains { ($0["type"] as? String) == "http" })

        // Our endpoint should be wired for all spec-listed events.
        let stop = hooks["Stop"] as? [[String: Any]] ?? []
        #expect(stop.contains { ($0["type"] as? String) == "http" })
    }

    @Test("Backup file is written before mutation")
    func backupOnInstall() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let originalData = try JSONSerialization.data(
            withJSONObject: ["theme": "system"], options: [.prettyPrinted]
        )
        try originalData.write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(socketPath: "/tmp/hooks.sock"))
        try await installer.install()

        let entries = try FileManager.default.contentsOfDirectory(at: claudeDir, includingPropertiesForKeys: nil)
        let backups = entries.filter {
            $0.lastPathComponent.hasPrefix("settings.json.workspaces-backup-")
        }
        #expect(backups.count == 1)

        let backupContents = try Data(contentsOf: backups[0])
        #expect(backupContents == originalData)
    }

    @Test("Re-install is idempotent (no duplicate hook entries)")
    func idempotentReinstall() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(socketPath: "/tmp/hooks.sock"))
        try await installer.install()
        try await installer.install()

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let data = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let hooks = updated["hooks"] as? [String: Any] ?? [:]
        let preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let httpEntries = preToolUse.filter { ($0["type"] as? String) == "http" }
        #expect(httpEntries.count == 1)
    }

    @Test("renderPreview describes pending changes")
    func renderPreviewDescribesChanges() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(socketPath: "/tmp/hooks.sock"))
        let preview = try await installer.renderPreview()
        #expect(preview.contains("workspaces.hooks"))
        #expect(preview.contains("Stop"))
    }

    @Test("isInstalled returns true after install")
    func isInstalledAfterInstall() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(socketPath: "/tmp/hooks.sock"))
        let beforeInstall = await installer.isInstalled()
        #expect(beforeInstall == false)
        try await installer.install()
        let afterInstall = await installer.isInstalled()
        #expect(afterInstall == true)
    }
}
