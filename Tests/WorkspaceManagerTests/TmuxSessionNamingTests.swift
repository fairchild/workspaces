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

    @Test("A labelled sibling is distinct from the primary and reproducible from its label")
    func labeledNameIsDistinctAndReproducible() {
        let labeled = TmuxSessionNaming.labeledName(for: directory, label: "review")

        #expect(labeled != TmuxSessionNaming.defaultName(for: directory))
        #expect(labeled.hasPrefix(TmuxSessionNaming.defaultName(for: directory)))
        // Reproducible from the label alone is the point: a caller who launched with
        // `--name review` can re-derive the handle without having kept it.
        #expect(labeled == TmuxSessionNaming.labeledName(for: directory, label: "review"))
        #expect(labeled != TmuxSessionNaming.labeledName(for: directory, label: "ship"))
    }

    @Test("A label carrying tmux target syntax is sanitized like every other component")
    func labeledNameSanitizesLabel() {
        let labeled = TmuxSessionNaming.labeledName(for: directory, label: "Two Words:v1.2")

        #expect(!labeled.contains(":"))
        #expect(!labeled.contains("."))
        #expect(!labeled.contains(" "))
    }
}
