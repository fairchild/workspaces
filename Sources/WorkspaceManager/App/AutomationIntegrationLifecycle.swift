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
    private var startTask: Task<String, Error>?

    private init() {}

    var isEnabled: Bool {
        ExperimentalFeatures.isEnabled(.automationAPI)
    }

    func configure(
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void
    ) async {
        guard isEnabled else {
            hostTerminalState.configureAutomation(handleRegistry: nil, socketPath: nil)
            return
        }

        do {
            let socketPath = try await startIfNeeded(
                hostTerminalState: hostTerminalState,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal
            )
            hostTerminalState.configureAutomation(handleRegistry: handleRegistry, socketPath: socketPath)
        } catch {
            hostTerminalState.configureAutomation(handleRegistry: nil, socketPath: nil)
            handleRegistry.removeAll()
            NSLog("[AutomationIntegration] listener unavailable: %@", "\(error)")
        }
    }

    func startIfNeeded(
        hostTerminalState: HostTerminalStateStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void
    ) async throws -> String {
        if let startTask {
            let socketPath = try await startTask.value
            controller?.update(
                hostTerminalState: hostTerminalState,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal
            )
            return socketPath
        }

        guard !didStart else {
            controller?.update(
                hostTerminalState: hostTerminalState,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal
            )
            guard let socketPath else {
                throw AutomationListener.ListenerError.socketBindFailed("listener started without a socket path")
            }
            return socketPath
        }

        let controller = AutomationController(
            handleRegistry: handleRegistry,
            hostTerminalState: hostTerminalState,
            focusTerminal: focusTerminal,
            requestCloseTerminal: requestCloseTerminal
        )

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

        let startTask = Task<String, Error> {
            try await listener.start()
            return listener.socketPath
        }
        self.startTask = startTask

        let startedSocketPath: String
        do {
            startedSocketPath = try await startTask.value
        } catch {
            self.startTask = nil
            throw error
        }

        self.controller = controller
        self.listener = listener
        self.socketPath = startedSocketPath
        didStart = true
        self.startTask = nil
        NSLog("[AutomationIntegration] listener started at %@", listener.socketPath)

        teardownObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.stop() }
        }
        return listener.socketPath
    }

    func stop() async {
        startTask?.cancel()
        startTask = nil
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
