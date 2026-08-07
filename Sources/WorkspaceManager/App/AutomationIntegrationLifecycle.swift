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
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "AutomationIntegrationLifecycle")

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
    private var operatorCredentialURL: URL?
    private var appIntentOperatorHandle: String?
    private let appIntentOperatorHostSessionID = UUID()

    /// The app scope id operator handles carry — matched to the value `TileTreeStore` stamps on tile
    /// handles so audit and context read consistently across both handle classes.
    private static let appScopeID = "workspaces.local"

    private init() {}

    var isEnabled: Bool {
        ExperimentalFeatures.isEnabled(.automationAPI)
    }

    /// Whether this launch opted into operator scope. Both mint paths check it: the socket-side
    /// credential provision (reached only when the listener is enabled) and the App Intents mint,
    /// which has no listener dependency and therefore gates on it explicitly per call.
    private var isOperatorEnabled: Bool {
        ExperimentalFeatures.isEnabled(.automationOperator)
    }

    func configure(
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        webSurfaceRecords: @escaping @MainActor () -> [WebSurfaceRecord] = { [] },
        workspaceInventory: @escaping @MainActor () -> AutomationWorkspaceInventory = {
            AutomationWorkspaceInventory()
        },
        gestureVerbs: AutomationGestureVerbs? = nil
    ) async {
        let webSurfaces = Self.makeWebSurfaces(
            tileTreeStore: tileTreeStore,
            webSurfaceRecords: webSurfaceRecords
        )
        let webSnapshot = Self.makeWebSnapshot(
            tileTreeStore: tileTreeStore,
            webSurfaceRecords: webSurfaceRecords
        )
        let windows: @MainActor () -> [AutomationWindowDescriptor] = {
            AutomationWindowEnumerator.descriptors()
        }
        let windowSnapshot: @MainActor (String) async -> WindowSnapshotOutcome = { windowID in
            WindowSnapshotService.snapshot(windowID: windowID)
        }

        configureController(
            tileTreeStore: tileTreeStore,
            focusTerminal: focusTerminal,
            requestCloseTerminal: requestCloseTerminal,
            webSurfaces: webSurfaces,
            webSnapshot: webSnapshot,
            windows: windows,
            windowSnapshot: windowSnapshot,
            workspaceInventory: workspaceInventory,
            gestureVerbs: gestureVerbs
        )

        guard isEnabled else {
            tileTreeStore.configureAutomation(handleRegistry: nil, socketPath: nil)
            // Fail closed: an app without the Automation API leaves no operator credential behind.
            clearOperatorCredential()
            return
        }

        do {
            let socketPath = try await startIfNeeded(
                tileTreeStore: tileTreeStore,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal,
                webSurfaceRecords: webSurfaceRecords,
                workspaceInventory: workspaceInventory,
                gestureVerbs: gestureVerbs,
                webSurfaces: webSurfaces,
                webSnapshot: webSnapshot,
                windows: windows,
                windowSnapshot: windowSnapshot
            )
            tileTreeStore.configureAutomation(handleRegistry: handleRegistry, socketPath: socketPath)
        } catch {
            tileTreeStore.configureAutomation(handleRegistry: nil, socketPath: nil)
            handleRegistry.removeAll()
            log.error("[AutomationIntegration] listener unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func startIfNeeded(
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        webSurfaceRecords: @escaping @MainActor () -> [WebSurfaceRecord] = { [] },
        workspaceInventory: @escaping @MainActor () -> AutomationWorkspaceInventory = {
            AutomationWorkspaceInventory()
        },
        gestureVerbs: AutomationGestureVerbs? = nil,
        webSurfaces: (@MainActor () -> [AutomationWebSurfaceDescriptor])? = nil,
        webSnapshot: (@MainActor (UUID) async -> WebSnapshotOutcome)? = nil,
        windows: (@MainActor () -> [AutomationWindowDescriptor])? = nil,
        windowSnapshot: (@MainActor (String) async -> WindowSnapshotOutcome)? = nil
    ) async throws -> String {
        // Compose the read-only web-surface list from the caller's live source records
        // joined with the surface store's live WKWebView state (non-creating peek).
        let webSurfaces =
            webSurfaces
            ?? Self.makeWebSurfaces(tileTreeStore: tileTreeStore, webSurfaceRecords: webSurfaceRecords)
        let webSnapshot =
            webSnapshot
            ?? Self.makeWebSnapshot(tileTreeStore: tileTreeStore, webSurfaceRecords: webSurfaceRecords)
        let windows =
            windows ?? {
                AutomationWindowEnumerator.descriptors()
            }
        let windowSnapshot =
            windowSnapshot ?? { windowID in
                WindowSnapshotService.snapshot(windowID: windowID)
            }

        if let startTask {
            let socketPath = try await startTask.value
            controller?.update(
                tileTreeStore: tileTreeStore,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal,
                webSurfaces: webSurfaces,
                webSnapshot: webSnapshot,
                windows: windows,
                windowSnapshot: windowSnapshot,
                workspaceInventory: workspaceInventory,
                gestureVerbs: gestureVerbs
            )
            return socketPath
        }

        guard !didStart else {
            controller?.update(
                tileTreeStore: tileTreeStore,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal,
                webSurfaces: webSurfaces,
                webSnapshot: webSnapshot,
                windows: windows,
                windowSnapshot: windowSnapshot,
                workspaceInventory: workspaceInventory,
                gestureVerbs: gestureVerbs
            )
            guard let socketPath else {
                throw AutomationListener.ListenerError.socketBindFailed("listener started without a socket path")
            }
            return socketPath
        }

        let controller = configureController(
            tileTreeStore: tileTreeStore,
            focusTerminal: focusTerminal,
            requestCloseTerminal: requestCloseTerminal,
            webSurfaces: webSurfaces,
            webSnapshot: webSnapshot,
            windows: windows,
            windowSnapshot: windowSnapshot,
            workspaceInventory: workspaceInventory,
            gestureVerbs: gestureVerbs
        )

        let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
        let auditLogger = AutomationAuditLogger(
            auditURL: AutomationAuditLogger.defaultAuditURL(bundleIdentifier: bundleID)
        )
        let listener = AutomationListener(
            bundleIdentifier: bundleID,
            controller: controller,
            auditLogger: auditLogger,
            isEnabled: { ExperimentalFeatures.isEnabled(.automationAPI) },
            makeHealthServer: { launchedAt in
                AutomationServerDescriptor.current(
                    launchedAt: launchedAt,
                    experiments: Self.activeAutomationExperimentKeys()
                )
            }
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
        log.info("[AutomationIntegration] listener started at \(listener.socketPath, privacy: .public)")

        // Mint the per-launch operator credential exactly once, on first start. Opted-in launches
        // register an operator handle and write the credential next to the socket; every other
        // launch clears any stale credential so a non-opted-in app never leaves one behind.
        let credentialURL = AutomationOperatorCredentialStore.defaultURL(bundleIdentifier: bundleID)
        operatorCredentialURL = credentialURL
        let credential = AutomationOperatorProvisioner.provision(
            optedIn: isOperatorEnabled,
            registry: handleRegistry,
            socketPath: startedSocketPath,
            appScopeID: Self.appScopeID,
            credentialURL: credentialURL
        )
        if credential != nil {
            log.info("[AutomationIntegration] operator credential minted at \(credentialURL.path, privacy: .public)")
        }

        teardownObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Remove the credential synchronously here: the async stop() Task below may not run
            // before the process exits, and "dies with the launch" should hold on a clean quit.
            // (A crash can't clean up, which is why a stale credential also fails closed against the
            // fresh registry — see AutomationOperatorCredentialStore.)
            let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
            AutomationOperatorCredentialStore.remove(
                at: AutomationOperatorCredentialStore.defaultURL(bundleIdentifier: bundleID)
            )
            Task { @MainActor [weak self] in await self?.stop() }
        }
        return listener.socketPath
    }

    @discardableResult
    private func configureController(
        tileTreeStore: TileTreeStore,
        focusTerminal: @escaping @MainActor (UUID) -> Void,
        requestCloseTerminal: @escaping @MainActor (UUID) -> Void,
        webSurfaces: @escaping @MainActor () -> [AutomationWebSurfaceDescriptor],
        webSnapshot: @escaping @MainActor (UUID) async -> WebSnapshotOutcome,
        windows: @escaping @MainActor () -> [AutomationWindowDescriptor],
        windowSnapshot: @escaping @MainActor (String) async -> WindowSnapshotOutcome,
        workspaceInventory: @escaping @MainActor () -> AutomationWorkspaceInventory,
        gestureVerbs: AutomationGestureVerbs?
    ) -> AutomationController {
        if let controller {
            controller.update(
                tileTreeStore: tileTreeStore,
                focusTerminal: focusTerminal,
                requestCloseTerminal: requestCloseTerminal,
                webSurfaces: webSurfaces,
                webSnapshot: webSnapshot,
                windows: windows,
                windowSnapshot: windowSnapshot,
                workspaceInventory: workspaceInventory,
                gestureVerbs: gestureVerbs
            )
            return controller
        }

        let controller = AutomationController(
            handleRegistry: handleRegistry,
            tileTreeStore: tileTreeStore,
            focusTerminal: focusTerminal,
            requestCloseTerminal: requestCloseTerminal,
            webSurfaces: webSurfaces,
            webSnapshot: webSnapshot,
            windows: windows,
            windowSnapshot: windowSnapshot,
            workspaceInventory: workspaceInventory,
            gestureVerbs: gestureVerbs
        )
        self.controller = controller
        return controller
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

    private nonisolated static func activeAutomationExperimentKeys() -> [String] {
        [
            ExperimentalFeature.automationAPI,
            .automationOperator,
            .automationInputWrite,
        ]
        .filter { ExperimentalFeatures.isEnabled($0) }
        .map(\.rawValue)
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

    /// Detaches the gesture-verb layer when the installing window disappears, so a mutation verb
    /// fails closed (`unsupported`) rather than driving a stale gesture while the app lingers as an
    /// accessory. The listener and operator credential stay up — only the window-bound gesture layer
    /// drops; a reappearing window reinstalls it via `configure`.
    func detachGestureVerbs() {
        controller?.detachGestureVerbs()
    }

    func appIntentControllerAndHandle() throws -> (controller: AutomationController, handle: String) {
        try appIntentControllerAndHandle(isOperatorEnabled: isOperatorEnabled)
    }

    /// The operator gate runs before the cached-handle fast path, so turning the experiment off
    /// mid-launch cuts Shortcuts off immediately — the same per-request re-check `input.write`
    /// applies. `isOperatorEnabled` is injected so tests exercise the gate without mutating global
    /// experiment state.
    func appIntentControllerAndHandle(
        isOperatorEnabled: Bool
    ) throws -> (controller: AutomationController, handle: String) {
        guard isOperatorEnabled else {
            throw AutomationServiceError(
                .capabilityDenied,
                "The Automation Operator Scope experiment is disabled. "
                    + "Enable it in WorkSpaces Settings to use Shortcuts actions."
            )
        }
        guard let controller else {
            throw AutomationServiceError(
                .unsupported,
                "No WorkSpaces window is attached; open a WorkSpaces window and try again."
            )
        }
        if let appIntentOperatorHandle,
            handleRegistry.resolve(appIntentOperatorHandle)?.isOperator == true
        {
            return (controller, appIntentOperatorHandle)
        }

        let entry = handleRegistry.registerOperator(
            appScopeID: Self.appScopeID,
            hostSessionID: appIntentOperatorHostSessionID
        )
        appIntentOperatorHandle = entry.handle
        return (controller, entry.handle)
    }

    func stop() async {
        startTask?.cancel()
        startTask = nil
        await listener?.stop()
        listener = nil
        controller = nil
        socketPath = nil
        didStart = false
        appIntentOperatorHandle = nil
        handleRegistry.removeAll()
        // The operator handle dies with the launch; remove its credential file on the way out so a
        // clean exit leaves nothing readable (a crash can't, which is why stale credentials fail
        // closed against the fresh registry — see AutomationOperatorCredentialStore).
        clearOperatorCredential()
        if let teardownObserver {
            NotificationCenter.default.removeObserver(teardownObserver)
            self.teardownObserver = nil
        }
    }

    private func clearOperatorCredential() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.cloudcompute.workspaces"
        let url = operatorCredentialURL ?? AutomationOperatorCredentialStore.defaultURL(bundleIdentifier: bundleID)
        AutomationOperatorCredentialStore.remove(at: url)
        operatorCredentialURL = nil
    }
}
