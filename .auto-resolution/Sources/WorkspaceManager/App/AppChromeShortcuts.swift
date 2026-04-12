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
    case toggleTerminalPanel
    case newWorkspace
    case openInEditor

    var keyCharacter: Character {
        switch self {
        case .toggleSidebar:
            return "b"
        case .toggleInspector:
            return "b"
        case .toggleTerminalPanel:
            return "j"
        case .newWorkspace:
            return "t"
        case .openInEditor:
            return "o"
        }
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        switch self {
        case .toggleSidebar:
            return [.command]
        case .toggleInspector:
            return [.command, .shift]
        case .toggleTerminalPanel:
            return [.command]
        case .newWorkspace:
            return [.command, .shift]
        case .openInEditor:
            return [.command, .shift]
        }
    }

    var eventModifiers: EventModifiers {
        switch self {
        case .toggleSidebar:
            return [.command]
        case .toggleInspector:
            return [.command, .shift]
        case .toggleTerminalPanel:
            return [.command]
        case .newWorkspace:
            return [.command, .shift]
        case .openInEditor:
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
    // Keep this list intentionally narrow; context-dependent shortcuts can be
    // routed via ShortcutRoutingPolicy overrides.
    static let appOwnedDefaults: [AppChromeShortcut] = [
        .toggleSidebar,
        .toggleInspector,
        .toggleTerminalPanel,
        .newWorkspace,
    ]

    static let appOwnedDefaultChords: Set<ShortcutChord> = Set(appOwnedDefaults.map(\.chord))
}
