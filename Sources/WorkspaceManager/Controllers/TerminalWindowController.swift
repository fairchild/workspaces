//
//  TerminalWindowController.swift
//  WorkspaceManager
//
//  Window controller for terminal focus management.
//

import AppKit

/// Manages focus for terminal views within a window.
/// Uses NotificationCenter instead of window delegate so SwiftUI window behavior stays intact.
final class TerminalFocusManager: NSObject {

    static let shared = TerminalFocusManager()

    /// The currently focused terminal view.
    weak var focusedTerminal: NSView?

    /// Windows being managed.
    private var managedWindows = NSHashTable<NSWindow>.weakObjects()

    /// Track pending focus restoration work.
    private var pendingFocusWork: DispatchWorkItem?

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
        pendingFocusWork?.cancel()

        let nextDelay: TimeInterval
        if let delay {
            nextDelay = min(delay * 2, 0.5)
        } else {
            nextDelay = 0.05
        }

        let work = DispatchWorkItem { [weak self, weak terminal] in
            guard let self, let terminal else { return }

            guard let window = terminal.window else {
                if nextDelay <= 0.5 {
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
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else {
                // Keep focus intent without stealing foreground when app is inactive.
                if !NSApp.isActive || !window.isKeyWindow {
                    self.focusedTerminal = terminal
                    return
                }
            }

            if let oldFocused = self.focusedTerminal, oldFocused !== terminal {
                _ = oldFocused.resignFirstResponder()
            }

            let success = window.makeFirstResponder(terminal)
            if success {
                self.focusedTerminal = terminal
                PerformanceSignposts.endLaunchToFirstPromptIfNeeded(trigger: "terminal_focus")
                onFocused?()
            } else if nextDelay <= 0.5 {
                self.requestFocus(
                    for: terminal,
                    delay: nextDelay,
                    activateApp: activateApp,
                    onFocused: onFocused
                )
            }
        }

        pendingFocusWork = work

        if let delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
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

        if window.firstResponder === window, let terminal = focusedTerminal {
            DispatchQueue.main.async {
                self.requestFocus(for: terminal, activateApp: false)
            }
        }

        syncFocusState(for: window)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
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
