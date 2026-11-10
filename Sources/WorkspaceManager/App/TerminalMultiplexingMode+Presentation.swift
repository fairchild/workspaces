//
//  TerminalMultiplexingMode+Presentation.swift
//  WorkspaceManager
//

import WorkspaceManagerCore

extension TerminalMultiplexingMode {
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
            return "Run each tab and split in its own tmux session, so it keeps running when the app quits. "
                + "Use tmux keybindings inside the terminal."
        }
    }
}
