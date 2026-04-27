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

    @Test("Next color scheme skips duplicate application unless forced")
    func nextColorSchemeSkipsDuplicatesUnlessForced() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let darkScheme = GhosttyAppearanceSync.colorScheme(for: appearance)

        #expect(
            GhosttyAppearanceSync.nextColorScheme(
                for: appearance,
                currentColorScheme: darkScheme
            ) == nil
        )
        #expect(
            GhosttyAppearanceSync.nextColorScheme(
                for: appearance,
                currentColorScheme: darkScheme,
                force: true
            )?.rawValue == darkScheme.rawValue
        )
    }

    @Test("Next color scheme returns resolved scheme for first application")
    func nextColorSchemeReturnsResolvedSchemeForFirstApplication() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let darkScheme = GhosttyAppearanceSync.colorScheme(for: appearance)

        let nextScheme = GhosttyAppearanceSync.nextColorScheme(
            for: appearance,
            currentColorScheme: nil
        )

        #expect(nextScheme?.rawValue == darkScheme.rawValue)
    }

    @Test("Resolved next color scheme skips duplicates unless forced")
    func resolvedNextColorSchemeSkipsDuplicatesUnlessForced() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let lightScheme = GhosttyAppearanceSync.colorScheme(for: appearance)

        #expect(
            GhosttyAppearanceSync.nextColorScheme(
                resolvedColorScheme: lightScheme,
                currentColorScheme: lightScheme
            ) == nil
        )
        #expect(
            GhosttyAppearanceSync.nextColorScheme(
                resolvedColorScheme: lightScheme,
                currentColorScheme: lightScheme,
                force: true
            )?.rawValue == lightScheme.rawValue
        )
    }

    @Test("Resolved next color scheme returns new values when the scheme changes")
    func resolvedNextColorSchemeReturnsChangedValues() throws {
        let darkAppearance = try #require(NSAppearance(named: .darkAqua))
        let lightAppearance = try #require(NSAppearance(named: .aqua))
        let nextScheme = GhosttyAppearanceSync.nextColorScheme(
            resolvedColorScheme: GhosttyAppearanceSync.colorScheme(for: darkAppearance),
            currentColorScheme: GhosttyAppearanceSync.colorScheme(for: lightAppearance)
        )

        #expect(nextScheme.map(GhosttyAppearanceSync.isDark) == true)
    }
}
