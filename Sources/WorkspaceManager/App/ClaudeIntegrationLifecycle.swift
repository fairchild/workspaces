//
//  ClaudeIntegrationLifecycle.swift
//  WorkspaceManager
//
//  Owns the runtime lifecycle of the Claude Code integration: hook listener over
//  a Unix domain socket plus the notification poster that observes the registry.
//  Hooked at app startup from `WorkspaceManagerApp.init`.
//

import AppKit
import Combine
import Foundation
import WorkspaceManagerCore

/// Shared keys for persisted opt-in state. The Settings UI toggle and the lifecycle's
/// silent reinstall path both read/write the same UserDefaults key so they stay in
/// sync across launches.
enum ClaudeIntegrationDefaults {
    /// `true` once the user has accepted the merge preview at least once. Drives the
    /// silent reinstall on subsequent launches so the hook routes always reflect the
    /// live (pid-scoped) socket path.
    static let optedInKey = "workspaces.claudeIntegration.optedIn"
}

@MainActor
final class ClaudeIntegrationLifecycle: ObservableObject {
    static let shared = ClaudeIntegrationLifecycle()

    private(set) var listener: AgentHookListener?
    private(set) var notificationPoster: AgentNotificationPoster?
    @Published private(set) var settingsInstaller: (any ClaudeSettingsInstalling)?
    private(set) var socketPath: String?
    private var teardownObserver: Any?
    private var didStart = false
    private var defaults: UserDefaults = .standard
    private var installerFactory: @Sendable (String) async -> any ClaudeSettingsInstalling = {
        _ in
        let installer = ClaudeSettingsInstaller()

        // Channel 1: requires the bundled event-forwarder shell. If extraction
        // fails (most tests, previews) we skip JUST this contribution so
        // Channels 2 and 3 still register cleanly.
        if let eventForwarderPath = ClaudeIntegrationLifecycle.extractEventForwarderScript() {
            let titleEmitPath = ClaudeIntegrationLifecycle.extractTitleEmitScript()
            await installer.register(
                workspacesHooksContribution(
                    eventForwarderScriptPath: eventForwarderPath,
                    titleEmitScriptPath: titleEmitPath
                )
            )
        } else {
            NSLog(
                "[ClaudeIntegration] event-forwarder.sh extraction failed; Channel 1 will be skipped this session (Channels 2 and 3 unaffected)"
            )
        }

        // Channel 3 channel-selection: writes preferredNotifChannel into ~/.claude.json.
        // Independent of Channel 1's script availability.
        await installer.register(workspacesNotifChannelContribution())

        // Channel 2: status-line forwarder. Independent of Channel 1's script.
        if let forwarderPath = ClaudeIntegrationLifecycle.bundledStatusLineForwarderPath() {
            await installer.register(
                workspacesStatusLineContribution(forwarderPath: forwarderPath)
            )
        } else {
            NSLog(
                "[ClaudeIntegration] statusline.sh not found in bundle; skipping Channel 2 contribution"
            )
        }
        return installer
    }

    /// Locate the Channel 2 status-line forwarder shell shipped alongside the app.
    /// The script is added to the SPM bundle via `Resources/HookForwarders` (see
    /// Package.swift). Returns nil if the bundle was assembled without it — caller
    /// logs and proceeds without registering Channel 2.
    nonisolated static func bundledStatusLineForwarderPath() -> String? {
        if let url = Bundle.module.url(
            forResource: "statusline",
            withExtension: "sh",
            subdirectory: "HookForwarders"
        ) {
            return url.path
        }
        if let url = Bundle.module.url(forResource: "statusline", withExtension: "sh") {
            return url.path
        }
        return nil
    }

    private init() {}

    /// Test seam: swap the UserDefaults instance and the installer construction so
    /// the silent-reinstall behaviour can be exercised without touching the user's
    /// real `~/.claude/settings.json`. Tests must reset state via `_resetForTesting`.
    func _configureForTesting(
        defaults: UserDefaults,
        installerFactory: @escaping @Sendable (String) async -> any ClaudeSettingsInstalling
    ) {
        self.defaults = defaults
        self.installerFactory = installerFactory
        self.didStart = false
        self.listener = nil
        self.notificationPoster = nil
        self.settingsInstaller = nil
        self.socketPath = nil
    }

