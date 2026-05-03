//
//  GhosttySurfaceView.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit

@MainActor
final class GhosttySurfaceView: NSView {
    private let workingDirectory: URL
    var onProcessExit: (() -> Void)?
    var onCloseConfirmationRequired: (() -> Void)?

    private var terminalConfig: GhosttyTerminalConfig
    private let readinessDiagnostics: TerminalReadinessDiagnostics
    var eventMonitor: Any?
    var keyTextAccumulator: [String]?
    var markedText = NSMutableAttributedString()
    var focused = false
    var lastPerformKeyEvent: TimeInterval?
    private var currentColorScheme: ghostty_color_scheme_e?

    private(set) var surface: ghostty_surface_t?
    private(set) var terminalTitle: String = ""
    private(set) var currentWorkingDirectory: String?
    private var didProcessExit = false
    private var lastScaleAndSize: GhosttySurfaceScaleCalculator.ScaleAndSize?
    private var trackingAreaInstalled = false
    var workingDirectoryPath: String { workingDirectory.path }
    var contextMenuProvider: (() -> NSMenu?)?

    init(
        workingDirectory: URL,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.onProcessExit = onProcessExit
        self.onCloseConfirmationRequired = onCloseConfirmationRequired
        self.terminalConfig = GhosttyTerminalConfig(workingDirectory: workingDirectory)
        self.readinessDiagnostics = TerminalReadinessDiagnostics(
            workingDirectoryName: workingDirectory.lastPathComponent,
            shellProfileMode: terminalConfig.shellProfileModeLabel
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.wantsLayer = true

        createSurfaceIfNeeded()
    }

    init(
        customCommand: String,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil
    ) {
        self.workingDirectory = FileManager.default.temporaryDirectory
        self.onProcessExit = onProcessExit
        self.onCloseConfirmationRequired = onCloseConfirmationRequired
        self.terminalConfig = GhosttyTerminalConfig(customCommand: customCommand)
        self.readinessDiagnostics = TerminalReadinessDiagnostics(
            workingDirectoryName: workingDirectory.lastPathComponent,
            shellProfileMode: terminalConfig.shellProfileModeLabel
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.wantsLayer = true

        createSurfaceIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }

            if let surface {
                ghostty_surface_free(surface)
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if let window {
            TerminalFocusManager.shared.registerWindow(window)
            setupEventMonitor()
            updateScaleAndSize()
            applySystemColorSchemeIfNeeded(force: true)
            let shouldSkipRestore =
                (TerminalFocusManager.shared.delegate(for: window)?.shouldSkipWindowFocusRestore(for: window))
                == true
            if !shouldSkipRestore {
                TerminalFocusManager.shared.requestFocus(for: self)
            }
        } else {
            removeEventMonitor()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySystemColorSchemeIfNeeded(force: true)
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

        guard !trackingAreaInstalled else { return }
        trackingAreaInstalled = true

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
        guard !title.isEmpty else { return }
        readinessDiagnostics.observeShellSignal(.setTitle)
    }

    func updateWorkingDirectory(_ path: String?) {
        currentWorkingDirectory = path
        guard let path, !path.isEmpty else { return }
        readinessDiagnostics.observeShellSignal(.pwd)
    }

    func runtimeDidRequestClose(processAlive: Bool) {
        if processAlive {
            onCloseConfirmationRequired?()
            return
        }

        if !processAlive, !didProcessExit {
            didProcessExit = true
            onProcessExit?()
        }
    }

    func requestClose() {
        guard let surface else {
            runtimeDidRequestClose(processAlive: false)
            return
        }
        ghostty_surface_request_close(surface)
    }

    // MARK: - Local event monitor

    private func setupEventMonitor() {
        guard eventMonitor == nil else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown]) {
            [weak self] event in
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
        GhosttySurfaceInputRouter.handleLocalEvent(in: self, event: event)
    }

    // MARK: - Surface setup

    private func createSurfaceIfNeeded() {
        guard surface == nil else { return }

        readinessDiagnostics.markSurfaceCreateStarted()

        GhosttyAppManager.shared.initializeIfNeeded()
        guard let app = GhosttyAppManager.shared.app else {
            NSLog("[GhosttySurfaceView] Ghostty app is not initialized")
            readinessDiagnostics.markSurfaceCreateFailed(reason: "ghostty_app_not_initialized")
            return
        }

        let createdSurface = terminalConfig.withCValue(view: self) { config in
            ghostty_surface_new(app, &config)
        }

        guard let createdSurface else {
            NSLog("[GhosttySurfaceView] ghostty_surface_new failed")
            readinessDiagnostics.markSurfaceCreateFailed(reason: "ghostty_surface_new_failed")
            return
        }

        surface = createdSurface
        updateScaleAndSize()
        applySystemColorSchemeIfNeeded(force: true)
        readinessDiagnostics.markSurfaceCreateSucceeded()
    }

    private func updateScaleAndSize() {
        guard let surface else { return }

        let bounds = self.bounds
        let decision = GhosttySurfaceScaleCalculator.decide(
            bounds: bounds,
            backingBounds: convertToBacking(bounds),
            last: lastScaleAndSize
        )

        guard case .update(let next) = decision else { return }

        lastScaleAndSize = next
        ghostty_surface_set_content_scale(surface, next.xScale, next.yScale)
        ghostty_surface_set_size(surface, next.width, next.height)
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        GhosttySurfaceInputRouter.focusAndSendMouseButton(in: self, event: event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func mouseUp(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMouseButton(in: self, event: event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func rightMouseDown(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMouseButton(in: self, event: event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func rightMouseUp(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMouseButton(in: self, event: event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        TerminalFocusManager.shared.requestFocus(for: self)
        return contextMenuProvider?()
    }

    override func otherMouseDown(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMouseButton(in: self, event: event, state: GHOSTTY_MOUSE_PRESS)
    }

    override func otherMouseUp(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMouseButton(in: self, event: event, state: GHOSTTY_MOUSE_RELEASE)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        GhosttySurfaceInputRouter.sendMousePosition(in: self, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMousePosition(in: self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMousePosition(in: self, event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMousePosition(in: self, event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        GhosttySurfaceInputRouter.sendMousePosition(in: self, event: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(from: event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    // MARK: - Keyboard input

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard focused || window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }

        return GhosttySurfaceInputRouter.performKeyEquivalent(in: self, event: event)
    }

    override func keyDown(with event: NSEvent) {
        GhosttySurfaceInputRouter.keyDown(in: self, event: event)
    }

    override func keyUp(with event: NSEvent) {
        GhosttySurfaceInputRouter.keyUp(in: self, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        GhosttySurfaceInputRouter.flagsChanged(in: self, event: event)
    }

    func keyAction(
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
        GhosttySurfaceTextInputBridge.insertText(
            into: self,
            string: string,
            replacementRange: replacementRange
        )
    }

    override func doCommand(by selector: Selector) {
        GhosttySurfaceTextInputBridge.doCommand(in: self, selector: selector)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        GhosttySurfaceTextInputBridge.setMarkedText(
            in: self,
            string: string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    func unmarkText() {
        GhosttySurfaceTextInputBridge.unmarkText(in: self)
    }

    func selectedRange() -> NSRange {
        GhosttySurfaceTextInputBridge.selectedRange(in: self)
    }

    func markedRange() -> NSRange {
        GhosttySurfaceTextInputBridge.markedRange(in: self)
    }

    func hasMarkedText() -> Bool {
        GhosttySurfaceTextInputBridge.hasMarkedText(in: self)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        GhosttySurfaceTextInputBridge.attributedSubstring(
            in: self,
            forProposedRange: range,
            actualRange: actualRange
        )
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        GhosttySurfaceTextInputBridge.validAttributesForMarkedText(in: self)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        GhosttySurfaceTextInputBridge.firstRect(
            in: self,
            forCharacterRange: range,
            actualRange: actualRange
        )
    }

    func characterIndex(for point: NSPoint) -> Int {
        GhosttySurfaceTextInputBridge.characterIndex(in: self, for: point)
    }

    func syncPreedit(clearIfNeeded: Bool) {
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

    func translationModifiers(
        for event: NSEvent,
        surface: ghostty_surface_t
    ) -> NSEvent.ModifierFlags {
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

        return translationMods
    }

    func performBindingAction(_ action: String, surface: ghostty_surface_t) -> Bool {
        action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    private func applySystemColorSchemeIfNeeded(force: Bool = false) {
        guard
            let resolvedColorScheme = GhosttyAppearanceSync.nextColorScheme(
                for: window?.effectiveAppearance ?? effectiveAppearance,
                currentColorScheme: currentColorScheme,
                force: force
            )
        else {
            return
        }

        if let surface {
            ghostty_surface_set_color_scheme(surface, resolvedColorScheme)
        }
        GhosttyAppManager.shared.applyColorScheme(resolvedColorScheme)
        currentColorScheme = resolvedColorScheme
    }
}

@MainActor
extension GhosttySurfaceView: @preconcurrency NSTextInputClient {}
