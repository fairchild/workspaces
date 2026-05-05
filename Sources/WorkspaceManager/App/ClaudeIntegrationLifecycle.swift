//
//  ClaudeIntegrationLifecycle.swift
//  WorkspaceManager
//
//  Owns the runtime lifecycle of the Claude Code integration: hook listener over
//  a Unix domain socket plus the notification poster that observes the registry.
//  Hooked at app startup from `WorkspaceManagerApp.init`.
//

import AppKit
import Foundation
import WorkspaceManagerCore

@MainActor
final class ClaudeIntegrationLifecycle {
    static let shared = ClaudeIntegrationLifecycle()

    private(set) var listener: AgentHookListener?
    private(set) var notificationPoster: AgentNotificationPoster?
    private(set) var settingsInstaller: ClaudeSettingsInstaller?
    private(set) var socketPath: String?
    private var teardownObserver: Any?
    private var didStart = false

    private init() {}

    func start(registry: AgentSessionRegistry) {
        guard !didStart else { return }
        didStart = true

        let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
        let listener = AgentHookListener(bundleIdentifier: bundleID, registry: registry)
        self.listener = listener
        self.notificationPoster = AgentNotificationPoster(registry: registry)

        // Build the settings installer immediately so the Settings UI can render the
        // merge preview. The contribution targets the live socket path, which we know
        // synchronously via the AgentHookListener init contract.
        let installer = ClaudeSettingsInstaller()
        self.settingsInstaller = installer

        Task {
            let resolvedSocketPath = await listener.socketPath
            self.socketPath = resolvedSocketPath
            await installer.register(workspacesHooksContribution(socketPath: resolvedSocketPath))
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
