//
//  ShortcutRoutingPolicy.swift
//  WorkspaceManager
//
//  Central policy for deciding whether a shortcut is owned by app chrome
//  or should pass through to the embedded Ghostty terminal.
//

import AppKit

enum ShortcutRouteTarget: String {
    case appChrome
    case ghostty
}

/// A normalized keyboard chord used for routing decisions.
struct ShortcutChord: Hashable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = ShortcutChord.normalizeModifiers(modifiers)
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown,
            let key = event.charactersIgnoringModifiers?.lowercased(),
            !key.isEmpty
        else {
            return nil
        }

        self.init(key: key, modifiers: event.modifierFlags)
    }

    private static func normalizeModifiers(_ raw: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        raw.intersection([.command, .control, .option, .shift])
    }

    static func == (lhs: ShortcutChord, rhs: ShortcutChord) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }
}

/// Ghostty-first routing with a tiny app-owned allowlist and optional overrides.
@MainActor
final class ShortcutRoutingPolicy {
    static let shared = ShortcutRoutingPolicy()

    /// Default behavior: terminal gets shortcuts unless explicitly app-owned.
    private let defaultRoute: ShortcutRouteTarget = .ghostty

    /// Current app-owned shortcut set. Keep this intentionally small.
    private let appOwnedDefaults: Set<ShortcutChord> = [
        ShortcutChord(key: "b", modifiers: [.command])
    ]

    /// Future user-configurable routing overrides (`App` vs `Ghostty`).
    /// Empty for now, but shape is in place to avoid ad-hoc key handling.
    private var overrides: [ShortcutChord: ShortcutRouteTarget] = [:]

    func route(for event: NSEvent) -> ShortcutRouteTarget {
        guard let chord = ShortcutChord(event: event) else {
            return defaultRoute
        }

        if let override = overrides[chord] {
            return override
        }

        if appOwnedDefaults.contains(chord) {
            return .appChrome
        }

        return defaultRoute
    }

    func setOverride(_ route: ShortcutRouteTarget?, for chord: ShortcutChord) {
        if let route {
            overrides[chord] = route
        } else {
            overrides.removeValue(forKey: chord)
        }
    }
}
