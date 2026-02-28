//
//  TerminalMultiplexingMode.swift
//  WorkspaceManager
//

import Foundation

enum TerminalMultiplexingMode: String, CaseIterable, Identifiable {
    case ghosttyManagedSplits = "ghostty_managed_splits"
    case tmuxPerSession = "tmux_per_session"

    static let storageKey = "terminalMultiplexingMode"
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
            return "Launch each repo/workspace in a deterministic tmux session. Use tmux keybindings inside the terminal."
        }
    }

    static func resolve(
        from userDefaults: UserDefaults = .standard
    ) -> TerminalMultiplexingMode {
        guard
            let rawValue = userDefaults.string(forKey: storageKey),
            let mode = TerminalMultiplexingMode(rawValue: rawValue)
        else {
            return defaultValue
        }
        return mode
    }
}
