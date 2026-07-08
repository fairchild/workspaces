//
//  GhosttySurfaceView.swift
//  WorkspaceManager
//

import AppKit
import Foundation
import GhosttyKit
import QuartzCore

enum GhosttySurfaceRetirementCloseError: LocalizedError {
    case processStillRunning(title: String)
    case timedOut(title: String)

    var errorDescription: String? {
        switch self {
        case .processStillRunning(let title):
            return
                "Terminal '\(title)' still has a running process. Close it before archiving or deleting the workspace."
        case .timedOut(let title):
            return "Terminal '\(title)' did not exit before the workspace lifecycle timeout."
        }
    }
}

@MainActor
final class GhosttySurfaceView: NSView, RetirementClosableSurface {
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
    private(set) var latestScrollbarState: GhosttyScrollbarState?
    private var didProcessExit = false
    private var promptReadinessSignposts: TerminalPromptReadinessSignpostController
    private var lastScaleAndSize: GhosttySurfaceScaleCalculator.ScaleAndSize?
    private var trackingAreaInstalled = false
    var workingDirectoryPath: String { workingDirectory.path }
    var contextMenuProvider: (() -> NSMenu?)?
    var onScrollbarStateChange: ((GhosttyScrollbarState) -> Void)?
    var onTerminalTitleChanged: ((String) -> Void)?

    init(
        launchContext: TerminalSessionLaunchContext,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil
    ) {
        self.workingDirectory = launchContext.workingDirectory
        self.promptReadinessSignposts = TerminalPromptReadinessSignpostController(
            hostSessionID: launchContext.promptReadinessHostSessionID
        )
        self.onProcessExit = onProcessExit
        self.onCloseConfirmationRequired = onCloseConfirmationRequired
        self.terminalConfig = GhosttyTerminalConfig(launchContext: launchContext)
        self.readinessDiagnostics = TerminalReadinessDiagnostics(
            workingDirectoryName: workingDirectory.lastPathComponent,
            shellProfileMode: terminalConfig.shellProfileModeLabel
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.wantsLayer = true
        registerForDraggedTypes(GhosttyDroppedContentFormatter.pasteboardTypes)

        createSurfaceIfNeeded()
    }

    convenience init(
        workingDirectory: URL,
        hostSessionID: UUID? = nil,
        hooksSocketPath: String? = nil,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil
    ) {
        self.init(
            launchContext: .directoryBacked(
                workingDirectory: workingDirectory,
                hostSessionID: hostSessionID,
                hooksSocketPath: hooksSocketPath
            ),
            onProcessExit: onProcessExit,
            onCloseConfirmationRequired: onCloseConfirmationRequired
        )
    }

    convenience init(
        customCommand: String,
        onProcessExit: (() -> Void)? = nil,
        onCloseConfirmationRequired: (() -> Void)? = nil
    ) {
        self.init(
            launchContext: .customCommand(customCommand),
            onProcessExit: onProcessExit,
            onCloseConfirmationRequired: onCloseConfirmationRequired
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        MainActor.assumeIsolated {
            GhosttyAppManager.shared.unregisterSurface(self)

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
            syncLayerContentsScale()
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
        syncLayerContentsScale()
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
        let previousTitle = terminalTitle
        terminalTitle = title
        if previousTitle != title {
            onTerminalTitleChanged?(title)
        }
        guard !title.isEmpty else { return }
        observePromptReadinessSignal(.setTitle)
    }

    func updateWorkingDirectory(_ path: String?) {
        currentWorkingDirectory = path
        guard let path, !path.isEmpty else { return }
        observePromptReadinessSignal(.pwd)
    }

    private func observePromptReadinessSignal(_ signal: TerminalReadinessDiagnostics.Signal) {
        readinessDiagnostics.observeShellSignal(signal)
        completePromptReadinessSignpostsIfNeeded(signal: signal)
    }

    private func completePromptReadinessSignpostsIfNeeded(signal: TerminalReadinessDiagnostics.Signal) {
        promptReadinessSignposts.completeIfNeeded(signal: signal)
    }

    /// Terminal attention fallback: an OSC 9 / OSC 777 notification from the
    /// agent. Forward to the registry via the OSC router so the sidebar dot,
    /// macOS notifications, and the dedup window all see the same event.
    func handleDesktopNotification(
        title: String?,
        body: String,
        surfaceAddress: UInt
    ) {
        AgentOSCRouter.shared.handleDesktopNotification(
            title: title,
            body: body,
            surfaceView: self,
            surfaceAddress: surfaceAddress
        )
    }

    /// Terminal attention fallback: terminal BEL. Routed through the OSC router
    /// so the registry has a single ingestion path for non-hook attention
    /// signals.
    func handleRingBell(surfaceAddress: UInt) {
        AgentOSCRouter.shared.handleRingBell(
            surfaceView: self,
            surfaceAddress: surfaceAddress
        )
    }

    func updateScrollbarState(_ state: GhosttyScrollbarState) {
        latestScrollbarState = state
        onScrollbarStateChange?(state)
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

    // MARK: - Retirement close seam

    var isSurfaceAlive: Bool {
        surface != nil
    }

    var hasProcessExited: Bool {
        guard let surface else { return false }
        return ghostty_surface_process_exited(surface)
    }

    func requestSurfaceClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }

    var retirementDisplayTitle: String {
        let title = terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }

        let fallback = workingDirectory.lastPathComponent
        return fallback.isEmpty ? "Terminal" : fallback
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
        GhosttyAppManager.shared.registerSurface(self)
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

    private func syncLayerContentsScale() {
        guard let backingScaleFactor = window?.backingScaleFactor else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = backingScaleFactor
        CATransaction.commit()
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
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            GhosttyScrollInput.mods(from: event)
        )
    }

    func scrollToRow(_ row: Int) {
        guard let surface else { return }
        _ = performBindingAction("scroll_to_row:\(row)", surface: surface)
    }

    func readPlainScreenText() -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return "" }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard GhosttyDroppedContentFormatter.accepts(types: sender.draggingPasteboard.types) else {
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let content = GhosttyDroppedContentFormatter.content(from: sender.draggingPasteboard) else {
            return false
        }

        TerminalFocusManager.shared.requestFocus(for: self)
        insertText(content, replacementRange: NSRange(location: 0, length: 0))
        return true
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
