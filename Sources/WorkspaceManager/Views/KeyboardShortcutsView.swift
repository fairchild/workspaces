import SwiftUI

/// A read-only keyboard-shortcut cheat-sheet (Help → Keyboard Shortcuts), so the app's navigation
/// keys are discoverable rather than hidden. App-owned shortcuts are derived from `AppChromeShortcut`
/// so they can never drift from the real bindings; terminal/tile shortcuts are libghostty defaults and
/// are documented here as a static, clearly-labeled section (the app routes them but does not own them).

struct KeyboardShortcutRow: Identifiable, Equatable {
    let label: String
    let glyphs: String
    var id: String { label }
}

struct KeyboardShortcutSection: Identifiable {
    let title: String
    let footnote: String?
    let rows: [KeyboardShortcutRow]
    var id: String { title }
}

enum KeyboardShortcutsCatalog {
    /// App-owned shortcuts, sourced directly from `AppChromeShortcut` so the sheet stays in sync.
    static var appRows: [KeyboardShortcutRow] {
        AppChromeShortcut.allCases.map {
            KeyboardShortcutRow(label: $0.displayName, glyphs: $0.keyboardGlyphs)
        }
    }

    /// Terminal & tile shortcuts. These are libghostty's macOS defaults (the app owns none of them);
    /// the values mirror the pinned Ghostty config and the actions the app's split router handles.
    static let tilingRows: [KeyboardShortcutRow] = [
        KeyboardShortcutRow(label: "Split right", glyphs: "⌘D"),
        KeyboardShortcutRow(label: "Split down", glyphs: "⇧⌘D"),
        KeyboardShortcutRow(label: "Focus previous tile", glyphs: "⌘["),
        KeyboardShortcutRow(label: "Focus next tile", glyphs: "⌘]"),
        KeyboardShortcutRow(label: "Focus tile by direction", glyphs: "⌥⌘ ← ↑ ↓ →"),
        KeyboardShortcutRow(label: "Resize split", glyphs: "⌃⌘ ← ↑ ↓ →"),
        KeyboardShortcutRow(label: "Equalize splits", glyphs: "⌃⌘="),
    ]

    static var sections: [KeyboardShortcutSection] {
        [
            KeyboardShortcutSection(title: "App", footnote: nil, rows: appRows),
            KeyboardShortcutSection(
                title: "Terminal & Tiles",
                footnote: "Terminal defaults from the embedded terminal — active when a terminal tile has focus.",
                rows: tilingRows
            ),
        ]
    }
}

struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"

    var body: some View {
        ScrollView {
            KeyboardShortcutsContent()
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, minHeight: 540)
    }
}

/// The cheat-sheet body, split out of the `ScrollView` so it can be rendered at natural size (the
/// live window scrolls it; PR-evidence rendering and previews lay it out whole).
struct KeyboardShortcutsContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(KeyboardShortcutsCatalog.sections) { section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.headline)
                        .padding(.bottom, 2)

                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label)
                            Spacer(minLength: 24)
                            Text(row.glyphs)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }

                    if let footnote = section.footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }
}
