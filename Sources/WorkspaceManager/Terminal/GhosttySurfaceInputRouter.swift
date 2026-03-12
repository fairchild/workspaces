//
//  GhosttySurfaceInputRouter.swift
//  WorkspaceManager
//

import AppKit
import GhosttyKit

@MainActor
enum GhosttySurfaceInputRouter {
    static func handleLocalEvent(in view: GhosttySurfaceView, event: NSEvent) -> NSEvent? {
        guard let window = view.window,
            event.window != nil,
            window == event.window
        else {
            return event
        }

        switch event.type {
        case .leftMouseDown:
            let location = view.convert(event.locationInWindow, from: nil)
            guard view.hitTest(location) == view else { return event }

            if !NSApp.isActive || !window.isKeyWindow {
                window.makeFirstResponder(view)
            }
            return event

        case .keyDown:
            guard view.focused else {
                return event
            }

            let commandOrControlModifiers = event.modifierFlags.intersection([.command, .control])
            guard !commandOrControlModifiers.isEmpty else {
                return event
            }

            if ShortcutRoutingPolicy.shared.route(for: event) == .appChrome {
                return event
            }

            if performKeyEquivalent(in: view, event: event) {
                return nil
            }
            return event

        case .keyUp:
            guard view.focused else {
                return event
            }

            let commandOrControlModifiers = event.modifierFlags.intersection([.command, .control])
            guard !commandOrControlModifiers.isEmpty else {
                return event
            }

            if ShortcutRoutingPolicy.shared.route(for: event) == .appChrome {
                return event
            }
            keyUp(in: view, event: event)
            return nil

        default:
            return event
        }
    }

    static func focusAndSendMouseButton(
        in view: GhosttySurfaceView,
        event: NSEvent,
        state: ghostty_input_mouse_state_e
    ) {
        TerminalFocusManager.shared.requestFocus(for: view)
        sendMouseButton(in: view, event: event, state: state)
    }

    static func sendMouseButton(
        in view: GhosttySurfaceView,
        event: NSEvent,
        state: ghostty_input_mouse_state_e
    ) {
        guard let surface = view.surface else { return }

        let button = GhosttyInput.mouseButton(from: Int(event.buttonNumber))
        _ = ghostty_surface_mouse_button(surface, state, button, GhosttyInput.mods(from: event.modifierFlags))
    }

    static func sendMousePosition(in view: GhosttySurfaceView, event: NSEvent) {
        guard let surface = view.surface else { return }

        let position = view.convert(event.locationInWindow, from: nil)
        let y = view.frame.height - position.y
        ghostty_surface_mouse_pos(surface, position.x, y, GhosttyInput.mods(from: event.modifierFlags))
    }

    static func performKeyEquivalent(in view: GhosttySurfaceView, event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return false
        }

        if ShortcutRoutingPolicy.shared.route(for: event) == .appChrome {
            return false
        }

        guard let surface = view.surface else {
            return false
        }

        let translationMods = view.translationModifiers(for: event, surface: surface)
        let keyEvent = GhosttyInput.keyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS,
            translationMods: translationMods
        )
        var bindingFlags = ghostty_binding_flags_e(rawValue: 0)

        let bindingText =
            GhosttyInput.ghosttyCharacters(from: event)
            ?? event.charactersIgnoringModifiers
        var keyEventWithText = keyEvent
        let isGhosttyBinding: Bool
        if let bindingText, !bindingText.isEmpty {
            isGhosttyBinding = bindingText.withCString { pointer in
                keyEventWithText.text = pointer
                return ghostty_surface_key_is_binding(surface, keyEventWithText, &bindingFlags)
            }
        } else {
            keyEventWithText.text = nil
            isGhosttyBinding = ghostty_surface_key_is_binding(surface, keyEventWithText, &bindingFlags)
        }

        if isGhosttyBinding {
            keyDown(in: view, event: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else {
                return false
            }
            equivalent = "\r"

        case "/":
            guard event.modifierFlags.contains(.control),
                event.modifierFlags.isDisjoint(with: [.shift, .command, .option])
            else {
                return false
            }
            equivalent = "_"

        default:
            guard event.timestamp != 0 else {
                return false
            }

            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                view.lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent = view.lastPerformKeyEvent {
                view.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            view.lastPerformKeyEvent = event.timestamp
            return false
        }

        guard
            let replayEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )
        else {
            return false
        }

        keyDown(in: view, event: replayEvent)
        return true
    }

    static func keyDown(in view: GhosttySurfaceView, event: NSEvent) {
        guard let surface = view.surface else {
            view.interpretKeyEvents([event])
            return
        }

        let translationMods = view.translationModifiers(for: event, surface: surface)

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent =
                NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationMods,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
        }

        view.keyTextAccumulator = []
        defer { view.keyTextAccumulator = nil }

        let hadMarkedText = view.markedText.length > 0
        view.interpretKeyEvents([translationEvent])
        view.syncPreedit(clearIfNeeded: hadMarkedText)

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        if let keyTextAccumulator = view.keyTextAccumulator, !keyTextAccumulator.isEmpty {
            for text in keyTextAccumulator {
                _ = view.keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = view.keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: GhosttyInput.ghosttyCharacters(from: translationEvent),
                composing: view.markedText.length > 0 || hadMarkedText
            )
        }
    }

    static func keyUp(in view: GhosttySurfaceView, event: NSEvent) {
        _ = view.keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    static func flagsChanged(in view: GhosttySurfaceView, event: NSEvent) {
        guard !view.hasMarkedText() else { return }

        let modMask: UInt32
        switch event.keyCode {
        case 0x39: modMask = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: modMask = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: modMask = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: modMask = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: modMask = GHOSTTY_MODS_SUPER.rawValue
        default:
            return
        }

        let mods = GhosttyInput.mods(from: event.modifierFlags)
        let action: ghostty_input_action_e =
            (mods.rawValue & modMask) != 0 ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        _ = view.keyAction(action, event: event)
    }
}
