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
    private var defaults: UserDefaults = .standard
    private var installerFactory: @Sendable (String) async -> any ClaudeSettingsInstalling = {
        _ in
        let eventForwarderPath = ClaudeIntegrationLifecycle.extractEventForwarderScript()
        if eventForwarderPath == nil {
            NSLog(
                "[ClaudeIntegration] event-forwarder.sh extraction failed; Channel 1 will be skipped this session"
            )
        }

        let statusLinePath = ClaudeIntegrationLifecycle.bundledStatusLineForwarderPath()
        if statusLinePath == nil {
            NSLog(
                "[ClaudeIntegration] statusline.sh not found in bundle; skipping Channel 2 contribution"
            )
        }

        return ClaudeSettingsInstaller(
            eventForwarderScriptPath: eventForwarderPath,
            statusLineForwarderPath: statusLinePath
        )
    }

    /// Locate the Channel 2 status-line forwarder shell shipped alongside the app.
    /// Returns nil if the bundle was assembled without it — caller logs and
    /// proceeds without registering Channel 2.
    nonisolated static func bundledStatusLineForwarderPath() -> String? {
        bundledHookForwarderURL(named: "statusline")?.path
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
                NSLog("[ClaudeIntegration] hook listener started at %@", resolvedSocketPath)
            } catch {
                NSLog("[ClaudeIntegration] hook listener failed to start: %@", "\(error)")
            }

            if optedIn {
                do {
                    if await installer.isInstalled() {
                        NSLog("[ClaudeIntegration] settings already installed; no write needed")
                    } else {
                        try await installer.install()
                        let backup = await installer.mostRecentBackupPath() ?? "(no prior file)"
                        NSLog(
                            "[ClaudeIntegration] settings repair succeeded; backup=%@",
                            backup
                        )
                    }
                } catch {
                    NSLog(
                        "[ClaudeIntegration] settings repair failed: %@; integration settings may be stale",
                        "\(error)"
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

    /// Copy the bundled `event-forwarder.sh` (Channel 1 hook event forwarder) to a
    /// stable location under Application Support and chmod it executable. Returns
    /// the destination path, or nil if extraction failed — the contribution then
    /// declines to register, and Channel 1 stays dormant for this session.
    nonisolated static func extractEventForwarderScript() -> String? {
        extractHookForwarderScript(named: "event-forwarder")
    }

    /// Generic helper used by the event-forwarder extractor:
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

        // Source: bundled .sh file. Packaged apps expose flattened resources
        // through Bundle.main; SwiftPM builds expose them through a sibling
        // WorkspaceManager_WorkspaceManager.bundle.
        let bundleURL = bundledHookForwarderURL(named: name)
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

    nonisolated static func bundledHookForwarderURL(named name: String) -> URL? {
        bundledHookForwarderURL(
            named: name,
            mainBundle: .main,
            swiftPMResourceBundle: { Bundle.module }
        )
    }

    nonisolated static func bundledHookForwarderURL(
        named name: String,
        mainBundle: Bundle,
        swiftPMResourceBundle: () -> Bundle?
    ) -> URL? {
        let appResourceBundles = hookForwarderResourceBundles(mainBundle: mainBundle)
        if let url = hookForwarderURL(named: name, resourceBundles: appResourceBundles) {
            return url
        }

        guard !isApplicationBundle(mainBundle), let swiftPMBundle = swiftPMResourceBundle() else {
            return nil
        }

        return hookForwarderURL(
            named: name,
            resourceBundles: [swiftPMBundle]
        )
    }

    nonisolated static func hookForwarderURL(named name: String, resourceBundles: [Bundle]) -> URL? {
        for bundle in resourceBundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: "sh",
                subdirectory: "HookForwarders"
            ) {
                return url
            }
            if let url = bundle.url(forResource: name, withExtension: "sh") {
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
