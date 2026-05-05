//
//  AgentNotificationPoster.swift
//  WorkspaceManager
//
//  Observes the AgentSessionRegistry and posts a macOS user notification when a
//  session transitions into `.awaitingInput(.permissionPrompt)`. Per spec § Channel 1
//  ("Notification → permission_prompt"), this is the canonical attention signal.
//
//  Coalescing: at most one notification per host session per 30s.
//

import Combine
import Foundation
import UserNotifications
import WorkspaceManagerCore

@MainActor
public final class AgentNotificationPoster {
    private weak var registry: AgentSessionRegistry?
    private var subscription: AnyCancellable?
    private var lastPosted: [UUID: Date] = [:]
    private var requestedAuthorization = false
    private var observedRuns: [UUID: AgentRunState] = [:]

    private static let coalescingWindow: TimeInterval = 30

    public init(registry: AgentSessionRegistry) {
        self.registry = registry
        self.subscription = registry.$statuses.sink { [weak self] statuses in
            self?.handle(statuses: statuses)
        }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    private func handle(statuses: [UUID: AgentSessionStatus]) {
        for (hostID, status) in statuses {
            let previous = observedRuns[hostID]
            observedRuns[hostID] = status.run

            // Only fire on *transition* into permissionPrompt awaiting state.
            guard
                case .awaitingInput(let reason) = status.run,
                reason == .permissionPrompt
            else { continue }

            if let previous, previous == status.run { continue }

            // Coalesce.
            let now = Date()
            if let last = lastPosted[hostID],
                now.timeIntervalSince(last) < Self.coalescingWindow
            {
                continue
            }

            lastPosted[hostID] = now
            postPermissionPrompt(for: status)
        }
    }

    private func postPermissionPrompt(for status: AgentSessionStatus) {
        // `UNUserNotificationCenter.current()` requires a real .app bundle proxy.
        // Calling it from a raw `swift run` binary (or any process whose mainBundle
        // doesn't resolve to a code-signed application) raises an NSInternalInconsistencyException
        // ("bundleProxyForCurrentProcess is nil") that propagates to the runloop and
        // terminates the app. Gate every call behind a bundle-readiness check.
        guard Self.isUserNotificationsAvailable else { return }
        Task { [weak self] in
            await self?.requestAuthorizationIfNeeded()
            await self?.deliverNotification(for: status)
        }
    }

    private func requestAuthorizationIfNeeded() async {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        guard Self.isUserNotificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private func deliverNotification(for status: AgentSessionStatus) async {
        guard Self.isUserNotificationsAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = agentDisplayName(for: status.kind) + " is awaiting input"
        content.body = "Permission requested in \(status.cwd)"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "agent.permission.\(status.hostSessionID.uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// True only when running inside a real `.app` bundle that the notification
    /// framework can resolve. Raw `swift run` debug binaries fall through here.
    private static let isUserNotificationsAvailable: Bool = {
        guard let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty else {
            return false
        }
        // Bundle.main.bundleURL ends with ".app" inside a real bundle; for raw
        // `swift run` it points at the executable's parent directory.
        return Bundle.main.bundleURL.pathExtension == "app"
    }()

    private func agentDisplayName(for kind: AgentKind) -> String {
        switch kind {
        case .claudeCode: return "Claude Code"
        case .opencode: return "OpenCode"
        case .aider: return "Aider"
        case .unknown: return "Agent"
        }
    }
}
