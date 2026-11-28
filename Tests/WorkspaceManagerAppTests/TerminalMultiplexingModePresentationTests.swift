//
//  TerminalMultiplexingModePresentationTests.swift
//  WorkspaceManagerAppTests
//

import Testing

@testable import WorkspaceManager
@testable import WorkspaceManagerCore

@Suite("TerminalMultiplexingMode presentation")
struct TerminalMultiplexingModePresentationTests {
    @Test("The first-terminal toggle stores the existing raw values")
    func toggleMapsOntoStoredModes() {
        #expect(TerminalMultiplexingMode(keepsFirstTerminalRunning: true).rawValue == "tmux_per_session")
        #expect(TerminalMultiplexingMode(keepsFirstTerminalRunning: false).rawValue == "ghostty_managed_splits")
        for mode in TerminalMultiplexingMode.allCases {
            #expect(TerminalMultiplexingMode(keepsFirstTerminalRunning: mode.keepsFirstTerminalRunning) == mode)
        }
        #expect(!TerminalMultiplexingMode.defaultValue.keepsFirstTerminalRunning)
    }

    @Test("The setting's copy claims only what the app does")
    func copyClaimsOnlyWhatTheAppDoes() {
        let perTab =
            "Each new tab chooses for itself: New Terminal Tab (Cmd+T) is a plain shell, "
            + "New Persistent Tab (Cmd+Shift+T) keeps running."
        #expect(
            TerminalMultiplexingMode.firstTerminalSettingLabel
                == "Keep a workspace's first terminal running after quitting")
        #expect(
            TerminalMultiplexingMode.plain.summary
                == "The terminal the app opens for Home, a local workspace or a repository is a plain shell "
                + "that ends when the app quits. \(perTab)")
        #expect(
            TerminalMultiplexingMode.persistent.summary
                == "The terminal the app opens for Home, a local workspace or a repository is held by tmux, "
                + "so it keeps running when the app quits and a later launch can rejoin it. \(perTab)")
        #expect(
            TerminalMultiplexingMode.persistentHolderMissingNote
                == "tmux wasn't found, so that terminal opens as a plain shell instead.")
    }
}
