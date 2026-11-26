//
//  TerminalMultiplexingMode.swift
//  WorkspaceManagerCore
//
//  Whether a terminal tile runs its shell under its own tmux session or as a plain
//  Ghostty surface. `resolve()` reads the global setting (the environment override
//  wins); each `HostTerminalSession` carries the mode it was born with.
//

import Foundation

public enum TerminalMultiplexingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case ghosttyManagedSplits = "ghostty_managed_splits"
    case tmuxPerSession = "tmux_per_session"

    public static let storageKey = "terminalMultiplexingMode"
    public static let environmentOverrideKey = "WORKSPACES_TERMINAL_MULTIPLEXING_MODE"
    public static let defaultValue: TerminalMultiplexingMode = .ghosttyManagedSplits

    /// The shell runs directly in the Ghostty surface and ends when the app quits.
    public static let plain: TerminalMultiplexingMode = .ghosttyManagedSplits
    /// The shell runs under a holder that outlives the app, so a later launch can rejoin it;
    /// tmux today. New code names the holder-backed mode through this alias, so swapping the
    /// holder changes the case and its launch path rather than every caller.
    public static let persistent: TerminalMultiplexingMode = .tmuxPerSession

    public var id: String { rawValue }

    public static func resolve(
        from userDefaults: UserDefaults = LaunchPreferences.defaults,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalMultiplexingMode {
        resolve(rawValue: userDefaults.string(forKey: storageKey), environment: environment)
    }

    public static func resolve(
        rawValue: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalMultiplexingMode {
        if let override = environment[environmentOverrideKey],
            let mode = TerminalMultiplexingMode(rawValue: override)
        {
            return mode
        }

        if let rawValue, let mode = TerminalMultiplexingMode(rawValue: rawValue) {
            return mode
        }

        return defaultValue
    }
}
