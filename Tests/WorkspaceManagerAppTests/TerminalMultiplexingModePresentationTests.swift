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

    @Test("Each mode's summary names both per-tab commands")
    func summaryNamesPerTabChoice() {
        for mode in TerminalMultiplexingMode.allCases {
            #expect(mode.summary.contains("New Terminal Tab (Cmd+T)"))
            #expect(mode.summary.contains("New Persistent Tab (Cmd+Shift+T)"))
        }
    }
}
