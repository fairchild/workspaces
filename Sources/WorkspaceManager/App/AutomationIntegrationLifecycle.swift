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
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        webSurfaceRecords: @escaping @MainActor () -> [WebSurfaceRecord] = { [] }
    ) async {
        guard isEnabled else {
            tileTreeStore.configureAutomation(handleRegistry: nil, socketPath: nil)
            return
        }

        do {
            let socketPath = try await startIfNeeded(
                tileTreeStore: tileTreeStore,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal,
                webSurfaceRecords: webSurfaceRecords
            )
            tileTreeStore.configureAutomation(handleRegistry: handleRegistry, socketPath: socketPath)
        } catch {
            tileTreeStore.configureAutomation(handleRegistry: nil, socketPath: nil)
            handleRegistry.removeAll()
            NSLog("[AutomationIntegration] listener unavailable: %@", "\(error)")
        }
    }

    func startIfNeeded(
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        webSurfaceRecords: @escaping @MainActor () -> [WebSurfaceRecord] = { [] }
    ) async throws -> String {
        // Compose the read-only web-surface list from the caller's live source records
        // joined with the surface store's live WKWebView state (non-creating peek).
        let webSurfaces = Self.makeWebSurfaces(
            tileTreeStore: tileTreeStore,
            webSurfaceRecords: webSurfaceRecords
        )
        let webSnapshot = Self.makeWebSnapshot(
            tileTreeStore: tileTreeStore,
            webSurfaceRecords: webSurfaceRecords
        )

        if let startTask {
            let socketPath = try await startTask.value
            controller?.update(
                tileTreeStore: tileTreeStore,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal,
                webSurfaces: webSurfaces,
                webSnapshot: webSnapshot
            )
            return socketPath
        }

        guard !didStart else {
            controller?.update(
                tileTreeStore: tileTreeStore,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal,
                webSurfaces: webSurfaces,
                webSnapshot: webSnapshot
            )
            guard let socketPath else {
                throw AutomationListener.ListenerError.socketBindFailed("listener started without a socket path")
            }
            return socketPath
        }

        let controller = AutomationController(
            handleRegistry: handleRegistry,
            tileTreeStore: tileTreeStore,
            focusTerminal: focusTerminal,
            requestCloseTerminal: requestCloseTerminal,
            webSurfaces: webSurfaces,
            webSnapshot: webSnapshot
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

    private static func makeWebSurfaces(
        tileTreeStore: TileTreeStore,
        webSurfaceRecords: @escaping @MainActor () -> [WebSurfaceRecord]
    ) -> @MainActor () -> [AutomationWebSurfaceDescriptor] {
        { [weak tileTreeStore] in
            WebSurfaceEnumerator.descriptors(
                records: webSurfaceRecords(),
                liveState: { sourceID in
                    tileTreeStore?.surfaceStore.liveWebState(forSourceID: sourceID)
                }
            )
        }
    }

    /// Resolves a snapshot request against the caller's live source records and the surface
    /// store's live `WKWebView` (both non-creating), then captures on the MainActor. Fails
    /// closed: an unknown id or a source without an instantiated view never spins up a page.
    private static func makeWebSnapshot(
        tileTreeStore: TileTreeStore,
        webSurfaceRecords: @escaping @MainActor () -> [WebSurfaceRecord]
    ) -> @MainActor (UUID) async -> WebSnapshotOutcome {
        { [weak tileTreeStore] sourceID in
            guard webSurfaceRecords().contains(where: { $0.sourceID == sourceID }) else {
                return .unknownSource
            }
            guard let webView = tileTreeStore?.surfaceStore.liveWebView(forSourceID: sourceID) else {
                return .notLive
            }
            return await WebSurfaceSnapshotCapture.capture(webView)
        }
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
