//
//  TerminalMultiplexingMode+Presentation.swift
//  WorkspaceManager
//
//  How Settings presents the global mode: the mode a workspace's first terminal opens in.
//  Tabs choose their own mode (New Terminal Tab is plain, New Persistent Tab keeps running),
//  so the setting reads as one yes/no property rather than an app-wide multiplexer choice.
//

import WorkspaceManagerCore

extension TerminalMultiplexingMode {
    static let firstTerminalSettingLabel = "Keep a workspace's first terminal running after quitting"

    static let persistentHolderMissingNote =
        "tmux isn't installed, so terminals that would keep running open as plain shells instead."

    init(keepsFirstTerminalRunning: Bool) {
        self = keepsFirstTerminalRunning ? .persistent : .plain
    }

    var keepsFirstTerminalRunning: Bool { self == .persistent }

    var summary: String {
        let perTab =
            "Each new tab chooses for itself: New Terminal Tab (Cmd+T) is a plain shell, "
            + "New Persistent Tab (Cmd+Shift+T) keeps running."
        switch self {
        case .ghosttyManagedSplits:
            return "Opening a workspace, Home or a repository starts a plain shell that ends when "
                + "the app quits. \(perTab)"
        case .tmuxPerSession:
            return "Opening a workspace, Home or a repository starts a terminal held by tmux, so it "
                + "keeps running when the app quits and the next launch rejoins it. \(perTab)"
        }
    }
}
