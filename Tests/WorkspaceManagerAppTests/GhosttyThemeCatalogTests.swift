//
//  GhosttyThemeCatalogTests.swift
//  WorkspaceManagerAppTests
//

import Foundation
import Testing

@testable import WorkspaceManager

@Suite("GhosttyThemeCatalog")
struct GhosttyThemeCatalogTests {
    private struct ThemesFixture {
        let directory: URL

        init(themeNames: [String]) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in themeNames {
                FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(name, isDirectory: false).path,
                    contents: Data("background = #000000\n".utf8)
                )
            }
        }

        func addHiddenFile(_ name: String) {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name, isDirectory: false).path,
                contents: Data()
            )
        }

        func addSubdirectory(_ name: String) throws {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("Enumerates regular theme files, sorted alphabetically, skipping hidden files and subdirectories")
    func enumeratesThemeFiles() throws {
        let fixture = try ThemesFixture(themeNames: ["Nord", "Dracula", "Catppuccin Mocha", "Owlet", "Light Owl"])
        defer { fixture.cleanup() }
        fixture.addHiddenFile(".DS_Store")
        try fixture.addSubdirectory("nested")

        let themes = GhosttyThemeCatalog.themes(in: fixture.directory)

        #expect(themes.map(\.name) == ["Catppuccin Mocha", "Dracula", "Light Owl", "Nord", "Owlet"])
    }

    @Test("Missing themes directory yields an empty list rather than throwing")
    func missingDirectoryYieldsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(GhosttyThemeCatalog.themes(in: missing).isEmpty)
    }

    @Test("Featured returns curated themes that exist, in curated order")
    func featuredOrdering() throws {
        let fixture = try ThemesFixture(themeNames: ["Nord", "Dracula", "Catppuccin Mocha", "Owlet"])
        defer { fixture.cleanup() }

        let all = GhosttyThemeCatalog.themes(in: fixture.directory)
        let featured = GhosttyThemeCatalog.featured(in: all)

        // Curated order from featuredNames: Catppuccin Mocha < Nord < Dracula.
        #expect(featured.map(\.name) == ["Catppuccin Mocha", "Nord", "Dracula"])
        #expect(!featured.map(\.name).contains("Owlet"))
    }

    @Test("Ranking puts prefix matches above substring matches")
    func rankingPrefixThenSubstring() throws {
        let fixture = try ThemesFixture(themeNames: ["Owlet", "Light Owl", "Nord"])
        defer { fixture.cleanup() }

        let all = GhosttyThemeCatalog.themes(in: fixture.directory)
        let ranked = GhosttyThemeCatalog.rank(all, query: "owl")

        #expect(ranked.map(\.name) == ["Owlet", "Light Owl"])
    }

    @Test("Empty query returns every theme alphabetically")
    func emptyQueryReturnsAll() throws {
        let fixture = try ThemesFixture(themeNames: ["Nord", "Dracula"])
        defer { fixture.cleanup() }

        let all = GhosttyThemeCatalog.themes(in: fixture.directory)
        #expect(GhosttyThemeCatalog.rank(all, query: "").map(\.name) == ["Dracula", "Nord"])
        #expect(GhosttyThemeCatalog.rank(all, query: "   ").map(\.name) == ["Dracula", "Nord"])
    }

    @Test("matches is case-insensitive and treats empty query as a match")
    func matchesSemantics() {
        let theme = GhosttyTheme(name: "Catppuccin Mocha")
        #expect(GhosttyThemeCatalog.matches(theme, query: ""))
        #expect(GhosttyThemeCatalog.matches(theme, query: "MOCHA"))
        #expect(GhosttyThemeCatalog.matches(theme, query: "ppucc"))
        #expect(!GhosttyThemeCatalog.matches(theme, query: "dracula"))
    }
}
