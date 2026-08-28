//
//  AutomationSupportDirectory.swift
//  WorkspaceManagerCore
//
//  Where the automation plane's per-launch files live — the socket, the audit log, and the
//  operator credential. One resolver so all three land together, and so an isolated launch
//  moves all three somewhere the running app's copy is not (#1391).
//

import Foundation

/// The directory the automation plane writes into, for a given bundle identifier.
///
/// Keyed on bundle id alone, this was one shared directory for every copy of the app: an
/// unbundled debug build has no `Bundle.main.bundleIdentifier` and falls back to the release
/// identifier, so a second instance bound the running app's socket, appended to its audit log,
/// and — because a launch with the Automation API disabled fails closed by removing it — deleted
/// the credential the daily driver had minted. The running app cannot see that happen: its
/// in-memory record still says the credential is published.
///
/// `WORKSPACES_SYNTHETIC_ROOT` already means "this run must not touch the owner's real
/// filesystem roots" — `WorkspaceOrphanReconciler` and `LaunchPreferences` both honour it — and
/// it is honoured here for the same reason. `WORKSPACES_DATA_DIR` deliberately does not apply:
/// it relocates the model store and the local-state sidecar, and a run that only moves its data
/// still shares one automation plane with the app it is running beside.
public enum AutomationSupportDirectory {
    /// A `sockaddr_un.sun_path` holds 104 bytes on Darwin, including the terminator. The real
    /// Application Support path already spends ~88 of them, so an isolated directory cannot be
    /// nested inside an arbitrary synthetic root — that overruns the limit and the socket never
    /// binds, while the credential is still written and names a path nothing is listening on.
    public static let maximumSocketPathLength = 104

    /// The automation directory for `bundleIdentifier`, or an isolated one when a synthetic root
    /// is active.
    ///
    /// An isolated run gets a short, deterministic directory *derived from* the synthetic root
    /// rather than one inside it — the socket has to stay addressable, and a synthetic root is
    /// usually a deep scratch path. The digest is stable across processes, so the app and the
    /// `workspaces` CLI launched into the same root agree on where to look, exactly as
    /// `LaunchPreferences` does for its scratch suite.
    public nonisolated static func url(
        bundleIdentifier: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let syntheticRoot = SyntheticRunRoot.url(environment: environment) else {
            let appSupport =
                FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first ?? FileManager.default.temporaryDirectory
            return appSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        }

        return URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ws-auto-\(digest(of: syntheticRoot.path))", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    /// Path of a named file in that directory.
    public nonisolated static func fileURL(
        named fileName: String,
        bundleIdentifier: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        url(bundleIdentifier: bundleIdentifier, environment: environment)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// FNV-1a (64-bit), truncated. `Hasher` is seeded per process and so cannot name a directory
    /// two processes must both find; this is stable across processes and releases, and short
    /// enough to keep the socket path inside `sun_path`.
    private nonisolated static func digest(of value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash).prefix(8).description
    }
}
