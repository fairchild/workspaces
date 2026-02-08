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
    let colors: [NSColor]

    static let defaultDark = TerminalTheme(
        foreground: NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0),
        background: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0),
        cursor: NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1.0),
        colors: [
            // Normal colors (0-7)
            NSColor(hex: "#1d1f21"),  // Black
            NSColor(hex: "#cc6666"),  // Red
            NSColor(hex: "#b5bd68"),  // Green
            NSColor(hex: "#f0c674"),  // Yellow
            NSColor(hex: "#81a2be"),  // Blue
            NSColor(hex: "#b294bb"),  // Magenta
            NSColor(hex: "#8abeb7"),  // Cyan
            NSColor(hex: "#c5c8c6"),  // White
            // Bright colors (8-15)
            NSColor(hex: "#969896"),  // Bright Black
            NSColor(hex: "#de935f"),  // Bright Red
            NSColor(hex: "#b5bd68"),  // Bright Green
            NSColor(hex: "#f0c674"),  // Bright Yellow
            NSColor(hex: "#81a2be"),  // Bright Blue
            NSColor(hex: "#b294bb"),  // Bright Magenta
            NSColor(hex: "#8abeb7"),  // Bright Cyan
            NSColor(hex: "#ffffff"),  // Bright White
        ]
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
