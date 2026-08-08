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
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "ClaudeIntegrationLifecycle")

/// Shared keys for persisted opt-in state. The Settings UI toggle and the lifecycle's
/// silent reinstall path both read/write the same UserDefaults key so they stay in
/// sync across launches.
enum ClaudeIntegrationDefaults {
    /// `true` once the user has accepted the merge preview at least once. Drives the
    /// silent settings repair on subsequent launches.
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
    private var defaults: UserDefaults = LaunchPreferences.defaults
    private var socketURLOverride: URL?
    private var installerFactory: @Sendable (String) async -> any ClaudeSettingsInstalling = {
        _ in
        let eventForwarderPath = ClaudeIntegrationLifecycle.extractEventForwarderScript()
        if eventForwarderPath == nil {
            log.error(
                "[ClaudeIntegration] event-forwarder.sh extraction failed; command hook forwarder will be skipped this session"
            )
        }

        let statusLinePath = ClaudeIntegrationLifecycle.extractStatusLineForwarderScript()
        if statusLinePath == nil {
            log.error(
                "[ClaudeIntegration] statusline.sh extraction failed; skipping status-line forwarder"
            )
        }

        return ClaudeSettingsInstaller(
            eventForwarderScriptPath: eventForwarderPath,
            statusLineForwarderPath: statusLinePath
        )
    }

    /// Locate the sourceable zsh command-status producer shipped alongside the app.
    /// Returns nil when the bundle was assembled without the producer resource.
    nonisolated static func bundledCommandStatusHookPath() -> String? {
        bundledHookForwarderURL(named: "command-status", fileExtension: "zsh")?.path
    }

    private init() {}

    /// Test seam: swap the UserDefaults instance and the installer construction so
    /// the silent-reinstall behaviour can be exercised without touching the user's
    /// real `~/.claude/settings.json`. `socketURLOverride` keeps the hook listener off
    /// the real, machine-wide `~/Library/Application Support/<bundleID>/hooks.sock` —
    /// without it, tests contend over the same `flock`-guarded socket as any real
    /// running app instance on the same machine. Call again to reconfigure; each call
    /// resets `didStart` so a fresh `start()` re-runs the lifecycle.
    func _configureForTesting(
        defaults: UserDefaults,
        installerFactory: @escaping @Sendable (String) async -> any ClaudeSettingsInstalling,
        socketURLOverride: URL? = nil
    ) {
        self.defaults = defaults
        self.installerFactory = installerFactory
        self.socketURLOverride = socketURLOverride
        self.didStart = false
        self.listener = nil
        self.notificationPoster = nil
        self.settingsInstaller = nil
        self.socketPath = nil
    }

