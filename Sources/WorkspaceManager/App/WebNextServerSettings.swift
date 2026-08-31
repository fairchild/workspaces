//
//  WebNextServerSettings.swift
//  WorkspaceManager
//
//  Resolves the embedded web-next server's launch configuration from user
//  settings (with the Milestone-1 demo defaults) and holds the live service so
//  app termination can shut the server's process group down cleanly. The server
//  is started lazily on first activation of the embedded surface, so nothing
//  here spawns a process — it only decides where and how one would launch.
//

import Foundation
import WorkspaceManagerCore

enum WebNextServerSettings {
    /// UserDefaults key for the web-next checkout the server launches from.
    static let rootStorageKey = "webNextServerRoot"

    /// Milestone-1 demo default: the sibling CLAUDE.md/AGENTS.md checkout. Packaging
    /// web-next into the app bundle is deferred (Milestone-2 follow-up).
    static let defaultRoot = "~/code/workspaces/web-next"

    /// Loopback port, clear of dev (3100) and hero (3200) per the contract.
    static let port = 3140

    static func resolvedConfiguration(
        defaults: UserDefaults = LaunchPreferences.defaults
    ) -> WebNextServerConfiguration {
        let configured = defaults.string(forKey: rootStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root: String
        if let configured, !configured.isEmpty {
            root = configured
        } else {
            root = defaultRoot
        }
        let expanded = (root as NSString).expandingTildeInPath
        // A resolvable tailnet origin is forwarded to the child so the
        // mobile pairing path (tailscale serve -> loopback) passes the
        // server's Host gate; absent Tailscale this stays empty and the
        // server behaves exactly as before. Deliberately a provider —
        // resolution may shell out to the Tailscale CLI, and this function
        // runs on the launch path.
        return WebNextServerConfiguration(
            webNextRoot: URL(fileURLWithPath: expanded),
            port: port,
            extraLocalOriginsProvider: {
                TailnetIdentity.httpsOrigin().map { [$0] } ?? []
            }
        )
    }
}

/// Process-wide handle to the live embedded web-next server so the AppKit
/// termination hook — which cannot reach the SwiftUI service graph — can stop
/// the server's process group before the app exits. Without this, quitting
/// while the server runs would orphan a `next start` child holding the port.
final class WebNextServerLifecycle: @unchecked Sendable {
    static let shared = WebNextServerLifecycle()

    private let lock = NSLock()
    private var service: (any WebNextServerServiceProtocol)?

    func register(_ service: any WebNextServerServiceProtocol) {
        lock.lock()
        defer { lock.unlock() }
        self.service = service
    }

    /// Best-effort synchronous shutdown for `applicationWillTerminate`. Blocks up
    /// to `timeout` — kept under the OS's ~5s terminate budget — while the
    /// service runs its compressed-grace `stopForTermination`, so the child group
    /// is gone before the process exits; returns early if no server was started.
    func stopBlocking(timeout: TimeInterval = 4) {
        lock.lock()
        let service = self.service
        lock.unlock()
        guard let service else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await service.stopForTermination()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }
}
