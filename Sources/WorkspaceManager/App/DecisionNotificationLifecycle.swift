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
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "DecisionNotifications")

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
    private var surfaceFactory: @MainActor (URL?) -> DecisionNotificationSurface = { board in
        DecisionNotificationSurface(boardURL: board)
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

        // An isolated run that did not name its board gets no board at all.
        // Answering against the default would write a real verdict into the owner's
        // real store and look like it worked, and there is no undo for that
        // beyond editing the card by hand.
        let board = DecisionBoardConstants.resolvedBoardURL(environment: environment)
        let surface = surfaceFactory(board)
        self.surface = surface

        // Claimed even when the surface will not post: with no delegate at all
        // macOS suppresses every notification while the app is frontmost, which
        // is #1623 and predates this feature.
        surface.claimDelegate()

        guard isEnabled else { return }
        guard board != nil else {
            log.error(
                "decision notifications stay off: \(DecisionBoardConstants.boardURLEnvironmentKey, privacy: .public) must be set under a synthetic root"
            )
            return
        }
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
        surfaceFactory: @escaping @MainActor (URL?) -> DecisionNotificationSurface
    ) {
        self.defaults = defaults
        self.environment = environment
        self.surfaceFactory = surfaceFactory
        self.didStart = false
        self.surface = nil
        self.startupTask = nil
    }
}
