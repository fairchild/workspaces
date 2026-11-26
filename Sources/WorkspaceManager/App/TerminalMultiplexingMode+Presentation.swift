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
            return "Open each workspace in a terminal with its own tmux session, so it keeps running when the "
                + "app quits. New tabs are plain shells; New Persistent Tab opens one that keeps running."
        }
    }
}
