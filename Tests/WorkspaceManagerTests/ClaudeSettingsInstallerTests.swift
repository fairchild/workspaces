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

    private func hookGroups(
        named event: String,
        in updated: [String: Any]
    ) -> [[String: Any]] {
        let hooks = updated["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private func hookHandlers(in group: [String: Any]) -> [[String: Any]] {
        (group["hooks"] as? [[String: Any]]) ?? []
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
        await installer.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        try await installer.install()

        let updatedData = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: updatedData) as? [String: Any] ?? [:]

        #expect(updated["theme"] as? String == "dark")
        #expect(updated["model"] as? String == "claude-opus-4")

        let preToolUse = hookGroups(named: "PreToolUse", in: updated)
        // Original user command hook is preserved and normalized; our event-forwarder
        // command hook is added as a second matcherless group.
        #expect(preToolUse.count == 2)
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
                        && ($0["command"] as? String) == "/tmp/event-forwarder.sh"
                }
            })

        // Our event-forwarder should be wired for every spec-listed event.
        let stop = hookGroups(named: "Stop", in: updated)
        #expect(
            stop.contains {
                hookHandlers(in: $0).contains {
                    ($0["type"] as? String) == "command"
                        && ($0["command"] as? String) == "/tmp/event-forwarder.sh"
                }
            })

        // No `type: "http"` handlers anywhere — the http+unix:// scheme is broken in
        // real Claude and must never be written by this installer again.
        let allHookGroups = (updated["hooks"] as? [String: Any] ?? [:])
            .values.flatMap { $0 as? [[String: Any]] ?? [] }
        let anyHTTP = allHookGroups.contains { group in
            hookHandlers(in: group).contains { ($0["type"] as? String) == "http" }
        }
        #expect(anyHTTP == false)
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
        await installer.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
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
        await installer.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        try await installer.install()
        try await installer.install()

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let data = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let preToolUse = hookGroups(named: "PreToolUse", in: updated)
        let eventForwarderEntries = preToolUse.flatMap { group in
            hookHandlers(in: group).filter {
                ($0["type"] as? String) == "command"
                    && ($0["command"] as? String) == "/tmp/event-forwarder.sh"
            }
        }
        #expect(eventForwarderEntries.count == 1)
    }

    @Test("Re-install scrubs legacy http+unix:// hook entries from previous installer versions")
    func reinstallScrubsLegacyHTTPUnixEntries() async throws {
        // Background: PR #443's installer wrote `type: "http"` handlers with
        // `http+unix://...` URLs. Real Claude Code does not speak that URL scheme,
        // so every hook errored with `Unsupported protocol http+unix:`. The
        // current installer self-heals by removing those handlers on every run.
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        let existing: [String: Any] = [
            "hooks": [
                "Notification": [
                    [
                        "type": "http",
                        "url": "http+unix://legacy-pid-1234/event",
                        "async": true,
                    ],
                    [
                        "type": "http",
                        "url": "http+unix://legacy-pid-5678/event",
                        "async": true,
                    ],
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try data.write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(
            workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        try await installer.install()

        let updatedData = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: updatedData) as? [String: Any] ?? [:]
        let notification = hookGroups(named: "Notification", in: updated)

        // Legacy http+unix:// entries are gone.
        let anyLegacy = notification.contains { group in
            hookHandlers(in: group).contains {
                ($0["type"] as? String) == "http"
                    && ((($0["url"] as? String) ?? "").hasPrefix("http+unix://"))
            }
        }
        #expect(anyLegacy == false)

        // Our event-forwarder command hook is wired in.
        let hasEventForwarder = notification.contains { group in
            hookHandlers(in: group).contains {
                ($0["type"] as? String) == "command"
                    && ($0["command"] as? String) == "/tmp/event-forwarder.sh"
            }
        }
        #expect(hasEventForwarder)
    }

    @Test("renderPreview describes pending changes")
    func renderPreviewDescribesChanges() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        let preview = try await installer.renderPreview()
        #expect(preview.contains("workspaces.hooks"))
        #expect(preview.contains("Stop"))
    }

    @Test("isInstalled returns true after install")
    func isInstalledAfterInstall() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        let beforeInstall = await installer.isInstalled()
        #expect(beforeInstall == false)
        try await installer.install()
        let afterInstall = await installer.isInstalled()
        #expect(afterInstall == true)
    }

    @Test("statusLine contribution writes the spec-shaped block")
    func statusLineContributionWritesBlock() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(
            workspacesStatusLineContribution(
                forwarderPath: "/tmp/statusline.sh", refreshInterval: 5000
            )
        )
        try await installer.install()

        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let data = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let block = updated["statusLine"] as? [String: Any] ?? [:]
        #expect(block["type"] as? String == "command")
        #expect(block["command"] as? String == "/tmp/statusline.sh")
        #expect(block["refreshInterval"] as? Int == 5000)
    }

    @Test("hooks + statusLine contributions merge cleanly into the same file")
    func hooksAndStatusLineMerge() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        let existing: [String: Any] = [
            "theme": "dark",
            "statusLine": [
                "type": "command",
                "command": "/old/statusline",
                // A field we don't recognize — must survive.
                "padding": 1,
            ],
        ]
        let original = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted])
        try original.write(to: settingsURL)

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(workspacesHooksContribution(eventForwarderScriptPath: "/tmp/event-forwarder.sh"))
        await installer.register(
            workspacesStatusLineContribution(forwarderPath: "/tmp/statusline.sh")
        )
        try await installer.install()

        let updatedData = try Data(contentsOf: settingsURL)
        let updated = try JSONSerialization.jsonObject(with: updatedData) as? [String: Any] ?? [:]

        // Theme survives.
        #expect(updated["theme"] as? String == "dark")

        // Event-forwarder command hooks wired up for all spec-listed events.
        let stop = hookGroups(named: "Stop", in: updated)
        #expect(
            stop.contains {
                hookHandlers(in: $0).contains {
                    ($0["type"] as? String) == "command"
                        && ($0["command"] as? String) == "/tmp/event-forwarder.sh"
                }
            })

        // statusLine block points at our forwarder; original `padding` field is
        // preserved — the merge replaces our owned keys but never strips others.
        let block = updated["statusLine"] as? [String: Any] ?? [:]
        #expect(block["command"] as? String == "/tmp/statusline.sh")
        #expect(block["refreshInterval"] as? Int == 5000)
        #expect(block["type"] as? String == "command")
        #expect(block["padding"] as? Int == 1)
    }

    @Test("statusLine re-install is idempotent")
    func statusLineIdempotent() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(
            workspacesStatusLineContribution(forwarderPath: "/tmp/statusline.sh")
        )
        try await installer.install()
        try await installer.install()

        let installed = await installer.isInstalled()
        #expect(installed == true)
    }

    @Test("statusLine renderPreview reflects pending changes")
    func statusLinePreviewWording() async throws {
        let home = makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let installer = ClaudeSettingsInstaller(homeDirectory: home)
        await installer.register(
            workspacesStatusLineContribution(forwarderPath: "/tmp/statusline.sh")
        )
        let preview = try await installer.renderPreview()
        #expect(preview.contains("workspaces.statusLine"))
        #expect(preview.contains("/tmp/statusline.sh"))
    }
}
