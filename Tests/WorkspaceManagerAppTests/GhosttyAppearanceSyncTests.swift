//
//  GhosttyAppearanceSyncTests.swift
//  WorkspaceManagerAppTests
//

import AppKit
import Testing

@testable import WorkspaceManager

@Suite("GhosttyAppearanceSync")
struct GhosttyAppearanceSyncTests {
    @Test("Maps dark appearances to Ghostty dark scheme")
    func mapsDarkAppearance() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let scheme = GhosttyAppearanceSync.colorScheme(for: appearance)
        #expect(GhosttyAppearanceSync.isDark(scheme))
    }

    @Test("Maps light appearances to Ghostty light scheme")
    func mapsLightAppearance() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let scheme = GhosttyAppearanceSync.colorScheme(for: appearance)
        #expect(GhosttyAppearanceSync.isLight(scheme))
    }

    @Test("Nil appearance defaults to Ghostty light scheme")
    func nilAppearanceDefaultsToLight() {
        let scheme = GhosttyAppearanceSync.colorScheme(for: nil)
        #expect(GhosttyAppearanceSync.isLight(scheme))
    }
}
