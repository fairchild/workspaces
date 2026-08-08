//
//  LaunchPreferences.swift
//  WorkspaceManagerCore
//
//  Decides which `UserDefaults` domain a launch reads and writes. Isolated runs
//  (a synthetic root, or an explicitly named suite) get a scratch suite so
//  selection/restore state lives and dies with the run instead of leaking in
//  from the persistent app domain — the preferences axis of the isolation
//  `WORKSPACES_DATA_DIR` already gives the sidecar.
//

import Foundation
import os.log

private let log = Logger(subsystem: "com.cloudcompute.workspaces", category: "LaunchPreferences")

/// Which preferences domain a launch resolves to, decided purely from the launch
/// environment so the decision is testable without touching the defaults system.
public enum LaunchPreferencesResolution: Equatable, Sendable {
    /// The persistent app domain — normal dev and production launches.
    case standard
    /// A scratch suite. `resetOnLaunch` means the app wipes it at bootstrap, which
    /// is what keeps a reused suite name from becoming the leak it replaces.
    case scratch(suiteName: String, resetOnLaunch: Bool)

    public var isIsolated: Bool {
        if case .scratch = self { return true }
        return false
    }

    public var suiteName: String? {
        if case .scratch(let suiteName, _) = self { return suiteName }
        return nil
    }

    public var resetsOnLaunch: Bool {
        if case .scratch(_, let resetOnLaunch) = self { return resetOnLaunch }
        return false
    }
}

/// The environment contract: which variables signal isolation and what suite they
/// name.
public enum LaunchPreferencesEnvironment {
    /// Filesystem-isolation signal (#1224). Its presence alone means the run is
    /// synthetic, so preferences isolation composes with it without a second var.
    public static let syntheticRootKey = "WORKSPACES_SYNTHETIC_ROOT"

    /// Names an explicit scratch suite. Callers that need isolation without a
    /// synthetic root, two isolated launches sharing one root, or preferences that
    /// survive a relaunch within one run set this and own the suite's lifetime —
    /// an explicitly named suite is never reset on the app's behalf.
    public static let suiteOverrideKey = "WORKSPACES_PREFERENCES_SUITE"

    /// Prefix every synthetic-launch scratch suite shares. Never the suite name
    /// itself — see `scratchSuiteName(forSyntheticRoot:)`.
    public static let scratchSuiteBaseName = "com.cloudcompute.workspaces.isolated"

    /// Names that resolve back to a persistent domain (the bundled app id, the
    /// unbundled dev process domain, the global domain) or to the scratch-suite
    /// base, so an override naming one is treated as unset rather than silently
    /// defeating isolation or aliasing the synthetic-launch namespace.
    static let reservedSuiteNames: Set<String> = [
        "com.cloudcompute.workspaces",
        "WorkspaceManager",
        "NSGlobalDomain",
        ".GlobalPreferences",
        scratchSuiteBaseName,
    ]

    /// The suite a synthetic root resolves to: the base name plus a stable digest
    /// of the root. One plist per root means two isolated launches under different
    /// roots neither share state nor wipe each other at bootstrap, while every
    /// process launched into the *same* root — the app and the `workspaces` CLI
    /// driving it — still agrees on one suite.
    public static func scratchSuiteName(forSyntheticRoot syntheticRoot: String) -> String {
        "\(scratchSuiteBaseName).\(stableDigest(of: syntheticRoot))"
    }

    public static func resolution(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchPreferencesResolution {
        if let override = trimmed(environment[suiteOverrideKey]) {
            if reservedSuiteNames.contains(override) {
                log.error(
                    """
                    [LaunchPreferences] Ignoring \(suiteOverrideKey, privacy: .public)=\
                    '\(override, privacy: .public)': reserved domain
                    """
                )
            } else {
                return .scratch(suiteName: override, resetOnLaunch: false)
            }
        }

        if let syntheticRoot = trimmed(environment[syntheticRootKey]) {
            return .scratch(
                suiteName: scratchSuiteName(forSyntheticRoot: syntheticRoot),
                resetOnLaunch: true
            )
        }

        return .standard
    }

    /// FNV-1a (64-bit). `Hasher` is seeded per process, so it cannot name a suite
    /// two processes must both find; this is stable across processes and releases.
    private static func stableDigest(of value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func trimmed(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

/// Process-wide handle to the resolved preferences store. Every preferences read
/// in the app goes through `defaults`, so one bootstrap decision covers
/// `@AppStorage`, settings, and restore state alike.
public enum LaunchPreferences {
    public static let resolution = LaunchPreferencesEnvironment.resolution()

    /// Store construction only — reading it never wipes anything, so helper
    /// processes sharing the environment (the `workspaces` CLI driving a live
    /// isolated app) observe the same suite without clearing it underneath.
    public static let defaults: UserDefaults = makeDefaults(for: resolution)

    /// Called first thing in the app's launch, against the process's own resolution.
    public static func bootstrapForApplicationLaunch() {
        bootstrap(resolution: resolution)
    }

    /// Clears the scratch suite when the resolution says this run owns it, then
    /// records the resolved domain so an isolated launch is visible in the log
    /// stream. Takes its resolution as an argument so the wipe decision — which
    /// suites get cleared and which are the caller's to keep — is exercised
    /// directly instead of only through the process environment.
    static func bootstrap(resolution: LaunchPreferencesResolution) {
        if case .scratch(let suiteName, true) = resolution {
            reset(suiteName: suiteName)
        }

        switch resolution {
        case .standard:
            log.info("[LaunchPreferences] domain=standard")
        case .scratch(let suiteName, let resetOnLaunch):
            let isolated = makeDefaults(for: resolution) !== UserDefaults.standard
            log.info(
                """
                [LaunchPreferences] domain=scratch suite=\(suiteName, privacy: .public) \
                reset=\(resetOnLaunch, privacy: .public) isolated=\(isolated, privacy: .public)
                """
            )
        }
    }

    /// Drops every value in a suite. Applied to the on-disk domain, so a store
    /// already vended for that suite sees the cleared state too. Module-internal:
    /// the only sanctioned way to clear preferences is a launch whose resolution
    /// says the run owns the suite.
    static func reset(suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    /// Builds the store a resolution names. A suite the defaults system refuses
    /// degrades to the persistent domain loudly rather than failing the launch.
    public static func makeDefaults(for resolution: LaunchPreferencesResolution) -> UserDefaults {
        switch resolution {
        case .standard:
            return .standard
        case .scratch(let suiteName, _):
            guard let suite = UserDefaults(suiteName: suiteName) else {
                log.error(
                    """
                    [LaunchPreferences] Suite '\(suiteName, privacy: .public)' unavailable; \
                    falling back to the persistent domain
                    """
                )
                return .standard
            }
            return suite
        }
    }
}
