//
//  ClaudeSettingsInstallerTests.swift
//  WorkspaceManagerTests
//
//  Verifies the concrete installer is non-destructive and idempotent.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("ClaudeSettingsInstaller")
struct ClaudeSettingsInstallerTests {
    private let eventForwarder = "/tmp/event-forwarder.sh"
    private let statusline = "/tmp/statusline.sh"

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-installer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func installer(home: URL) -> ClaudeSettingsInstaller {
        ClaudeSettingsInstaller(
            homeDirectory: home,
            eventForwarderScriptPath: eventForwarder,
            statusLineForwarderPath: statusline
        )
    }

    private func hookGroups(named event: String, in updated: [String: Any]) -> [[String: Any]] {
        let hooks = updated["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private func hookHandlers(in group: [String: Any]) -> [[String: Any]] {
        (group["hooks"] as? [[String: Any]]) ?? []
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    @Test("Non-destructive merge preserves unrelated keys and user hooks")
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
            "statusLine": ["type": "command", "command": "/old/statusline", "padding": 1],
        ]
        try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
            .write(to: settingsURL)

        let installer = installer(home: home)
        try await installer.install()

        let updated = try readJSON(settingsURL)
        #expect(updated["theme"] as? String == "dark")
        #expect(updated["model"] as? String == "claude-opus-4")

        let preToolUse = hookGroups(named: "PreToolUse", in: updated)
        #expect(
            preToolUse.contains {
                hookHandlers(in: $0).contains {
                    ($0["type"] as? String) == "command"
                        && ($0["command"] as? String) == "/usr/local/bin/myhook"
                }
            })
        #expect(
            preToolUse.contains {
                hookHandlers(in: $0).contains {
                    ($0["type"] as? String) == "command"
                        && ($0["command"] as? String) == eventForwarder
                }
            })

        let stop = hookGroups(named: "Stop", in: updated)
        #expect(
            stop.contains {
                hookHandlers(in: $0).contains {
                    ($0["type"] as? String) == "command"
                        && ($0["command"] as? String) == eventForwarder
                }
            })

        let block = updated["statusLine"] as? [String: Any] ?? [:]
        #expect(block["type"] as? String == "command")
        #expect(block["command"] as? String == statusline)
        #expect(block["refreshInterval"] as? Int == 5000)
        #expect(block["padding"] as? Int == 1)
    }

    @Test("Install writes preferred notification channel")
    func notificationPreference() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = installer(home: home)
        try await installer.install()

        let claudeJSON = try readJSON(home.appendingPathComponent(".claude.json"))
        #expect(claudeJSON["preferredNotifChannel"] as? String == "iterm2")
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

        let installer = installer(home: home)
        try await installer.install()

        let backups = try FileManager.default.contentsOfDirectory(
            at: claudeDir,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("settings.json.workspaces-backup-") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == originalData)
    }

    @Test("Re-install is idempotent and does not churn backups")
    func idempotentReinstall() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try Data("{\"theme\":\"dark\"}".utf8).write(to: settingsURL)

        let installer = installer(home: home)
        try await installer.install()
        try await installer.install()
        try await installer.install()

        let updated = try readJSON(settingsURL)
        let preToolUse = hookGroups(named: "PreToolUse", in: updated)
        let eventForwarderEntries = preToolUse.flatMap { group in
            hookHandlers(in: group).filter {
                ($0["type"] as? String) == "command"
                    && ($0["command"] as? String) == eventForwarder
            }
        }
        #expect(eventForwarderEntries.count == 1)

        let backups = try FileManager.default.contentsOfDirectory(
            at: claudeDir,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("settings.json.workspaces-backup-") }
        #expect(backups.count == 1)
        #expect(await installer.isInstalled())
    }

    @Test("Re-install scrubs legacy WorkSpaces http+unix hooks only")
    func reinstallScrubsLegacyHTTPUnixEntries() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        let legacyURL =
            "http+unix://%2FUsers%2Ftest%2FLibrary%2FApplication%20Support%2Fcom.cloudcompute.workspaces%2Fhooks-1234.sock/event"
        let userURL = "http+unix://%2Ftmp%2Fmy-claude.sock/event"
        let existing: [String: Any] = [
            "hooks": [
                "Notification": [
                    ["type": "http", "url": legacyURL, "async": true],
                    ["type": "http", "url": userURL, "async": true],
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
            .write(to: settingsURL)

        let installer = installer(home: home)
        try await installer.install()

        let updated = try readJSON(settingsURL)
        let handlers = hookGroups(named: "Notification", in: updated)
            .flatMap { hookHandlers(in: $0) }
        #expect(handlers.contains { ($0["url"] as? String) == legacyURL } == false)
        #expect(handlers.contains { ($0["url"] as? String) == userURL })
        #expect(
            handlers.contains {
                ($0["type"] as? String) == "command"
                    && ($0["command"] as? String) == eventForwarder
            })
    }

    @Test("Install removes deprecated WorkSpaces title-emit hook")
    func removesTitleEmitHook() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        let titleEmit =
            "/Users/test/Library/Application Support/com.cloudcompute.workspaces/HookForwarders/title-emit.sh"
        let existing: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": titleEmit, "async": true]]]
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
            .write(to: settingsURL)

        let installer = installer(home: home)
        try await installer.install()

        let updated = try readJSON(settingsURL)
        let handlers = hookGroups(named: "Stop", in: updated).flatMap { hookHandlers(in: $0) }
        #expect(handlers.contains { ($0["command"] as? String) == titleEmit } == false)
        #expect(handlers.contains { ($0["command"] as? String) == eventForwarder })
    }

    @Test("renderPreview describes pending concrete changes")
    func renderPreviewDescribesChanges() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = installer(home: home)
        let preview = try await installer.renderPreview()
        #expect(preview.contains("add command hook"))
        #expect(preview.contains(eventForwarder))
        #expect(preview.contains("statusLine"))
        #expect(preview.contains("preferredNotifChannel"))
    }

    @Test("isInstalled returns true after install")
    func isInstalledAfterInstall() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = installer(home: home)
        #expect(await installer.isInstalled() == false)
        try await installer.install()
        #expect(await installer.isInstalled() == true)
    }
}
