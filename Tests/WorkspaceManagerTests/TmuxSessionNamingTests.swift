//
//  TmuxSessionNamingTests.swift
//  WorkspaceManagerTests
//
//  Pins the canonical tmux naming contract: the directory derivation restore and
//  launch both depend on staying deterministic, and split-pane names staying
//  distinct from the primary's while remaining valid tmux session names.
//

import Foundation
import Testing

@testable import WorkspaceManagerCore

@Suite("TmuxSessionNaming")
struct TmuxSessionNamingTests {
    private let directory = URL(fileURLWithPath: "/private/tmp/repo-a")

    @Test("The directory derivation is deterministic and path-distinct")
    func defaultNameIsDeterministic() {
        let other = URL(fileURLWithPath: "/private/tmp/repo-b")

        #expect(TmuxSessionNaming.defaultName(for: directory) == TmuxSessionNaming.defaultName(for: directory))
        #expect(TmuxSessionNaming.defaultName(for: directory) != TmuxSessionNaming.defaultName(for: other))
        #expect(TmuxSessionNaming.defaultName(for: directory).hasPrefix("wm-repo-a-"))
    }

    @Test("A split pane's name differs from the primary's for the same directory")
    func splitPaneNameIsDistinctFromPrimary() {
        let paneID = UUID()
        let splitName = TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: paneID)

        #expect(splitName != TmuxSessionNaming.defaultName(for: directory))
        #expect(splitName.hasPrefix(TmuxSessionNaming.defaultName(for: directory)))
    }

    @Test("Two panes in one directory get distinct names")
    func siblingPanesGetDistinctNames() {
        let first = TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: UUID())
        let second = TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: UUID())

        #expect(first != second)
    }

    @Test("A split pane's name is stable for its pane session id")
    func splitPaneNameIsStablePerPane() {
        let paneID = UUID()

        #expect(
            TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: paneID)
                == TmuxSessionNaming.splitPaneName(for: directory, paneSessionID: paneID))
    }

    @Test("Names avoid characters tmux treats specially in targets")
    func namesUseSafeCharacters() {
        let odd = URL(fileURLWithPath: "/private/tmp/My Repo.Name")
        for name in [
            TmuxSessionNaming.defaultName(for: odd),
            TmuxSessionNaming.splitPaneName(for: odd, paneSessionID: UUID()),
        ] {
            #expect(!name.contains(":"))
            #expect(!name.contains("."))
            #expect(!name.contains(" "))
        }
    }
}
