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

extension NSColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1.0
        )
    }
}
