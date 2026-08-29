import Foundation
import Testing
import WorkspaceManagerCore

@testable import WorkspaceManager

@Suite("Workspace row second line")
struct WorkspaceRowSecondLineTests {
    private let live = SidebarLiveSessionStatus(
        kind: .claudeCode,
        summary: "Thinking…",
        startedAt: Date(timeIntervalSince1970: 1_756_000_000)
    )

    @Test("A transient action message outranks both the session and the note")
    func statusMessageWins() {
        #expect(
            WorkspaceRowSecondLine.resolve(
                statusMessage: "Connecting...",
                liveStatus: live,
                isSelected: true,
                note: "slice 4 in review"
            ) == .statusMessage("Connecting...")
        )
    }

    @Test("The selected row's live session outranks its note")
    func liveStatusOutranksNote() {
        #expect(
            WorkspaceRowSecondLine.resolve(
                statusMessage: nil,
                liveStatus: live,
                isSelected: true,
                note: "slice 4 in review"
            ) == .liveStatus(live)
        )
    }

    /// The gate that keeps the sidebar to one running timer: a live session shows its line only
    /// on the row that is selected, whatever the sidebar hands the row.
    @Test("An unselected row never shows a live status line, and keeps its note")
    func unselectedRowIsUnchanged() {
        #expect(
            WorkspaceRowSecondLine.resolve(
                statusMessage: nil,
                liveStatus: live,
                isSelected: false,
                note: "slice 4 in review"
            ) == .note("slice 4 in review")
        )
        #expect(
            WorkspaceRowSecondLine.resolve(
                statusMessage: nil,
                liveStatus: live,
                isSelected: false,
                note: nil
            ) == .blank
        )
    }

    @Test("A selected row with no live session falls back to the note, then to nothing")
    func selectedRowWithoutSession() {
        #expect(
            WorkspaceRowSecondLine.resolve(
                statusMessage: nil,
                liveStatus: nil,
                isSelected: true,
                note: "slice 4 in review"
            ) == .note("slice 4 in review")
        )
        #expect(
            WorkspaceRowSecondLine.resolve(
                statusMessage: nil,
                liveStatus: nil,
                isSelected: true,
                note: nil
            ) == .blank
        )
    }
}
