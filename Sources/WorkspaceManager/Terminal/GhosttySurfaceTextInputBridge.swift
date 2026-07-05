//
//  GhosttySurfaceTextInputBridge.swift
//  WorkspaceManager
//

import AppKit
import GhosttyKit

@MainActor
enum GhosttySurfaceTextInputBridge {
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

    /// Automation write path: delivers text straight to the live libghostty surface, bypassing the
    /// `keyTextAccumulator` IME diversion that keyboard-driven inserts honor. Returns false when the
    /// view has no live surface to receive the bytes.
    static func writeAutomationText(into view: GhosttySurfaceView, text: String) -> Bool {
        guard let surface = view.surface else { return false }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
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
