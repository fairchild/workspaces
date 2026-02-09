# Solution: Terminal Keyboard Input in SwiftUI

## The Problem

When embedding SwiftTerm's `LocalProcessTerminalView` (an AppKit NSView) inside a SwiftUI app using `NSViewControllerRepresentable`, keyboard input doesn't reach the terminal. The terminal renders correctly, the cursor blinks, mouse selection works, but typing does nothing.

## Root Cause

**SwiftUI intercepts keyboard events before they reach AppKit views.**

Even when:
- `makeFirstResponder(terminal)` returns `true`
- The terminal is visually focused (cursor blinks)
- The window appears to be key

...keyboard events go to SwiftUI's responder chain, not the embedded AppKit view.

Additionally, when running via `swift run`, clicking on the app window doesn't properly activate the app - events continue going to Terminal.app.

## The Solution: Ghostty-Style Focus Management

The solution combines three components, inspired by [Ghostty](https://ghostty.org/)'s approach to the same problem:

### 1. Centralized Focus Manager (`TerminalFocusManager`)

Located in `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`:

```swift
final class TerminalFocusManager: NSObject {
    static let shared = TerminalFocusManager()

    weak var focusedTerminal: LocalProcessTerminalView?
    private var managedWindows = NSHashTable<NSWindow>.weakObjects()

    /// Register window using NotificationCenter (not window.delegate).
    /// This avoids overwriting SwiftUI's window delegate.
    func registerWindow(_ window: NSWindow) {
        guard !managedWindows.contains(window) else { return }
        managedWindows.add(window)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        // Also observe didResignKey and willClose...
    }

    /// Retry-based focus with exponential backoff (max 2 seconds)
    func requestFocus(for terminal: LocalProcessTerminalView, delay: TimeInterval? = nil) {
        let nextDelay = (delay ?? 0) * 1.5 + 0.05
        guard nextDelay <= 2.0 else { return }

        guard let window = terminal.window else {
            requestFocus(for: terminal, delay: nextDelay)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if window.makeFirstResponder(terminal) {
            focusedTerminal = terminal
        } else {
            requestFocus(for: terminal, delay: nextDelay)
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window.firstResponder === window, let terminal = focusedTerminal {
            requestFocus(for: terminal)
        }
    }
}
```

**Key insights**:
- Use `NotificationCenter` instead of `window.delegate` to avoid interfering with SwiftUI
- Retry logic (up to 40 attempts over 2 seconds) handles unpredictable SwiftUI lifecycle timing

### 2. NSEvent Local Monitor for Keyboard Events

```swift
// In TerminalViewController
eventMonitor = NSEvent.addLocalMonitorForEvents(
    matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]
) { [weak self] event in
    self?.handleLocalEvent(event)
}

private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
    guard let window = terminalView.window,
          window.isKeyWindow else {
        return event  // Not our window, pass through
    }

    switch event.type {
    case .keyDown:
        if window.firstResponder === terminalView,
           TerminalFocusManager.shared.focusedTerminal === terminalView {
            terminalView.keyDown(with: event)
            return nil  // CONSUME - don't let SwiftUI handle it
        }
        return event
    // ... similar for keyUp, flagsChanged
    }
}
```

**Key insight**: Return `nil` to consume the event and prevent SwiftUI from handling it. Return the event to let it pass through normally.

### 3. Global Click Monitor for App Activation

```swift
// In TerminalNSContainerView
clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { event in
    // Global monitor catches clicks even when app is not active
    if let clickedWindow = NSApp.window(withWindowNumber: event.windowNumber),
       clickedWindow === self.window {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        TerminalFocusManager.shared.requestFocus(for: terminal)
    }
}
```

**Key insight**: When running via `swift run`, the app doesn't automatically activate when clicked. The global monitor detects clicks on our window from other apps and forces activation.

### 4. View Controller Integration

Window registration happens in `viewDidAppear`, and cleanup in `viewWillDisappear`:

```swift
// In TerminalViewController
override func viewDidAppear() {
    super.viewDidAppear()

    if let window = view.window {
        TerminalFocusManager.shared.registerWindow(window)
    }
    TerminalFocusManager.shared.requestFocus(for: terminalView)
    setupEventMonitor()
}

override func viewWillDisappear() {
    super.viewWillDisappear()
    removeEventMonitor()  // Critical: prevent duplicate monitors
}
```

## Why Other Approaches Failed

| Approach | Why It Failed |
|----------|---------------|
| Just `makeFirstResponder()` | SwiftUI intercepts events before AppKit |
| `NSViewRepresentable` | Same issue - SwiftUI wrapper intercepts |
| `NSViewControllerRepresentable` | Better lifecycle, but still intercepted |
| Single event monitor attempt | Didn't handle app activation |
| `NSApp.activate()` alone | Timing issues with SwiftUI lifecycle |
| `window.delegate = self` | Overwrites SwiftUI's delegate, breaks things |

## Debugging Techniques That Helped

### 1. Global vs Local Monitor Test
```swift
// If global sees events but local doesn't → app isn't key
NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
    NSLog("[GLOBAL] keyDown: %@", event.characters ?? "?")
}
```

### 2. Detailed State Logging
```swift
NSLog("isActive:%@ isKey:%@ FR:%@",
      NSApp.isActive ? "YES" : "NO",
      window.isKeyWindow ? "YES" : "NO",
      String(describing: type(of: window.firstResponder)))
```

### 3. Window Number Comparison
```swift
// Check if click is in our window when app isn't active
if event.windowNumber == window.windowNumber { ... }
```

## Files Involved

```
Sources/
├── Controllers/
│   └── TerminalWindowController.swift  # TerminalFocusManager (focus singleton)
└── Views/Components/
    └── TerminalView.swift              # TerminalViewController, event monitors, container view
```

## References

- [Ghostty](https://github.com/ghostty-org/ghostty) - GPU-accelerated terminal that solved the same SwiftUI/AppKit focus issues
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) - Terminal emulator library
- [WWDC22: Use SwiftUI with AppKit](https://developer.apple.com/videos/play/wwdc2022/10075/)

## Key Takeaways

1. **SwiftUI intercepts keyboard events** - Use `NSEvent.addLocalMonitorForEvents` and return `nil` to consume events
2. **App activation requires explicit handling** - Use global monitor + `NSApp.activate(ignoringOtherApps: true)`
3. **Timing is unpredictable** - Use retry logic with exponential backoff for focus requests
4. **Use NotificationCenter, not window.delegate** - Avoid overwriting SwiftUI's window delegate
5. **Track focus state centrally** - Use a singleton to coordinate focus across windows
6. **Clean up event monitors** - Remove in `viewWillDisappear` to prevent duplicates
