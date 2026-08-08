//
//  TerminalMultiplexingMode.swift
//  WorkspaceManager
//

import Foundation
import WorkspaceManagerCore

enum TerminalMultiplexingMode: String, CaseIterable, Identifiable, Codable {
    case ghosttyManagedSplits = "ghostty_managed_splits"
    case tmuxPerSession = "tmux_per_session"

    static let storageKey = "terminalMultiplexingMode"
    static let environmentOverrideKey = "WORKSPACES_TERMINAL_MULTIPLEXING_MODE"
    static let defaultValue: TerminalMultiplexingMode = .ghosttyManagedSplits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ghosttyManagedSplits:
            return "Ghostty Splits"
        case .tmuxPerSession:
            return "tmux Per Session"
        }
    }

    var summary: String {
        switch self {
        case .ghosttyManagedSplits:
            return "Use the app's embedded Ghostty split model (Cmd+D, Cmd+[ / Cmd+])."
        case .tmuxPerSession:
            return "Launch each repo/workspace in a deterministic tmux session. "
                + "Use tmux keybindings inside the terminal."
        }
    }

    static func resolve(
        from userDefaults: UserDefaults = LaunchPreferences.defaults,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalMultiplexingMode {
        resolve(rawValue: userDefaults.string(forKey: storageKey), environment: environment)
    }

    static func resolve(
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