    func start(registry: AgentSessionRegistry) {
        guard !didStart else { return }
        didStart = true

        let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
        let listener = AgentHookListener(bundleIdentifier: bundleID, registry: registry)
        self.listener = listener
        self.notificationPoster = AgentNotificationPoster(registry: registry)

        let optedIn = defaults.bool(forKey: ClaudeIntegrationDefaults.optedInKey)
        let installerFactory = self.installerFactory

        Task { @MainActor in
            let resolvedSocketPath = await listener.socketPath
            self.socketPath = resolvedSocketPath
            let installer = await installerFactory(resolvedSocketPath)
            self.settingsInstaller = installer

            // Defect 1: the pid-scoped socket path means a previously installed
            // settings.json points at a dead socket after every relaunch. When the
            // user has opted in, silently re-run install() so the routes always
            // reflect the live socket. install() is idempotent and backs up before
            // writing, so this is safe to run unconditionally on opted-in cold
            // starts.
            if optedIn {
                do {
                    try await installer.install()
                    let backup = await installer.mostRecentBackupPath() ?? "(no prior file)"
                    NSLog(
                        "[ClaudeIntegration] silent reinstall succeeded; backup=%@",
                        backup
                    )
                } catch {
                    NSLog(
                        "[ClaudeIntegration] silent reinstall failed: %@; channel 1 dormant for this session",
                        "\(error)"
                    )
                }
            }

            do {
                try await listener.start()
                NSLog("[ClaudeIntegration] hook listener started at %@", resolvedSocketPath)
            } catch {
                NSLog("[ClaudeIntegration] hook listener failed to start: %@", "\(error)")
            }
        }

        teardownObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.stop() }
        }
    }

    /// Copy the bundled `event-forwarder.sh` (Channel 1 hook event forwarder) to a
    /// stable location under Application Support and chmod it executable. Returns
    /// the destination path, or nil if extraction failed — the contribution then
    /// declines to register, and Channel 1 stays dormant for this session.
    nonisolated static func extractEventForwarderScript() -> String? {
        extractHookForwarderScript(named: "event-forwarder")
    }

    /// Copy the bundled `title-emit.sh` (Channel 3 hook forwarder) to a stable
    /// location under Application Support and chmod it executable. Returns the
    /// destination path, or nil if extraction failed — the contribution then
    /// degrades gracefully to event-forwarder-only hooks.
    nonisolated static func extractTitleEmitScript() -> String? {
        extractHookForwarderScript(named: "title-emit")
    }

    /// Generic helper used by both the event-forwarder and title-emit extractors:
    /// copies `<name>.sh` from the bundle's `HookForwarders/` resource directory
    /// to `~/Library/Application Support/<bundle-id>/HookForwarders/<name>.sh`,
    /// chmods it 0o755, returns the destination path. Nil on any failure.
    nonisolated private static func extractHookForwarderScript(named name: String) -> String? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let appSupport else { return nil }
        let dir =
            appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("HookForwarders", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let dest = dir.appendingPathComponent("\(name).sh")

        // Source: bundled .sh file. Falls back to nil silently — most tests
        // and previews don't run inside a real .app bundle.
        guard
            let bundleURL = Bundle.main.url(
                forResource: name,
                withExtension: "sh",
                subdirectory: "HookForwarders"
            )
        else {
            return nil
        }
        do {
            let contents = try Data(contentsOf: bundleURL)
            try contents.write(to: dest, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: dest.path
            )
            return dest.path
        } catch {
            return nil
        }
    }

    func stop() async {
        notificationPoster?.stop()
        notificationPoster = nil
        if let listener {
            await listener.stop()
        }
        listener = nil
        if let teardownObserver {
            NotificationCenter.default.removeObserver(teardownObserver)
            self.teardownObserver = nil
        }
        didStart = false
    }
}
