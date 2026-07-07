//
//  TerminalTabRenameActionTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies the terminal tab rename commit rules before SwiftUI dispatches
//  title changes into TileTreeStore.
//

import Testing

@testable import WorkspaceManager

@Suite("TerminalTabRenameAction")
struct TerminalTabRenameActionTests {
    @Test("Unchanged titles do not create a manual override")
    func unchangedTitlesDoNotCreateManualOverride() {
        #expect(
            TerminalTabRenameAction.resolve(
                originalTitle: "Build",
                editedTitle: "Build"
            ) == .unchanged
        )
    }

    @Test("Whitespace-only edits clear the current override")
    func whitespaceOnlyEditsClearOverride() {
        #expect(
            TerminalTabRenameAction.resolve(
                originalTitle: "Build",
                editedTitle: "   "
            ) == .clearOverride
        )
    }

    @Test("Changed titles are trimmed and stored")
    func changedTitlesAreTrimmedAndStored() {
        #expect(
            TerminalTabRenameAction.resolve(
                originalTitle: "Build",
                editedTitle: "  Deploy  "
            ) == .setOverride("Deploy")
        )
    }
}
