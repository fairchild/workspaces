//
//  TerminalWindowController.swift
//  WorkspaceManager
//
//  Window controller for terminal focus management.
//

import AppKit

/// Manages focus for terminal views within a window.
/// Uses NotificationCenter instead of window delegate so SwiftUI window behavior stays intact.
///
/// Focus ownership: TerminalFocusCoordinator is the single entry point for all focus
/// restoration flows. This manager handles the low-level NSWindow first-responder mechanics
/// with a single bounded fallback retry (no exponential backoff). App activation is handled
/// exclusively by the coordinator — this manager never calls NSApp.activate.
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
    var onAppDidBecomeActive: (@MainActor () -> Void)?
    var shouldSkipWindowFocusRestore: (@MainActor () -> Bool)?

    /// Maximum single-retry delay. Replaces the exponential backoff chain.
    private static let fallbackRetryDelay: TimeInterval = 0.1

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

    /// Request focus for a terminal with a single bounded fallback retry.
    ///
    /// The primary focus path is lifecycle-driven: the coordinator fires focus when the
    /// surface's `onSurfaceCreated` callback signals readiness. This method attempts
    /// `makeFirstResponder` immediately and, if it fails, retries exactly once after
    /// `fallbackRetryDelay` (100ms). No exponential backoff.
    func requestFocus(
        for terminal: NSView,
        isRetry: Bool = false,
        onFocused: (() -> Void)? = nil
    ) {
        InvestigationDiagnostics.emitFocus(
            phase: "focus_request_enqueued",
            fields: [
                "is_retry": isRetry ? "true" : "false",
                "had_pending_work": pendingFocusWork == nil ? "false" : "true",
            ]
        )
        pendingFocusWork?.cancel()

        let work = DispatchWorkItem { [weak self, weak terminal] in
            Task { @MainActor in
                guard let self, let terminal else { return }

                guard let window = terminal.window else {
                    InvestigationDiagnostics.emitFocus(
                        phase: isRetry
                            ? "focus_request_missing_window_terminal_lost"
                            : "focus_request_missing_window_retry",
                        fields: [
                            "is_retry": isRetry ? "true" : "false"
                        ]
                    )
                    if !isRetry {
                        self.scheduleFallbackRetry(for: terminal, onFocused: onFocused)
                    }
                    return
                }

                // When the app is inactive or the window isn't key, record intent
                // but don't force first-responder — the coordinator will re-drive
                // focus when the window becomes key.
                if !NSApp.isActive || !window.isKeyWindow {
                    InvestigationDiagnostics.emitFocus(
                        phase: "focus_request_inactive_skip",
                        fields: [
                            "is_retry": isRetry ? "true" : "false",
                            "window_key": window.isKeyWindow ? "true" : "false",
                            "app_active": NSApp.isActive ? "true" : "false",
                        ]
                    )
                    self.focusedTerminal = terminal
                    return
                }

                if let oldFocused = self.focusedTerminal, oldFocused !== terminal {
                    _ = oldFocused.resignFirstResponder()
                }

                InvestigationDiagnostics.emitFocus(
                    phase: "focus_request_make_first_responder",
                    fields: [
                        "is_retry": isRetry ? "true" : "false",
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
                            "is_retry": isRetry ? "true" : "false",
                            "window_key": window.isKeyWindow ? "true" : "false",
                        ]
                    )
                    PerformanceSignposts.endLaunchToFirstPromptIfNeeded(trigger: "terminal_focus")
                    onFocused?()
                } else if !isRetry {
                    InvestigationDiagnostics.emitFocus(
                        phase: "focus_request_failed_retry",
                        fields: [
                            "is_retry": "false",
                            "window_key": window.isKeyWindow ? "true" : "false",
                        ]
                    )
                    self.scheduleFallbackRetry(for: terminal, onFocused: onFocused)
                } else {
                    InvestigationDiagnostics.emitFocus(
                        phase: "focus_request_failed_terminal",
                        fields: [
                            "is_retry": "true",
                            "window_key": window.isKeyWindow ? "true" : "false",
                        ]
                    )
                }
            }
        }

        pendingFocusWork = work

        if isRetry {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.fallbackRetryDelay,
                execute: work
            )
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func scheduleFallbackRetry(
        for terminal: NSView,
        onFocused: (() -> Void)?
    ) {
        requestFocus(for: terminal, isRetry: true, onFocused: onFocused)
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

        // Let the coordinator handle focus if it has a pending request.
        // Only self-restore when the coordinator is idle AND the window's
        // first responder is the window itself (meaning nothing else claimed focus).
        let coordinatorHasPending = shouldSkipWindowFocusRestore?() == true
        if !coordinatorHasPending,
            window.firstResponder === window,
            let terminal = focusedTerminal
        {
            requestFocus(for: terminal)
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

}
