import AppKit
import Testing

@testable import WorkspaceManager

@Suite("KeyboardShortcutsCatalog")
struct KeyboardShortcutsCatalogTests {
    @Test("Every app-owned shortcut surfaces a label and glyphs derived from its real binding")
    func appRowsCoverAllShortcuts() {
        let rows = KeyboardShortcutsCatalog.appRows

        #expect(rows.count == AppChromeShortcut.allCases.count)
        for row in rows {
            #expect(!row.label.isEmpty)
            #expect(!row.glyphs.isEmpty)
        }

        // Derived from the binding, so it can't drift: ⌘B = toggle sidebar.
        let sidebar = rows.first { $0.label == AppChromeShortcut.toggleSidebar.displayName }
        #expect(sidebar?.glyphs == "⌘B")
    }

    @Test("Glyphs render modifiers in canonical macOS order with key substitutions")
    func glyphFormatting() {
        // Platform order is Control → Option → Shift → Command (Command rightmost), as macOS menus
        // render it (e.g. ⇧⌘Z), regardless of the order the flags are supplied in.
        #expect(AppChromeShortcut.keyboardGlyphs(modifiers: [.command, .shift], keyString: "b") == "⇧⌘B")
        #expect(
            AppChromeShortcut.keyboardGlyphs(modifiers: [.command, .control, .option, .shift], keyString: "d")
                == "⌃⌥⇧⌘D"
        )
        #expect(AppChromeShortcut.keyboardGlyphs(modifiers: [.control], keyString: "\t") == "⌃⇥")
        #expect(AppChromeShortcut.alternateNextTerminalTab.keyboardGlyphs == "⇧⌘]")
    }

    @Test("Catalog exposes the documented terminal/tile section")
    func tilingSectionPresent() {
        let titles = KeyboardShortcutsCatalog.sections.map(\.title)
        #expect(titles.contains("App"))
        #expect(titles.contains("Terminal & Tiles"))

        let tiling = KeyboardShortcutsCatalog.tilingRows
        #expect(tiling.contains { $0.glyphs == "⌘D" })
        #expect(tiling.contains { $0.label == "Focus tile by direction" })
    }
}
