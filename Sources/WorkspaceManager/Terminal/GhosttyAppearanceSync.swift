//
//  GhosttyAppearanceSync.swift
//  WorkspaceManager
//

import AppKit
import GhosttyKit

enum GhosttyAppearanceSync {
    static func colorScheme(for appearance: NSAppearance?) -> ghostty_color_scheme_e {
        let resolvedAppearance = appearance ?? NSAppearance(named: .aqua)
        let bestMatch = resolvedAppearance?.bestMatch(from: [.darkAqua, .aqua])
        if bestMatch == .darkAqua {
            return GHOSTTY_COLOR_SCHEME_DARK
        }
        return GHOSTTY_COLOR_SCHEME_LIGHT
    }

    static func isEqual(_ lhs: ghostty_color_scheme_e, _ rhs: ghostty_color_scheme_e) -> Bool {
        lhs.rawValue == rhs.rawValue
    }

    static func isDark(_ colorScheme: ghostty_color_scheme_e) -> Bool {
        isEqual(colorScheme, GHOSTTY_COLOR_SCHEME_DARK)
    }

    static func isLight(_ colorScheme: ghostty_color_scheme_e) -> Bool {
        isEqual(colorScheme, GHOSTTY_COLOR_SCHEME_LIGHT)
    }
}
