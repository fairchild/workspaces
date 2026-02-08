# Terminal Keyboard Input Troubleshooting

## Current Issue

Terminal keyboard input is intermittent. Automated tests sometimes succeed but manual interaction fails.

## Terminal Library: SwiftTerm

We are using [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) v1.2.0+.

### Why SwiftTerm?
- Production-proven: Used in [Secure Shellfish](https://secureshellfish.app/), [La Terminal](https://laterminal.app/), [CodeEdit](https://github.com/CodeEditApp/CodeEdit)
- Pure Swift implementation
- Provides `LocalProcessTerminalView` for macOS (NSView-based)
- 6+ years of active development
- Better UTF/Unicode handling than xterm.js or XtermSharp

### Alternatives Considered
- **Ghostty's libghostty** - New (Dec 2024), uses SwiftUI natively, but complex to integrate
- **Raw PTY + custom rendering** - Too much work for MVP
- **XtermSharp** - SwiftTerm is the Swift successor to this

## Investigation Timeline

### 2026-01-28: Initial keyboard input failure

**Symptoms:**
- Click to focus terminal works (cursor blinks)
- `makeFirstResponder` returns `true`
- Window is key window
- But keyboard input doesn't reach terminal

**Root Cause Identified:**
SwiftUI intercepts keyboard events before they reach the AppKit NSView (LocalProcessTerminalView).

**Fix Attempted:**
Install `NSEvent.addLocalMonitorForEvents` to intercept keyboard events and forward them directly to the terminal:

```swift
keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
    guard let terminal = self.terminal,
          let window = terminal.window,
          window.isKeyWindow,
          window.firstResponder === terminal else {
        return event
    }
    terminal.keyDown(with: event)
    return nil  // Consume the event
}
```

**Result:** Automated tests pass, but manual testing still fails.

### Subsequent Investigation

**Test Script Results:**

| Test | Click Position | Result |
|------|----------------|--------|
| gui-test.sh | Fixed (800,500) | ✅ Commands executed |
| terminal-test-suite.sh | Fixed (700,450) | ✅ Commands executed |
| smart-terminal-test.sh | Window-relative | ❌ No output |
| complete-terminal-test.sh | Window-relative | ❌ No terminal content |

**Key Observations:**

1. **Multi-monitor issue**: Window was at position (3119, -53) - on secondary monitor with unusual coordinates

2. **No workspace selected**: Some tests failed because no workspace was selected, so no terminal was shown

3. **Terminal initialization**: When workspace selected, terminal shows but shell may not fully initialize

4. **Logging confirms setup**:
   ```
   [TerminalView] makeNSView for: code-council-v1
   [Terminal 233487E4] Setting up keyboard monitor (total active: 1)
   [Terminal 233487E4] Keyboard monitor installed
   [TerminalView] Requesting first responder
   ```

## Known Issues

### 1. SwiftUI/AppKit Focus Coordination

The responder chain in AppKit and SwiftUI's `@FocusState` don't coordinate well.

**References:**
- [WWDC22: Use SwiftUI with AppKit](https://developer.apple.com/videos/play/wwdc2022/10075/)
- [Handling Keyboard Presses in SwiftUI for macOS](https://swiftjectivec.com/Handling-Keyboard-Presses-in-SwiftUI-for-macOS/)
- [SerialCoder: Focusable TextField in SwiftUI](https://serialcoder.dev/text-tutorials/macos-tutorials/macos-programming-implementing-a-focusable-text-field-in-swiftui/)

### 2. NSViewRepresentable Lifecycle

SwiftUI may create/destroy views unexpectedly, leading to:
- Multiple keyboard monitors if not cleaned up
- Focus lost when view hierarchy updates

**Mitigation:**
- Track active monitor count
- Remove monitor in `dismantleNSView` and `deinit`
- Use unique coordinator ID for debugging

### 3. Event Monitor Not Receiving Events

If the window isn't key or first responder isn't set correctly, the monitor's guard clause returns early.

**Debug with:**
```swift
NSLog("[Terminal] keyDown: '%@' keyCode: %d", chars, event.keyCode)
```

## Test Scripts

Located in `scripts/`:

| Script | Purpose |
|--------|---------|
| `gui-test.sh` | Basic keyboard input test |
| `terminal-test-suite.sh` | Comprehensive input tests |
| `smart-terminal-test.sh` | Window-position-aware test |
| `complete-terminal-test.sh` | Full flow: select workspace, test keyboard |
| `workspace-creation-test.sh` | Test workspace creation flow |
| `focus-debug-test.sh` | Debug first responder state |
| `terminal-init-test.sh` | Test terminal initialization timing |

## Potential Solutions to Try

### 1. Override `acceptsFirstResponder` in container
```swift
class TerminalContainerNSView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        terminalView?.window?.makeFirstResponder(terminalView)
        return true
    }
}
```

### 2. Use `NSHostingView` instead of pure SwiftUI embedding
Wrap the terminal in an `NSHostingView` to have more control over the AppKit lifecycle.

### 3. Delay focus request until view is in window
```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    terminal.window?.makeFirstResponder(terminal)
}
```

### 4. Add click handler to force focus
```swift
override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(terminalView)
    super.mouseDown(with: event)
}
```

### 5. Consider Ghostty's libghostty
[Ghostty](https://ghostty.org/) uses SwiftUI natively and may handle focus better. The `libghostty` library could potentially be integrated as an alternative backend.

## Debugging Commands

View app logs:
```bash
log show --predicate 'process == "WorkspaceManager"' --last 5m | grep Terminal
```

Run with console output:
```bash
swift run 2>&1 | tee app.log
```

Open test screenshots:
```bash
open /tmp/terminal-init-test/
```

### Focus State Debugging

Check if app is active:
```bash
# In the app, these logs should show isActive:YES isKey:YES
log show --predicate 'process == "WorkspaceManager"' --last 30s | grep -E "(isActive|isKey|FocusManager)"
```

Check window state via AppleScript:
```bash
osascript -e 'tell application "System Events" to get name of first window of (first process whose frontmost is true)'
```

### Key Diagnostic Questions

1. **Is the app frontmost?** Check menu bar - should show "WorkspaceManager"
2. **Is the window key?** Title bar should be fully colored (not grayed out)
3. **Does global monitor fire?** Look for `[GLOBAL] keyDown detected` in logs
4. **Does local monitor fire?** Look for `[TerminalVC] LOCAL EVENT keyDown` in logs
5. **Is terminal first responder?** Look for `FR:LocalProcessTerminalView` in logs

### Event Flow Diagnosis

```
User types key
    ↓
Is app active? ──NO──→ Global monitor sees it (other app receives key)
    │YES
    ↓
Is window key? ──NO──→ Another window in our app receives key
    │YES
    ↓
Local monitor fires
    ↓
Is terminal firstResponder? ──NO──→ Key goes to other responder
    │YES
    ↓
Forward to terminal.keyDown()
```

## Status

**Current state:** Keyboard input does not work. The app does not become active/frontmost when clicked.

**Core problem:** When clicking WorkspaceManager from another app (e.g., Terminal running `swift run`):
- The cursor visually indicates focus (blinks)
- But the app is NOT becoming the active/frontmost app
- Keyboard events continue going to the previously active app

**What we need to solve:**
1. Why doesn't `NSApp.activate(ignoringOtherApps: true)` make the app active?
2. Why doesn't clicking on the window make it the key window?
3. Is there something about running via `swift run` that prevents activation?

**Next steps:**
1. Build as .app bundle and run directly (not via swift run)
2. Try `NSApp.setActivationPolicy(.regular)` in AppDelegate
3. Check if app has proper Info.plist for activation
4. Use pure AppKit window (NSWindowController) instead of SwiftUI WindowGroup
5. Study CodeEdit's terminal implementation
