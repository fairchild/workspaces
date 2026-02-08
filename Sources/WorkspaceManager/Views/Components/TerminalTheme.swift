//
//  TerminalTheme.swift
//  WorkspaceManager
//
//  Terminal color theme and NSColor hex convenience
//

import AppKit

struct TerminalTheme {
    let foreground: NSColor
    let background: NSColor
    let cursor: NSColor

    static let defaultDark = TerminalTheme(
        foreground: NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0),
        background: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0),
        cursor: NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0)
    )
}
