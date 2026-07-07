//
//  ShortcutRoutingPolicyTests.swift
//  WorkspaceManagerAppTests
//
//  Verifies app-vs-terminal shortcut routing defaults and overrides.
//

import AppKit
import Testing

@testable import WorkspaceManager

@MainActor
@Suite("ShortcutRoutingPolicy", .serialized)
struct ShortcutRoutingPolicyTests {
    private let policy = ShortcutRoutingPolicy.shared

    private func chord(_ key: String, modifiers: NSEvent.ModifierFlags) -> ShortcutChord {
        ShortcutChord(key: key, modifiers: modifiers)
    }

    private func keyEvent(
        type: NSEvent.EventType,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: 0
        )!
    }

    @Test("App-owned shortcuts route to app chrome by default")
    func appOwnedDefaultsRouteToAppChrome() {
        policy.clearOverrides()

        for shortcut in AppChromeShortcutCatalog.appOwnedDefaults {
            #expect(policy.route(for: shortcut.chord) == .appChrome)
        }
        #expect(AppChromeShortcutCatalog.appOwnedDefaults.contains(.settings))
    }

    @Test("Standard macOS app menu shortcuts route to app chrome by default")
    func standardAppMenuShortcutsRouteToAppChrome() {
        policy.clearOverrides()

        for shortcut in StandardAppMenuShortcutCatalog.defaults {
            #expect(policy.route(for: shortcut.chord) == .appChrome)
        }

        #expect(policy.route(for: chord("q", modifiers: [.command])) == .appChrome)
        #expect(policy.route(for: chord("q", modifiers: [.command, .shift])) == .ghostty)
    }

    @Test("Command runner (Cmd+Shift+P) is app-owned so it no longer falls through to Ghostty")
    func commandRunnerRoutesToAppChrome() {
        policy.clearOverrides()

        let chord = AppChromeShortcut.commandRunner.chord
        #expect(chord == ShortcutChord(key: "p", modifiers: [.command, .shift]))
        #expect(chord != AppChromeShortcut.workspaceSwitcher.chord)
        #expect(policy.route(for: chord) == .appChrome)
        #expect(AppChromeShortcutCatalog.appOwnedDefaults.contains(.commandRunner))
    }

    @Test("Non-reserved shortcuts route to Ghostty by default")
    func nonReservedShortcutsRouteToGhostty() {
        policy.clearOverrides()

        let splitChord = chord("d", modifiers: [.command])
        #expect(policy.route(for: splitChord) == .ghostty)
        #expect(policy.route(for: AppChromeShortcut.openInEditor.chord) == .ghostty)
    }

    @Test("App-owned default catalog is derived from shortcut route policy")
    func appOwnedDefaultCatalogMatchesShortcutRoutePolicy() {
        let expectedDefaults = AppChromeShortcut.allCases.filter { $0.defaultRoute == .appChrome }

        #expect(AppChromeShortcutCatalog.appOwnedDefaults == expectedDefaults)
        #expect(!AppChromeShortcutCatalog.appOwnedDefaults.contains(.openInEditor))
        #expect(AppChromeShortcut.openInEditor.defaultRoute == .ghostty)
    }

    @Test("Overrides are applied and removable")
    func overridesCanBeSetAndCleared() {
        policy.clearOverrides()
        let splitChord = chord("d", modifiers: [.command])

        policy.setOverride(.appChrome, for: splitChord)
        #expect(policy.route(for: splitChord) == .appChrome)

        policy.setOverride(nil, for: splitChord)
        #expect(policy.route(for: splitChord) == .ghostty)
    }

    @Test("Open-in-editor chord can be promoted to app chrome via override")
    func openInEditorChordCanBeOverriddenToAppChrome() {
        policy.clearOverrides()
        let openChord = AppChromeShortcut.openInEditor.chord

        #expect(policy.route(for: openChord) == .ghostty)

        policy.setOverride(.appChrome, for: openChord)
        #expect(policy.route(for: openChord) == .appChrome)

        policy.setOverride(nil, for: openChord)
        #expect(policy.route(for: openChord) == .ghostty)
    }

    @Test("Event routing treats key-up same as key-down for ownership decisions")
    func keyUpEventsUseSameOwnershipPolicy() {
        policy.clearOverrides()

        let sidebarDown = keyEvent(type: .keyDown, key: "b", modifiers: [.command])
        let sidebarUp = keyEvent(type: .keyUp, key: "b", modifiers: [.command])
        let inspectorDown = keyEvent(type: .keyDown, key: "B", modifiers: [.command, .shift])
        let inspectorUp = keyEvent(type: .keyUp, key: "B", modifiers: [.command, .shift])
        let terminalDown = keyEvent(type: .keyDown, key: "j", modifiers: [.command])
        let terminalUp = keyEvent(type: .keyUp, key: "j", modifiers: [.command])
        let settingsDown = keyEvent(type: .keyDown, key: ",", modifiers: [.command])
        let settingsUp = keyEvent(type: .keyUp, key: ",", modifiers: [.command])
        let splitUp = keyEvent(type: .keyUp, key: "d", modifiers: [.command])

        #expect(policy.route(for: sidebarDown) == .appChrome)
        #expect(policy.route(for: sidebarUp) == .appChrome)
        #expect(policy.route(for: inspectorDown) == .appChrome)
        #expect(policy.route(for: inspectorUp) == .appChrome)
        #expect(policy.route(for: terminalDown) == .appChrome)
        #expect(policy.route(for: terminalUp) == .appChrome)
        #expect(policy.route(for: settingsDown) == .appChrome)
        #expect(policy.route(for: settingsUp) == .appChrome)
        #expect(policy.route(for: splitUp) == .ghostty)
    }
}
