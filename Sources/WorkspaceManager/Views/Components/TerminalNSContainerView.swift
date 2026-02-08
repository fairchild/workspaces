//
//  TerminalNSContainerView.swift
//  WorkspaceManager
//
//  NSView container that forwards clicks to the terminal view
//

import AppKit
import SwiftTerm

class TerminalNSContainerView: NSView {
    weak var terminalView: LocalProcessTerminalView?
    private var clickMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            setupClickMonitor()
        } else {
            removeClickMonitor()
        }
    }

    private func setupClickMonitor() {
        guard clickMonitor == nil else { return }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self,
                let window = self.window,
                let terminal = self.terminalView
            else {
                NSLog("[TerminalContainer] Global click - but no window/terminal")
                return
            }

            NSLog(
                "[TerminalContainer] Global click detected - windowNumber:%d eventWindow:%d",
                window.windowNumber,
                event.windowNumber)

            if let clickedWindow = NSApp.window(withWindowNumber: event.windowNumber),
                clickedWindow === window
            {
                NSLog("[TerminalContainer] Click IS in our window - activating app")
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                TerminalFocusManager.shared.requestFocus(for: terminal)
            } else {
                NSLog("[TerminalContainer] Click NOT in our window")
            }
        }
        NSLog("[TerminalContainer] Global click monitor installed")
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        NSLog("[TerminalContainer] mouseDown")
        if let terminal = terminalView {
            TerminalFocusManager.shared.requestFocus(for: terminal)
        }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        NSLog("[TerminalContainer] becomeFirstResponder, forwarding to terminal")
        if let terminal = terminalView {
            TerminalFocusManager.shared.requestFocus(for: terminal)
        }
        return super.becomeFirstResponder()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let terminal = terminalView, bounds.contains(point) {
            let terminalPoint = convert(point, to: terminal)
            if terminal.bounds.contains(terminalPoint) {
                return terminal
            }
        }
        return super.hitTest(point)
    }

    deinit {
        removeClickMonitor()
    }
}
