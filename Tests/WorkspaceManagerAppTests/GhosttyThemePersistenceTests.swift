//
//  GhosttyThemePersistenceTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyThemePersistence")
struct GhosttyThemePersistenceTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "GhosttyThemePersistenceTests-\(UUID().uuidString)")!
    }

    @Test("Absent values load as an empty pair")
    func emptyByDefault() {
        let defaults = makeDefaults()
        let pair = GhosttyThemePersistence.load(from: defaults)
        #expect(pair == .empty)
        #expect(!pair.hasSelection)
    }

    @Test("Saved pair round-trips through UserDefaults")
    func roundTrip() {
        let defaults = makeDefaults()
        let pair = GhosttyThemePersistence.Pair(lightTheme: "Catppuccin Latte", darkTheme: "Dracula")
        GhosttyThemePersistence.save(pair, to: defaults)

        let loaded = GhosttyThemePersistence.load(from: defaults)
        #expect(loaded == pair)
        #expect(loaded.hasSelection)
    }

    @Test("A single populated slot still counts as a selection")
    func partialSelection() {
        let darkOnly = GhosttyThemePersistence.Pair(lightTheme: "", darkTheme: "Dracula")
        #expect(darkOnly.hasSelection)

        let lightOnly = GhosttyThemePersistence.Pair(lightTheme: "Nord", darkTheme: "")
        #expect(lightOnly.hasSelection)
    }
}
