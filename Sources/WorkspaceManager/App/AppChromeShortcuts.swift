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
    case newTerminalTab
    case closeTerminalTab
    case nextTerminalTab
    case previousTerminalTab
    case alternateNextTerminalTab
    case alternatePreviousTerminalTab
    case openInEditor

    var keyString: String {
        switch self {
        case .toggleSidebar:
            return "b"
        case .toggleInspector:
            return "b"
        case .toggleTerminalPanel:
            return "j"
        case .newWorkspace:
            return "n"
        case .newTerminalTab:
            return "t"
        case .closeTerminalTab:
            return "w"
        case .nextTerminalTab, .previousTerminalTab:
            return "\t"
        case .alternateNextTerminalTab:
            return "]"
        case .alternatePreviousTerminalTab:
            return "["
        case .openInEditor:
            return "o"
        }
    }

    var keyCharacter: Character {
        Character(keyString)
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
            return [.command]
        case .newTerminalTab:
            return [.command]
        case .closeTerminalTab:
            return [.command]
        case .nextTerminalTab:
            return [.control]
        case .previousTerminalTab:
            return [.control, .shift]
        case .alternateNextTerminalTab, .alternatePreviousTerminalTab:
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
            return [.command]
        case .newTerminalTab:
            return [.command]
        case .closeTerminalTab:
            return [.command]
        case .nextTerminalTab:
            return [.control]
        case .previousTerminalTab:
            return [.control, .shift]
        case .alternateNextTerminalTab, .alternatePreviousTerminalTab:
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
        .newTerminalTab,
        .closeTerminalTab,
        .nextTerminalTab,
        .previousTerminalTab,
        .alternateNextTerminalTab,
        .alternatePreviousTerminalTab,
    ]

    static let appOwnedDefaultChords: Set<ShortcutChord> = Set(appOwnedDefaults.map(\.chord))
}