    func start(registry: AgentSessionRegistry, commandStatusRegistry: LastCommandStatusRegistry? = nil) {
        guard !didStart else { return }
        didStart = true

        let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
        let listener = AgentHookListener(
            bundleIdentifier: bundleID,
            registry: registry,
            commandStatusRegistry: commandStatusRegistry,
            socketURLOverride: socketURLOverride
        )
        self.listener = listener
        self.socketPath = listener.socketPath
        self.notificationPoster = AgentNotificationPoster(registry: registry)

        let optedIn = defaults.bool(forKey: ClaudeIntegrationDefaults.optedInKey)
        let installerFactory = self.installerFactory

        Task { @MainActor in
            let resolvedSocketPath = listener.socketPath
            self.socketPath = resolvedSocketPath
            let installer = await installerFactory(resolvedSocketPath)
            self.settingsInstaller = installer

            do {
                try await listener.start()
                log.info("[ClaudeIntegration] hook listener started at \(resolvedSocketPath, privacy: .public)")
            } catch {
                log.error(
                    "[ClaudeIntegration] hook listener failed to start: \(String(describing: error), privacy: .public)"
                )
            }

            if optedIn {
                do {
                    if await installer.isInstalled() {
                        log.info("[ClaudeIntegration] settings already installed; no write needed")
                    } else {
                        try await installer.install()
                        let backup = await installer.mostRecentBackupPath() ?? "(no prior file)"
                        log.info(
                            "[ClaudeIntegration] settings repair succeeded; backup=\(backup, privacy: .public)"
                        )
                    }
                } catch {
                    log.error(
                        "[ClaudeIntegration] settings repair failed: \(String(describing: error), privacy: .public); integration settings may be stale"
                    )
                }
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

    /// Copy the bundled command hook forwarder to a stable location and chmod it
    /// executable. Returns the destination path, or nil if extraction failed —
    /// the contribution then declines to register.
    nonisolated static func extractEventForwarderScript() -> String? {
        extractHookForwarderScript(named: "event-forwarder")
    }

    /// Copy the bundled status-line forwarder to the same stable extraction dir
    /// as the command hook forwarder. Returns the destination path, or nil if
    /// extraction failed.
    nonisolated static func extractStatusLineForwarderScript() -> String? {
        extractHookForwarderScript(named: "statusline")
    }

    /// Stable, space-free directory the app extracts hook/status forwarders into.
    /// Honors `XDG_DATA_HOME`, defaulting to `~/.local/share`. Deliberately kept
    /// out of `~/.claude` so an extracted script never dirties the dotclaude git
    /// tree, and space-free so the command the installer writes to
    /// `settings.json` stays a clean, unquoted, machine-agnostic tilde path.
    nonisolated static func hookForwarderInstallDirectory() -> URL {
        let dataHome: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            dataHome = URL(fileURLWithPath: xdg)
        } else {
            dataHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local", isDirectory: true)
                .appendingPathComponent("share", isDirectory: true)
        }
        return
            dataHome
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent("hook-forwarders", isDirectory: true)
    }

    /// Generic helper used by the forwarder extractors: copies `<name>.<ext>` from
    /// the bundle's `HookForwarders/` resource directory to
    /// `hookForwarderInstallDirectory()/<name>.<ext>`, chmods it 0o755, and returns
    /// the destination path. Nil on any failure.
    nonisolated private static func extractHookForwarderScript(
        named name: String,
        fileExtension: String = "sh"
    ) -> String? {
        let dir = hookForwarderInstallDirectory()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let dest = dir.appendingPathComponent("\(name).\(fileExtension)")

        // Source: bundled resource file. Packaged apps expose flattened resources
        // through Bundle.main; SwiftPM builds expose them through a sibling
        // WorkspaceManager_WorkspaceManager.bundle.
        let bundleURL = bundledHookForwarderURL(named: name, fileExtension: fileExtension)
        guard let bundleURL else {
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

    nonisolated static func bundledHookForwarderURL(named name: String, fileExtension: String = "sh") -> URL? {
        bundledHookForwarderURL(
            named: name,
            fileExtension: fileExtension,
            mainBundle: .main,
            swiftPMResourceBundle: { Bundle.module }
        )
    }

    nonisolated static func bundledHookForwarderURL(
        named name: String,
        fileExtension: String = "sh",
        mainBundle: Bundle,
        swiftPMResourceBundle: () -> Bundle?
    ) -> URL? {
        let appResourceBundles = hookForwarderResourceBundles(mainBundle: mainBundle)
        if let url = hookForwarderURL(
            named: name,
            fileExtension: fileExtension,
            resourceBundles: appResourceBundles
        ) {
            return url
        }

        guard !isApplicationBundle(mainBundle), let swiftPMBundle = swiftPMResourceBundle() else {
            return nil
        }

        return hookForwarderURL(
            named: name,
            fileExtension: fileExtension,
            resourceBundles: [swiftPMBundle]
        )
    }

    nonisolated static func hookForwarderURL(
        named name: String,
        fileExtension: String = "sh",
        resourceBundles: [Bundle]
    ) -> URL? {
        for bundle in resourceBundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "HookForwarders"
            ) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: fileExtension) {
                return url
            }
        }
        return nil
    }

    private nonisolated static func hookForwarderResourceBundles(mainBundle: Bundle) -> [Bundle] {
        let swiftPMResourceBundleName = "WorkspaceManager_WorkspaceManager.bundle"
        let fileManager = FileManager.default
        var bundles: [Bundle] = []
        var seenPaths = Set<String>()

        func appendBundle(_ bundle: Bundle) {
            let path = bundle.bundleURL.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            bundles.append(bundle)
        }

        func appendBundle(at url: URL) {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            guard fileManager.fileExists(atPath: path), let bundle = Bundle(url: url) else { return }
            bundles.append(bundle)
        }

        appendBundle(mainBundle)

        let nestedResourceBundleURLs = [
            mainBundle.resourceURL?
                .appendingPathComponent(swiftPMResourceBundleName, isDirectory: true),
            mainBundle.bundleURL
                .appendingPathComponent(swiftPMResourceBundleName, isDirectory: true),
        ]

        for url in nestedResourceBundleURLs {
            guard let url else { continue }
            appendBundle(at: url)
        }

        return bundles
    }

    private nonisolated static func isApplicationBundle(_ bundle: Bundle) -> Bool {
        bundle.bundleURL.standardizedFileURL.pathExtension == "app"
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
