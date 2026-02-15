//
//  GhosttySurfaceView.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

final class GhosttySurfaceView: NSView, NSTextInputClient {
    private let workingDirectory: URL
    private let onProcessExit: (() -> Void)?

    private var terminalConfig: GhosttyTerminalConfig
    private var eventMonitor: Any?
    private var keyTextAccumulator: [String]?
    private var markedText = NSMutableAttributedString()
    private var focused = false

    private(set) var surface: ghostty_surface_t?
    private(set) var terminalTitle: String = ""
    private(set) var currentWorkingDirectory: String?
    var workingDirectoryPath: String { workingDirectory.path }

    init(workingDirectory: URL, onProcessExit: (() -> Void)? = nil) {
        self.workingDirectory = workingDirectory
        self.onProcessExit = onProcessExit
        self.terminalConfig = GhosttyTerminalConfig(workingDirectory: workingDirectory)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.wantsLayer = true

        createSurfaceIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        removeEventMonitor()

        if let surface {
            ghostty_surface_free(surface)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window {
            TerminalFocusManager.shared.registerWindow(window)
            setupEventMonitor()
            updateScaleAndSize()
            TerminalFocusManager.shared.requestFocus(for: self)
        } else {
            removeEventMonitor()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            focused = true
            if let surface {
                ghostty_surface_set_focus(surface, true)
            }
            TerminalFocusManager.shared.focusedTerminal = self
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            focused = false
            if let surface {
                ghostty_surface_set_focus(surface, false)
            }
        }
        return result
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScaleAndSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaleAndSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }

        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
    }

    // MARK: - Runtime updates

    func updateTerminalTitle(_ title: String) {
        terminalTitle = title
    }

    func updateWorkingDirectory(_ path: String?) {
        currentWorkingDirectory = path
    }

    func runtimeDidRequestClose(processAlive: Bool) {
        if !processAlive {
            onProcessExit?()
        }
    }

    // MARK: - Local event monitor

    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .leftMouseDown]) { [weak self] event in
            self?.handleLocalEvent(event)
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        guard let window,
            event.window != nil,
            window == event.window
        else {
            return event
        }

        switch event.type {
        case .leftMouseDown:
            let location = convert(event.locationInWindow, from: nil)
            guard hitTest(location) == self else { return event }

            if !NSApp.isActive || !window.isKeyWindow {
                window.makeFirstResponder(self)
            }
            return event

        case .keyUp:
            guard focused, event.modifierFlags.contains(.command) else {
                return event
            }
            keyUp(with: event)
            return nil

        default:
            return event
        }
    }

    // MARK: - Surface setup

    private func createSurfaceIfNeeded() {
        guard surface == nil else { return }

        GhosttyAppManager.shared.initializeIfNeeded()
        guard let app = GhosttyAppManager.shared.app else {
            NSLog("[GhosttySurfaceView] Ghostty app is not initialized")
            return
        }

        let createdSurface = terminalConfig.withCValue(view: self) { config in
            ghostty_surface_new(app, &config)
        }

        guard let createdSurface else {
            NSLog("[GhosttySurfaceView] ghostty_surface_new failed")
            return
        }

        surface = createdSurface
        updateScaleAndSize()
    }

    private func updateScaleAndSize() {
        guard let surface else { return }

        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let backingBounds = convertToBacking(bounds)
        let xScale = backingBounds.width / bounds.width
        let yScale = backingBounds.height / bounds.height

        ghostty_surface_set_content_scale(surface, xScale, yScale)
        ghostty_surface_set_size(
            surface,
            UInt32(max(1, Int(backingBounds.width))),
            UInt32(max(1, Int(backingBounds.height)))
        )
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        focusAndSendMouseButton(event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        sendMousePosition(event)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(from: event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    private func focusAndSendMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e) {
        TerminalFocusManager.shared.requestFocus(for: self)
        sendMouseButton(event, state: state)
    }

    private func sendMouseButton(_ event: NSEvent, state: ghostty_input_mouse_state_e) {
        guard let surface else { return }

        let button = GhosttyInput.mouseButton(from: Int(event.buttonNumber))
        _ = ghostty_surface_mouse_button(surface, state, button, GhosttyInput.mods(from: event.modifierFlags))
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }

        let position = convert(event.locationInWindow, from: nil)
        let y = frame.height - position.y
        ghostty_surface_mouse_pos(surface, position.x, y, GhosttyInput.mods(from: event.modifierFlags))
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        let translatedMods = GhosttyInput.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(
                surface,
                GhosttyInput.mods(from: event.modifierFlags)
            )
        )

        var translationMods = event.modifierFlags
        for modifier in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translatedMods.contains(modifier) {
                translationMods.insert(modifier)
            } else {
                translationMods.remove(modifier)
            }
        }

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

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let hadMarkedText = markedText.length > 0
        interpretKeyEvents([translationEvent])
        syncPreedit(clearIfNeeded: hadMarkedText)

        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        if let keyTextAccumulator, !keyTextAccumulator.isEmpty {
            for text in keyTextAccumulator {
                _ = keyAction(action, event: event, translationEvent: translationEvent, text: text)
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: GhosttyInput.ghosttyCharacters(from: translationEvent),
                composing: markedText.length > 0 || hadMarkedText
            )
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard !hasMarkedText() else { return }

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
        _ = keyAction(action, event: event)
    }

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }

        var keyEvent = GhosttyInput.keyEvent(
            from: event,
            action: action,
            translationMods: translationEvent?.modifierFlags
        )
        keyEvent.composing = composing

        if let text,
            !text.isEmpty,
            let codepoint = text.utf8.first,
            codepoint >= 0x20
        {
            return text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(surface, keyEvent)
            }
        }

        return ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let attributed = string as? NSAttributedString {
            text = attributed.string
        } else if let plain = string as? String {
            text = plain
        } else {
            text = ""
        }

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
            return
        }

        guard let surface else { return }
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(text.utf8.count))
        }
    }

    override func doCommand(by selector: Selector) {
        _ = selector
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        _ = selectedRange
        _ = replacementRange

        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else if let plain = string as? String {
            markedText = NSMutableAttributedString(string: plain)
        } else {
            markedText = NSMutableAttributedString()
        }

        syncPreedit(clearIfNeeded: true)
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        syncPreedit(clearIfNeeded: true)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else {
            return NSRange(location: NSNotFound, length: 0)
        }

        return NSRange(location: 0, length: markedText.length)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        actualRange?.pointee = range
        return nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        _ = range

        guard let surface else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return .zero
        }

        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let localRect = NSRect(x: x, y: bounds.height - y - height, width: width, height: height)
        let windowRect = convert(localRect, to: nil)
        actualRange?.pointee = NSRange(location: NSNotFound, length: 0)

        return window?.convertToScreen(windowRect) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int {
        _ = point
        return NSNotFound
    }

    private func syncPreedit(clearIfNeeded: Bool) {
        guard let surface else { return }

        if markedText.length > 0 {
            let value = markedText.string
            value.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(value.utf8.count))
            }
            return
        }

        if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
