//
//  DecisionNotificationLifecycle.swift
//  WorkspaceManager
//
//  Owns the decision notification surface for the life of the app. A sibling of
//  `ClaudeIntegrationLifecycle` rather than a passenger inside it: this has
//  nothing to do with Claude hooks, and that lifecycle is skipped entirely under
//  CI, which is exactly the launch shape a demonstrated run uses.
//

import Foundation
import WorkspaceManagerCore

#if canImport(AppKit)
    import AppKit
#endif

@MainActor
public final class DecisionNotificationLifecycle {
    public static let shared = DecisionNotificationLifecycle()

    private var didStart = false
    private var surface: DecisionNotificationSurface?
    private var terminationObserver: NSObjectProtocol?
    private var defaults: UserDefaults = LaunchPreferences.defaults
    private var environment: [String: String] = ProcessInfo.processInfo.environment
    private var surfaceFactory: @MainActor () -> DecisionNotificationSurface = {
        DecisionNotificationSurface()
    }

    private init() {}

    /// Whether this launch runs the surface at all. Off by default: a channel
    /// that interrupts someone is opted into, never discovered.
    public var isEnabled: Bool {
        ExperimentalFeatures.isEnabled(
            .agentDecisionNotifications, userDefaults: defaults, environment: environment)
    }

    /// The surface's own start, retained so a test can await the chain instead of
    /// polling a clock for its side effects.
    public private(set) var startupTask: Task<Void, Never>?

    public func start() {
        guard !didStart else { return }
        didStart = true
        guard isEnabled else { return }

        let surface = surfaceFactory()
        self.surface = surface
        startupTask = Task { @MainActor in
            surface.start()
        }

        #if canImport(AppKit)
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in DecisionNotificationLifecycle.shared.stop() }
            }
        #endif
    }

    public func stop() {
        surface?.stop()
        surface = nil
        startupTask = nil
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
    }

    /// Test seam: swap the defaults, the environment and the surface so the gate
    /// and the start chain can be exercised without a notification centre. Each
    /// call resets `didStart` so a fresh `start()` re-runs the lifecycle.
    func _configureForTesting(
        defaults: UserDefaults,
        environment: [String: String],
        surfaceFactory: @escaping @MainActor () -> DecisionNotificationSurface
    ) {
        self.defaults = defaults
        self.environment = environment
        self.surfaceFactory = surfaceFactory
        self.didStart = false
        self.surface = nil
        self.startupTask = nil
    }
}
