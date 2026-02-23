//
//  AppChromeShortcuts.swift
//  WorkspaceManager
//
//  Shared definitions for app-owned keyboard shortcuts.
//

import AppKit
import SwiftUI

enum AppChromeShortcut: CaseIterable {
    case toggleSidebar
    case toggleInspector
    case newWorkspace

    var keyCharacter: Character {
        switch self {
        case .toggleSidebar:
            return "b"
        case .toggleInspector:
            return "b"
        case .newWorkspace:
            return "t"
        }
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        switch self {
        case .toggleSidebar:
            return [.command]
        case .toggleInspector:
            return [.command, .shift]
        case .newWorkspace:
            return [.command, .shift]
        }
    }

    var eventModifiers: EventModifiers {
        switch self {
        case .toggleSidebar:
            return [.command]
        case .toggleInspector:
            return [.command, .shift]
        case .newWorkspace:
            return [.command, .shift]
        }
    }

    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(keyCharacter)
    }

    var chord: ShortcutChord {
        ShortcutChord(
            key: String(keyCharacter),
            modifiers: appKitModifiers
        )
    }
}

enum AppChromeShortcutCatalog {
    static let appOwnedDefaultChords: Set<ShortcutChord> = Set(AppChromeShortcut.allCases.map(\.chord))
}
