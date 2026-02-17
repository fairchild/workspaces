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

        #expect(policy.route(for: AppChromeShortcut.toggleSidebar.chord) == .appChrome)
        #expect(policy.route(for: AppChromeShortcut.newWorkspace.chord) == .appChrome)
    }

    @Test("Non-reserved shortcuts route to Ghostty by default")
    func nonReservedShortcutsRouteToGhostty() {
        policy.clearOverrides()

        let splitChord = chord("d", modifiers: [.command])
        #expect(policy.route(for: splitChord) == .ghostty)
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

    @Test("Event routing treats key-up same as key-down for ownership decisions")
    func keyUpEventsUseSameOwnershipPolicy() {
        policy.clearOverrides()

        let sidebarDown = keyEvent(type: .keyDown, key: "b", modifiers: [.command])
        let sidebarUp = keyEvent(type: .keyUp, key: "b", modifiers: [.command])
        let splitUp = keyEvent(type: .keyUp, key: "d", modifiers: [.command])

        #expect(policy.route(for: sidebarDown) == .appChrome)
        #expect(policy.route(for: sidebarUp) == .appChrome)
        #expect(policy.route(for: splitUp) == .ghostty)
    }
}
