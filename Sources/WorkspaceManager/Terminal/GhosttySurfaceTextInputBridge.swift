//
//  GhosttySurfaceTextInputBridge.swift
//  WorkspaceManager
//
//  Every way text reaches a libghostty surface without a physical key: IME commits through
//  `ghostty_surface_text`, pastes (the automation input verb, drag and drop) through
//  `ghostty_surface_paste_text` so Ghostty's paste protection applies, and app-authored launch
//  commands through `ghostty_surface_text`, which is trusted and skips that protection.
//

import AppKit
import GhosttyKit

/// What happened to text offered to a surface as a paste.
enum GhosttyPasteOutcome: Equatable {
    case delivered
    /// Ghostty's paste protection asked to confirm the paste: multi-line text while the program
    /// has not enabled bracketed paste (each line would run as a command), or text carrying an
    /// end-of-paste marker. The app has no confirmation UI, so it declines and nothing is sent.
    case heldByPasteProtection
    case noSurface
}

@MainActor
enum GhosttySurfaceTextInputBridge {
    /// The surface a `pasteText` call is delivering into, and whether Ghostty asked to confirm
    /// it. `ghostty_surface_paste_text` raises that request synchronously on the calling
    /// thread, so the clipboard bridge's confirm callback lands here before the call returns.
    private static var pasteInFlight: (surfaceAddress: UInt, held: Bool)?

    /// IME commit path, and AppKit text insertion outside a key event (the emoji picker,
    /// dictation). Inside `keyDown` the text joins the key event instead, so typed characters go
    /// through Ghostty's key encoder rather than either text entry point.
    static func insertText(into view: GhosttySurfaceView, string: Any, replacementRange: NSRange) {
        _ = replacementRange

        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = ""
        }

        if view.keyTextAccumulator != nil {
            view.keyTextAccumulator?.append(text)
            return
        }

        guard let surface = view.surface else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    /// Paste path for text the user or an automation caller hands over whole: the automation
    /// input verb and drag and drop. Ghostty frames it in bracketed-paste markers when the
    /// program enabled mode 2004 and applies paste protection, which this app always declines.
    /// Goes straight to the live surface, bypassing the `keyTextAccumulator` IME diversion, so a
    /// half-composed keyboard event cannot swallow it.
    static func pasteText(into view: GhosttySurfaceView, text: String) -> GhosttyPasteOutcome {
        guard let surface = view.surface else { return .noSurface }
        let surfaceAddress = UInt(bitPattern: surface)
        pasteInFlight = (surfaceAddress, false)
        defer { pasteInFlight = nil }
        text.withCString { pointer in
            ghostty_surface_paste_text(surface, pointer, UInt(text.utf8.count))
        }
        return pasteInFlight?.held == true ? .heldByPasteProtection : .delivered
    }

    /// Called from Ghostty's confirm-paste callback, which declines every request. Marks an
    /// in-flight `pasteText` into the same surface as held; a confirmation raised outside one
    /// (a clipboard paste from a key binding) has no caller waiting on it.
    static func notePasteConfirmationRequested(surfaceAddress: UInt) {
        guard pasteInFlight?.surfaceAddress == surfaceAddress else { return }
        pasteInFlight?.held = true
    }

    /// Launch path for commands the app itself composed (a session's initial command, the tmux
    /// repair script). They skip paste protection: the app wrote them, no one is placed to
    /// confirm them, and they can land before the shell has enabled bracketed paste. Ghostty
    /// still delivers them as a paste. Returns false when the view has no live surface.
    static func writeLaunchCommand(into view: GhosttySurfaceView, text: String) -> Bool {
        guard let surface = view.surface else { return false }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
        return true
    }

    /// Submit path: presses and releases Return through the key-event pipeline. Both text entry
    /// points deliver a paste, so a CR appended to the text would arrive inside the
    /// bracketed-paste envelope and shells would insert it literally instead of executing. A
    /// synthetic key event encodes CR outside any paste envelope, matching a physical Return.
    static func sendAutomationReturn(into view: GhosttySurfaceView) -> Bool {
        guard let surface = view.surface else { return false }
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = 0x24  // kVK_Return
            keyEvent.text = nil
            keyEvent.composing = false
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0x0D
            _ = ghostty_surface_key(surface, keyEvent)
        }
        return true
    }

    static func doCommand(in view: GhosttySurfaceView, selector: Selector) {
        if let lastPerformKeyEvent = view.lastPerformKeyEvent,
            let currentEvent = NSApp.currentEvent,
            lastPerformKeyEvent == currentEvent.timestamp
        {
            NSApp.sendEvent(currentEvent)
            return
        }

        guard let surface = view.surface else { return }

        switch selector {
        case #selector(NSResponder.moveToBeginningOfDocument(_:)):
            _ = view.performBindingAction("scroll_to_top", surface: surface)

        case #selector(NSResponder.moveToEndOfDocument(_:)):
            _ = view.performBindingAction("scroll_to_bottom", surface: surface)

        default:
            break
        }
    }

    static func setMarkedText(
        in view: GhosttySurfaceView,
        string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        _ = selectedRange
        _ = replacementRange

        if let attributed = string as? NSAttributedString {
            view.markedText = NSMutableAttributedString(attributedString: attributed)
        } else if let plain = string as? String {
            view.markedText = NSMutableAttributedString(string: plain)
        } else {
            view.markedText = NSMutableAttributedString()
        }

        view.syncPreedit(clearIfNeeded: true)
    }

    static func unmarkText(in view: GhosttySurfaceView) {
        view.markedText = NSMutableAttributedString()
        view.syncPreedit(clearIfNeeded: true)
    }

    static func selectedRange(in view: GhosttySurfaceView) -> NSRange {
        _ = view
        return NSRange(location: NSNotFound, length: 0)
    }

    static func markedRange(in view: GhosttySurfaceView) -> NSRange {
        guard view.markedText.length > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }

        return NSRange(location: 0, length: view.markedText.length)
    }

    static func hasMarkedText(in view: GhosttySurfaceView) -> Bool {
        view.markedText.length > 0
    }

    static func attributedSubstring(
        in view: GhosttySurfaceView,
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        _ = view
        actualRange?.pointee = range
        return nil
    }

    static func validAttributesForMarkedText(in view: GhosttySurfaceView) -> [NSAttributedString.Key] {
        _ = view
        return []
    }

    static func firstRect(
        in view: GhosttySurfaceView,
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        _ = range

        guard let surface = view.surface else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return .zero
        }

        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let localRect = NSRect(x: x, y: view.bounds.height - y - height, width: width, height: height)
        let windowRect = view.convert(localRect, to: nil)
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)

        return view.window?.convertToScreen(windowRect) ?? .zero
    }

    static func characterIndex(in view: GhosttySurfaceView, for point: NSPoint) -> Int {
        _ = view
        _ = point
        return NSNotFound
    }
}
