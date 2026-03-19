//
//  TerminalWindowController.swift
//  WorkspaceManager
//
//  Window controller for terminal focus management.
//

import AppKit

/// Manages focus for terminal views within a window.
/// Uses NotificationCenter instead of window delegate so SwiftUI window behavior stays intact.
@MainActor
final class TerminalFocusManager: NSObject {

    static let shared = TerminalFocusManager()

    /// The currently focused terminal view.
    weak var focusedTerminal: NSView?

    /// Windows being managed.
    private var managedWindows = NSHashTable<NSWindow>.weakObjects()

    /// Track pending focus restoration work.
    private var pendingFocusWork: DispatchWorkItem?

    var onWindowDidBecomeKey: (@MainActor () -> Void)?
    var shouldSkipWindowFocusRestore: (@MainActor () -> Bool)?

    // MARK: - Window Registration

    func registerWindow(_ window: NSWindow) {
        guard !managedWindows.contains(window) else { return }

        managedWindows.add(window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    // MARK: - Focus Management

    /// Request focus for a terminal with retry logic.
    /// Retries with exponential backoff starting at 50ms, capped at 500ms.
    func requestFocus(
        for terminal: NSView,
        delay: TimeInterval? = nil,
        activateApp: Bool = false,
        onFocused: (() -> Void)? = nil
    ) {
        InvestigationDiagnostics.emitFocus(
            phase: "focus_request_enqueued",
            fields: [
                "activate_app": activateApp ? "true" : "false",
                "delay_ms": Self.delayFieldValue(delay),
                "had_pending_work": pendingFocusWork == nil ? "false" : "true",
            ]
        )
        pendingFocusWork?.cancel()

        let nextDelay = Self.nextRetryDelay(after: delay)
        let shouldRetry = Self.shouldRetry(after: delay)

        let work = DispatchWorkItem { [weak self, weak terminal] in
            Task { @MainActor in
                guard let self, let terminal else { return }

                guard let window = terminal.window else {
                    InvestigationDiagnostics.emitFocus(
                        phase: shouldRetry
                            ? "focus_request_missing_window_retry"
                            : "focus_request_missing_window_terminal_lost",
                        fields: [
                            "activate_app": activateApp ? "true" : "false",
                            "delay_ms": Self.delayFieldValue(delay),
                            "next_delay_ms": Self.delayFieldValue(nextDelay),
                        ]
                    )
                    if shouldRetry {
                        self.requestFocus(
                            for: terminal,
                            delay: nextDelay,
                            activateApp: activateApp,
                            onFocused: onFocused
                        )
                    }
                    return
                }

                if activateApp {
                    InvestigationDiagnostics.emitFocus(
                        phase: "focus_request_activate_app",
                        fields: [
                            "delay_ms": Self.delayFieldValue(delay),
                            "window_key": window.isKeyWindow ? "true" : "false",
                            "app_active": NSApp.isActive ? "true" : "false",
                        ]
                    )
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // Keep focus intent without stealing foreground when app is inactive.
                    if !NSApp.isActive || !window.isKeyWindow {
                        InvestigationDiagnostics.emitFocus(
                            phase: "focus_request_inactive_skip",
                            fields: [
                                "delay_ms": Self.delayFieldValue(delay),
                                "window_key": window.isKeyWindow ? "true" : "false",
                                "app_active": NSApp.isActive ? "true" : "false",
                            ]
                        )
                        self.focusedTerminal = terminal
                        return
                    }
                }

                if let oldFocused = self.focusedTerminal, oldFocused !== terminal {
                    _ = oldFocused.resignFirstResponder()
                }

                InvestigationDiagnostics.emitFocus(
                    phase: "focus_request_make_first_responder",
                    fields: [
                        "delay_ms": Self.delayFieldValue(delay),
                        "window_key": window.isKeyWindow ? "true" : "false",
                        "app_active": NSApp.isActive ? "true" : "false",
                    ]
                )
                let success = window.makeFirstResponder(terminal)
                if success {
                    self.focusedTerminal = terminal
                    InvestigationDiagnostics.emitFocus(
                        phase: "focus_request_succeeded",
                        fields: [
                            "delay_ms": Self.delayFieldValue(delay),
                            "window_key": window.isKeyWindow ? "true" : "false",
                        ]
                    )
                    PerformanceSignposts.endLaunchToFirstPromptIfNeeded(trigger: "terminal_focus")
                    onFocused?()
                } else if shouldRetry {
                    InvestigationDiagnostics.emitFocus(
                        phase: "focus_request_failed_retry",
                        fields: [
                            "delay_ms": Self.delayFieldValue(delay),
                            "next_delay_ms": Self.delayFieldValue(nextDelay),
                            "window_key": window.isKeyWindow ? "true" : "false",
                        ]
                    )
                    self.requestFocus(
                        for: terminal,
                        delay: nextDelay,
                        activateApp: activateApp,
                        onFocused: onFocused
                    )
                } else {
                    InvestigationDiagnostics.emitFocus(
                        phase: "focus_request_failed_terminal",
                        fields: [
                            "delay_ms": Self.delayFieldValue(delay),
                            "window_key": window.isKeyWindow ? "true" : "false",
                        ]
                    )
                }
            }
        }

        pendingFocusWork = work

        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    nonisolated static func nextRetryDelay(after delay: TimeInterval?) -> TimeInterval {
        if let delay {
            return min(delay * 2, 0.5)
        }
        return 0.05
    }

    nonisolated static func shouldRetry(after delay: TimeInterval?) -> Bool {
        (delay ?? 0) < 0.5
    }

    // MARK: - Focus State Synchronization

    func syncFocusState(for window: NSWindow?) {
        guard let window else { return }

        let isKeyWindow = window.isKeyWindow
        let firstResponder = window.firstResponder

        if let terminal = focusedTerminal {
            _ = isKeyWindow && firstResponder === terminal
        }
    }

    // MARK: - Window Notifications

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        InvestigationDiagnostics.emitFocus(
            phase: "window_did_become_key",
            fields: [
                "has_focused_terminal": focusedTerminal == nil ? "false" : "true"
            ]
        )

        let shouldSkipFocusedTerminalRestore = shouldSkipWindowFocusRestore?() == true
        if !shouldSkipFocusedTerminalRestore,
            window.firstResponder === window,
            let terminal = focusedTerminal
        {
            Task { @MainActor in
                self.requestFocus(for: terminal, activateApp: false)
            }
        }

        onWindowDidBecomeKey?()

        syncFocusState(for: window)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        InvestigationDiagnostics.emitFocus(
            phase: "window_did_resign_key",
            fields: [
                "has_focused_terminal": focusedTerminal == nil ? "false" : "true"
            ]
        )
        syncFocusState(for: window)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        managedWindows.remove(window)

        if focusedTerminal?.window === window {
            focusedTerminal = nil
        }
    }

    private nonisolated static func delayFieldValue(_ delay: TimeInterval?) -> String {
        guard let delay else { return "0.00" }
        return String(format: "%.2f", delay * 1000)
    }
}
