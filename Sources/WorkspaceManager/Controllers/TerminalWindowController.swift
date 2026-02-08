//
//  TerminalWindowController.swift
//  WorkspaceManager
//
//  Window controller for terminal focus management.
//  Based on Ghostty's approach: AppKit for window/lifecycle, SwiftUI for views.
//

import AppKit
import SwiftTerm

/// Manages focus for terminal views within a window.
/// Solves SwiftUI/AppKit focus coordination issues by centralizing focus logic.
/// Uses NotificationCenter instead of window delegate to avoid interfering with SwiftUI.
final class TerminalFocusManager: NSObject {

    static let shared = TerminalFocusManager()

    /// The currently focused terminal view
    weak var focusedTerminal: LocalProcessTerminalView?

    /// Windows being managed
    private var managedWindows = NSHashTable<NSWindow>.weakObjects()

    /// Track focus restoration attempts
    private var pendingFocusWork: DispatchWorkItem?

    // MARK: - Window Registration

    /// Register a window for focus management using NotificationCenter.
    /// This avoids overwriting SwiftUI's window delegate.
    func registerWindow(_ window: NSWindow) {
        guard !managedWindows.contains(window) else { return }

        managedWindows.add(window)

        // Use notifications instead of delegate to avoid interfering with SwiftUI
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

        NSLog("[FocusManager] Registered window: %@", window.title)
    }

    // MARK: - Focus Management (Ghostty-style retry logic)

    /// Request focus for a terminal with retry logic.
    /// Ghostty uses up to 40 attempts over 2 seconds to handle SwiftUI lifecycle timing.
    func requestFocus(for terminal: LocalProcessTerminalView, delay: TimeInterval? = nil) {
        // Cancel any pending focus work
        pendingFocusWork?.cancel()

        // Max delay: 0.05s * 40 = 2 seconds
        let nextDelay = (delay ?? 0) * 1.5 + 0.05
        guard nextDelay <= 2.0 else {
            NSLog("[FocusManager] Focus restoration failed after max attempts")
            return
        }

        let work = DispatchWorkItem { [weak self, weak terminal] in
            guard let self = self, let terminal = terminal else { return }

            // If the surface isn't attached to a window yet, reschedule
            guard let window = terminal.window else {
                NSLog("[FocusManager] Terminal not in window yet, retrying (delay: %.2fs)", nextDelay)
                self.requestFocus(for: terminal, delay: nextDelay)
                return
            }

            // Activate app and make window key
            NSLog("[FocusManager] Activating app and making window key")
            NSLog(
                "[FocusManager] BEFORE - isActive:%@ isKey:%@",
                NSApp.isActive ? "YES" : "NO",
                window.isKeyWindow ? "YES" : "NO")

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)

            NSLog(
                "[FocusManager] AFTER - isActive:%@ isKey:%@",
                NSApp.isActive ? "YES" : "NO",
                window.isKeyWindow ? "YES" : "NO")

            // Explicitly resign old focus (callback sometimes doesn't fire - per Ghostty)
            if let oldFocused = self.focusedTerminal, oldFocused !== terminal {
                _ = oldFocused.resignFirstResponder()
            }

            let success = window.makeFirstResponder(terminal)
            if success {
                self.focusedTerminal = terminal
                NSLog("[FocusManager] Focus granted to terminal")
            } else {
                // Retry if failed
                NSLog("[FocusManager] makeFirstResponder failed, retrying")
                self.requestFocus(for: terminal, delay: nextDelay)
            }
        }

        self.pendingFocusWork = work

        if let delay = delay {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Focus State Synchronization

    /// Sync focus state to all terminals. Called on window key changes.
    func syncFocusState(for window: NSWindow?) {
        guard let window = window else { return }

        let isKeyWindow = window.isKeyWindow
        let firstResponder = window.firstResponder

        // Notify the focused terminal of its focus state
        if let terminal = focusedTerminal {
            let isFocused = isKeyWindow && firstResponder === terminal
            NSLog(
                "[FocusManager] syncFocusState - isKeyWindow: %@, terminalFocused: %@",
                isKeyWindow ? "YES" : "NO",
                isFocused ? "YES" : "NO")
        }
    }

    // MARK: - Window Notifications

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        NSLog("[FocusManager] windowDidBecomeKey")

        // If when we become key our first responder is the window itself,
        // we want to move focus to our focused terminal surface.
        // This works around various weirdness with SwiftUI focus coordination.
        if window.firstResponder === window, let terminal = focusedTerminal {
            DispatchQueue.main.async {
                self.requestFocus(for: terminal)
            }
        }

        syncFocusState(for: window)
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NSLog("[FocusManager] windowDidResignKey")
        syncFocusState(for: window)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        managedWindows.remove(window)

        // Clear focused terminal if it was in this window
        if focusedTerminal?.window === window {
            focusedTerminal = nil
        }
    }
}
