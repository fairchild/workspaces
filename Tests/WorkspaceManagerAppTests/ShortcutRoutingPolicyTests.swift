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
}
