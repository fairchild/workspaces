//
//  AutomationIntegrationLifecycle.swift
//  WorkspaceManager
//
//  Starts the local app-shell automation listener when the experimental feature
//  is enabled and exposes its socket/handle registry to terminal surfaces.
//

import AppKit
import Combine
import Foundation
import WorkspaceManagerCore

@MainActor
final class AutomationIntegrationLifecycle: ObservableObject {
    static let shared = AutomationIntegrationLifecycle()

    let handleRegistry = AutomationHandleRegistry()

    private(set) var listener: AutomationListener?
    private(set) var controller: AutomationController?
    @Published private(set) var socketPath: String?
    private var teardownObserver: Any?
    private var didStart = false

    private init() {}

    var isEnabled: Bool {
        ExperimentalFeatures.isEnabled(.automationAPI)
    }

    func configure(
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void
    ) {
        guard isEnabled else {
            hostTerminalState.configureAutomation(handleRegistry: nil, socketPath: nil)
            return
        }

        startIfNeeded(
            hostTerminalState: hostTerminalState,
            focusTerminal: focusTerminal,
            requestCloseTerminal: requestCloseTerminal
        )
        hostTerminalState.configureAutomation(handleRegistry: handleRegistry, socketPath: socketPath)
    }

    func startIfNeeded(
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void
    ) {
        guard !didStart else {
            controller?.update(
                hostTerminalState: hostTerminalState,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal
            )
            return
        }
        didStart = true

        let controller = AutomationController(
            handleRegistry: handleRegistry,
            hostTerminalState: hostTerminalState,
            focusTerminal: focusTerminal,
            requestCloseTerminal: requestCloseTerminal
        )
        self.controller = controller

        let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
        let auditLogger = AutomationAuditLogger(
            auditURL: AutomationAuditLogger.defaultAuditURL(bundleIdentifier: bundleID)
        )
        let listener = AutomationListener(
            bundleIdentifier: bundleID,
            controller: controller,
            auditLogger: auditLogger,
            isEnabled: { ExperimentalFeatures.isEnabled(.automationAPI) }
        )
        self.listener = listener
        self.socketPath = listener.socketPath

        Task { @MainActor in
            do {
                try await listener.start()
                NSLog("[AutomationIntegration] listener started at %@", listener.socketPath)
            } catch {
                NSLog("[AutomationIntegration] listener failed to start: %@", "\(error)")
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
        await listener?.stop()
        listener = nil
        controller = nil
        socketPath = nil
        didStart = false
        handleRegistry.removeAll()
        if let teardownObserver {
            NotificationCenter.default.removeObserver(teardownObserver)
            self.teardownObserver = nil
        }
    }
}
