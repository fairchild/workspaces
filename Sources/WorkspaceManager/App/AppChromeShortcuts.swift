//
//  AppChromeShortcuts.swift
//  WorkspaceManager
//
//  Shared definitions for app-owned keyboard shortcuts.
//

import AppKit
import SwiftUI

private struct AppChromeShortcutDefinition {
    let keyString: String
    let modifiers: NSEvent.ModifierFlags
    let defaultRoute: ShortcutRouteTarget
}

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
    case settings
    case workspaceSwitcher
    case commandRunner

    private var definition: AppChromeShortcutDefinition {
        switch self {
        case .toggleSidebar:
            return AppChromeShortcutDefinition(keyString: "b", modifiers: [.command], defaultRoute: .appChrome)
        case .toggleInspector:
            return AppChromeShortcutDefinition(keyString: "b", modifiers: [.command, .shift], defaultRoute: .appChrome)
        case .toggleTerminalPanel:
            return AppChromeShortcutDefinition(keyString: "j", modifiers: [.command], defaultRoute: .appChrome)
        case .newWorkspace:
            return AppChromeShortcutDefinition(keyString: "n", modifiers: [.command], defaultRoute: .appChrome)
        case .newTerminalTab:
            return AppChromeShortcutDefinition(keyString: "t", modifiers: [.command], defaultRoute: .appChrome)
        case .closeTerminalTab:
            return AppChromeShortcutDefinition(keyString: "w", modifiers: [.command], defaultRoute: .appChrome)
        case .nextTerminalTab, .previousTerminalTab:
            let modifiers: NSEvent.ModifierFlags = self == .nextTerminalTab ? [.control] : [.control, .shift]
            return AppChromeShortcutDefinition(keyString: "\t", modifiers: modifiers, defaultRoute: .appChrome)
        case .alternateNextTerminalTab:
            return AppChromeShortcutDefinition(keyString: "]", modifiers: [.command, .shift], defaultRoute: .appChrome)
        case .alternatePreviousTerminalTab:
            return AppChromeShortcutDefinition(keyString: "[", modifiers: [.command, .shift], defaultRoute: .appChrome)
        case .openInEditor:
            return AppChromeShortcutDefinition(keyString: "o", modifiers: [.command, .shift], defaultRoute: .ghostty)
        case .settings:
            return AppChromeShortcutDefinition(keyString: ",", modifiers: [.command], defaultRoute: .appChrome)
        case .workspaceSwitcher:
            return AppChromeShortcutDefinition(keyString: "p", modifiers: [.command], defaultRoute: .appChrome)
        case .commandRunner:
            return AppChromeShortcutDefinition(
                keyString: "p",
                modifiers: [.command, .shift],
                defaultRoute: .appChrome
            )
        }
    }

    var keyString: String {
        definition.keyString
    }

    var keyCharacter: Character {
        Character(keyString)
    }

    var appKitModifiers: NSEvent.ModifierFlags {
        definition.modifiers
    }

    var defaultRoute: ShortcutRouteTarget {
        definition.defaultRoute
    }

    var eventModifiers: EventModifiers {
        EventModifiers(appKitModifiers: appKitModifiers)
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
    static let appOwnedDefaults: [AppChromeShortcut] =
        AppChromeShortcut.allCases.filter { $0.defaultRoute == .appChrome }

    static let appOwnedDefaultChords: Set<ShortcutChord> = Set(appOwnedDefaults.map(\.chord))
}

extension EventModifiers {
    fileprivate init(appKitModifiers: NSEvent.ModifierFlags) {
        self = []
        if appKitModifiers.contains(.command) { insert(.command) }
        if appKitModifiers.contains(.control) { insert(.control) }
        if appKitModifiers.contains(.option) { insert(.option) }
        if appKitModifiers.contains(.shift) { insert(.shift) }
    }
}
