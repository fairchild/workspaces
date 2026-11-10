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
