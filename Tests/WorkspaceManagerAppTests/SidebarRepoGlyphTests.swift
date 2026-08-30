import SwiftUI
import Testing

@testable import WorkspaceManager

@Suite("Repo identity glyph")
struct SidebarRepoGlyphTests {
    /// The glyph's whole point is that a repo wears one color forever. `Hasher` is seeded per
    /// process, so these pinned values are the guard against anyone reaching for it: the hash
    /// is allowed to change only by deliberately repainting every repo at once.
    @Test("Hue is pinned to the name, not to a per-process seed")
    func hueIsPinnedToTheName() {
        #expect(SidebarChrome.RepoGlyph.hue(for: "workspaces") == Double(943) / 3600)
        #expect(SidebarChrome.RepoGlyph.hue(for: "skills") == Double(1535) / 3600)
    }

    @Test("The same name always yields the same hue")
    func hueIsDeterministic() {
        for name in Self.names {
            #expect(SidebarChrome.RepoGlyph.hue(for: name) == SidebarChrome.RepoGlyph.hue(for: name))
        }
    }

    @Test("Hue stays inside the color wheel")
    func hueStaysInRange() {
        for name in Self.names {
            let hue = SidebarChrome.RepoGlyph.hue(for: name)
            #expect(hue >= 0)
            #expect(hue < 1)
        }
    }

    /// Collisions are possible in principle — 3600 hues, and neighbours look alike anyway —
    /// but a realistic set of repo names must not land on top of each other.
    @Test("Distinct names take distinct hues")
    func distinctNamesTakeDistinctHues() {
        let hues = Set(Self.names.map { SidebarChrome.RepoGlyph.hue(for: $0) })
        #expect(hues.count == Self.names.count)
    }

    /// The hash runs over NFC-normalized UTF-8: spellings Swift already treats as equal
    /// strings must wear the same color.
    @Test("Canonically equivalent spellings share a hue")
    func canonicallyEquivalentNamesShareAHue() {
        #expect(
            SidebarChrome.RepoGlyph.hue(for: "caf\u{E9}")
                == SidebarChrome.RepoGlyph.hue(for: "cafe\u{301}"))
    }

    @Test("A one-character difference moves the hue")
    func neighbouringNamesDiverge() {
        #expect(SidebarChrome.RepoGlyph.hue(for: "skills") != SidebarChrome.RepoGlyph.hue(for: "skill"))
        #expect(SidebarChrome.RepoGlyph.hue(for: "workspaces") != SidebarChrome.RepoGlyph.hue(for: "Workspaces"))
    }

    @Test("The monogram is the first non-blank character, uppercased")
    func monogramTakesTheFirstCharacter() {
        #expect(SidebarChrome.RepoGlyph.monogram(for: "workspaces") == "W")
        #expect(SidebarChrome.RepoGlyph.monogram(for: "Bertram-Chat") == "B")
        #expect(SidebarChrome.RepoGlyph.monogram(for: "  skills") == "S")
        #expect(SidebarChrome.RepoGlyph.monogram(for: "42-answers") == "4")
        #expect(SidebarChrome.RepoGlyph.monogram(for: "über-repo") == "Ü")
    }

    /// "ß".uppercased() is "SS": the glyph is one square, so it shows one character.
    @Test("The monogram stays a single character")
    func monogramStaysOneCharacter() {
        #expect(SidebarChrome.RepoGlyph.monogram(for: "ßeta") == "S")
    }

    @Test("A name with nothing to abbreviate falls back to a neutral glyph")
    func emptyNameFallsBackToPlaceholder() {
        #expect(SidebarChrome.RepoGlyph.monogram(for: "") == SidebarChrome.RepoGlyph.placeholderMonogram)
        #expect(SidebarChrome.RepoGlyph.monogram(for: "   ") == SidebarChrome.RepoGlyph.placeholderMonogram)
        #expect(SidebarChrome.RepoGlyph.fill(for: "") == SidebarChrome.RepoGlyph.placeholderFill)
        #expect(SidebarChrome.RepoGlyph.fill(for: " \t ") == SidebarChrome.RepoGlyph.placeholderFill)
    }

    @Test("A named repo gets a hue, not the placeholder")
    func namedRepoGetsAHue() {
        let fill = SidebarChrome.RepoGlyph.fill(for: "workspaces")
        #expect(fill != SidebarChrome.RepoGlyph.placeholderFill)
        #expect(
            fill
                == Color(
                    hue: SidebarChrome.RepoGlyph.hue(for: "workspaces"),
                    saturation: SidebarChrome.RepoGlyph.saturation,
                    brightness: SidebarChrome.RepoGlyph.brightness
                )
        )
    }

    private static let names = [
        "workspaces",
        "bertram-chat",
        "skills",
        "bread-builder",
        "dotclaude",
        "folio",
        "orca",
        "a-very-long-repository-name-that-cannot-fit",
    ]
}
